#!/usr/bin/env bash
# Oracle Cloud Ampere A1 인스턴스 확보 시도.
# GitHub Actions에서 주기적으로 호출되며, 주어진 시간 동안 LaunchInstance를 반복한다.
#
# 종료 코드: 0 = 정상(확보 성공, 목표 달성, 또는 용량 없음), 1 = 재시도해도 소용없는 오류

set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

SHAPE="VM.Standard.A1.Flex"

# 2026-09-26까지 2코어/12GB 통짜로 44일간 약 66,000회 시도했으나 전부 용량 없음이었다.
# 용량이 조각으로 열릴 때 들어갈 구멍을 넓히려고 1코어/6GB 두 대로 나눈다.
# 1코어 6GB × 2대 = 2 OCPU / 12GB로 Always Free 한도(월 1,500 OCPU시간 / 9,000 GB시간)를 정확히 채운다.
OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
# 무료 블록 스토리지는 부팅 볼륨까지 합쳐 총 200GB다. 두 대면 대당 90GB로 여유를 둔다.
# 200GB를 꽉 채우면 한도 초과 오류가 나서 확보 자체가 막힌다.
BOOT_GB="${BOOT_GB:-90}"

# 인스턴스 이름은 "<DISPLAY_NAME>-<번호>"가 된다. 보유 대수도 이 접두어로 센다.
DISPLAY_NAME="${DISPLAY_NAME:-parkgolf-api}"
TARGET_COUNT="${TARGET_COUNT:-2}"

# 한 번의 워크플로 실행이 시도를 이어가는 시간과 시도 간격.
# 스케줄이 10분마다 걸려 있어도 GitHub이 대부분을 건너뛰어, 실행 사이에 2~4시간씩 비는 일이 잦았다.
# 그래서 한 번 깨어나면 job 상한(6시간)에 가깝게 오래 던진다. 공개 리포는 Actions 분량이 무료라 비용은 없다.
RUN_SECONDS="${RUN_SECONDS:-18000}"
ATTEMPT_INTERVAL="${ATTEMPT_INTERVAL:-30}"
# 429를 맞으면 이 시간만큼 쉬었다 재개한다. 실제 로그를 보면 429는 우리 호출량과 무관하게
# 무작위 시점에 오므로 길게 쉴 이유가 없다. 연속 3회면 한 번 길게 쉬고 계속한다.
# (예전처럼 실행을 접어 버리면 다음 스케줄이 잡힐 때까지 몇 시간을 통째로 잃는다.)
RATE_LIMIT_BACKOFF="${RATE_LIMIT_BACKOFF:-90}"
RATE_LIMIT_LONG_BACKOFF="${RATE_LIMIT_LONG_BACKOFF:-600}"

IFS=',' read -r -a ADS <<< "$OCI_ADS"

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

emit() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }

summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }

# ── 보유 중인 인스턴스 이름 나열 ─────────────────────────────────────────
# 접두어가 일치하고 종료되지 않은 인스턴스 이름을 한 줄에 하나씩 낸다.
# 인증 오류로 목록 조회 자체가 실패하면 1을 반환한다 (0대로 오인해 중복 생성하면 안 된다).
list_existing() {
  local raw rc
  raw=$(oci compute instance list --compartment-id "$OCI_CLI_TENANCY" --all \
        --query 'data[].{n:"display-name",s:"lifecycle-state"}' --output json 2>&1)
  rc=$?

  if (( rc != 0 )); then
    if grep -qiE 'notauthenticated|notauthorized|authentication|invalid.*key|signature' <<< "$raw"; then
      log "❌ 인스턴스 목록 조회 실패 (인증 오류). Secrets를 확인해야 합니다."
      printf '%s\n' "$raw" | head -20
      summary "## ❌ OCI 인증 오류"
      summary "인스턴스 목록 조회부터 실패했습니다. Secrets(키/핑거프린트/OCID)를 확인하세요."
      return 1
    fi
    # 인스턴스가 하나도 없을 때도 비정상 종료처럼 보일 수 있으므로 빈 목록으로 본다.
    return 0
  fi

  [[ -z "$raw" ]] && return 0

  printf '%s' "$raw" | python3 -c '
import sys, json
prefix = sys.argv[1]
dead = {"TERMINATED", "TERMINATING"}
try:
    rows = json.load(sys.stdin) or []
except Exception:
    sys.exit(0)
for r in rows:
    name = r.get("n") or ""
    if name.startswith(prefix) and r.get("s") not in dead:
        print(name)
' "$DISPLAY_NAME"
}

existing=()

# 비어 있는 가장 작은 번호를 고른다. 중간이 종료돼 비면 그 번호를 다시 쓴다.
next_index() {
  local i=1 n used
  while :; do
    used=0
    for n in ${existing[@]+"${existing[@]}"}; do
      [[ "$n" == "${DISPLAY_NAME}-${i}" ]] && { used=1; break; }
    done
    (( used )) || { echo "$i"; return; }
    i=$(( i + 1 ))
  done
}

# ── 확보 즉시 이슈로 알린다 ──────────────────────────────────────────────
# 워크플로 스텝이 아니라 스크립트에서 직접 만든다. 이유가 두 가지다.
#  - 한 실행에서 여러 대를 잡을 수 있으므로 대당 한 번 알려야 한다.
#  - 러너가 통신을 잃고 죽으면 always()를 붙인 스텝조차 돌지 않는다 (2026-09-26에 실제로 겪었다).
#    확보 직후에 바로 보내면 그 구멍이 거의 닫힌다.
notify_caught() {
  local name="$1" instance_id="$2" ip="$3" ad="$4" remaining="$5" body
  if [[ -z "${GH_TOKEN:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
    log "  (GH_TOKEN이 없어 이슈를 만들지 않습니다)"
    return 0
  fi
  body=$(cat <<BODY
Oracle Cloud Ampere A1 인스턴스를 확보했습니다.

| 항목 | 값 |
|---|---|
| 이름 | \`${name}\` |
| 공인 IP | \`${ip}\` |
| Instance ID | \`${instance_id}\` |
| Availability Domain | \`AD-${ad##*-}\` |
| 사양 | ${OCPUS} OCPU / ${MEMORY_GB}GB / 부팅 ${BOOT_GB}GB |

접속:

\`\`\`
ssh -i ~/.ssh/oci_parkgolf ubuntu@${ip}
\`\`\`

목표 ${TARGET_COUNT}대 중 ${remaining}대가 남았습니다.
공인 IP가 비어 있으면 OCI 콘솔에서 확인하세요. 인스턴스는 이미 만들어졌습니다.
BODY
)
  if gh issue create --repo "$GITHUB_REPOSITORY" \
       --title "🎉 A1 인스턴스 확보 — ${name} (${ip})" --body "$body"; then
    log "  이슈로 알렸습니다."
  else
    log "  ⚠️ 이슈 생성에 실패했습니다 (인스턴스는 확보된 상태입니다)."
  fi
}

# 목표 대수를 이미 채운 상태로 실행이 시작된 경우에 쓴다.
# 앞선 실행이 확보 직후 러너와 함께 죽어 알림을 못 보냈을 수 있으므로 한 번 되짚어 알린다.
# 바로 다음 스텝에서 워크플로가 꺼지므로 반복되지 않는다.
notify_complete() {
  local body
  [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || return 0
  body=$(cat <<BODY
목표한 ${TARGET_COUNT}대를 이미 보유한 상태입니다.

보유 중인 인스턴스: ${existing[*]}

이 워크플로는 방금 자동으로 비활성화됐습니다.
다시 필요하면 Actions 탭에서 Enable 하세요.
공인 IP는 OCI 콘솔에서 확인하세요.
BODY
)
  gh issue create --repo "$GITHUB_REPOSITORY" \
    --title "✅ A1 인스턴스 ${TARGET_COUNT}대 확보 완료" --body "$body" \
    || log "  ⚠️ 완료 이슈 생성에 실패했습니다."
}

# ── 생성 시도 ──────────────────────────────────────────────────────────
try_launch() {
  local ad="$1" name="$2"
  # --no-retry: 용량 없음이 500으로 오기 때문에 CLI 기본 재시도가 걸려
  # 호출 하나가 100초씩 잡아먹는다. 재시도는 우리 루프가 대신한다.
  LAUNCH_OUT=$(oci compute instance launch \
    --no-retry \
    --availability-domain "$ad" \
    --compartment-id "$OCI_CLI_TENANCY" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$OCI_IMAGE" \
    --subnet-id "$OCI_SUBNET" \
    --display-name "$name" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_GB" \
    --metadata "{\"ssh_authorized_keys\":\"$OCI_SSH_PUBKEY\"}" 2>&1)
  return $?
}

# 공인 IP를 짧게 기다렸다 읽는다. 아직 목표가 남았을 수 있으므로 오래 붙잡지 않는다.
# 용량이 열린 창은 짧아서 여기서 5분을 쓰면 다음 대를 놓친다.
get_public_ip() {
  local instance_id="$1" i ip
  for i in 1 2 3 4 5 6; do
    ip=$(oci compute instance list-vnics --instance-id "$instance_id" \
         --query 'data[0]."public-ip"' --raw-output 2>/dev/null)
    if [[ -n "$ip" && "$ip" != "null" ]]; then
      printf '%s' "$ip"
      return 0
    fi
    sleep 10
  done
  return 1
}

on_success() {
  local ad="$1" name="$2" instance_id ip=""
  instance_id=$(printf '%s' "$LAUNCH_OUT" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)

  if [[ -z "$instance_id" ]]; then
    log "생성 호출은 성공했는데 응답에서 instance-id를 못 읽었습니다. 원본 출력:"
    printf '%s\n' "$LAUNCH_OUT" | head -30
  fi

  log "🎉 생성 성공! ${name} / AD-${ad##*-} / instance-id: ${instance_id:-unknown}"

  [[ -n "$instance_id" ]] && ip=$(get_public_ip "$instance_id")
  log "공인 IP: ${ip:-확인실패}"

  summary "## 🎉 확보: ${name}"
  summary ""
  summary "| 항목 | 값 |"
  summary "|---|---|"
  summary "| Availability Domain | \`AD-${ad##*-}\` |"
  summary "| Instance ID | \`${instance_id:-unknown}\` |"
  summary "| 공인 IP | \`${ip:-확인실패}\` |"
  summary "| 사양 | ${OCPUS} OCPU / ${MEMORY_GB}GB / 부팅 ${BOOT_GB}GB |"
  summary ""
  summary "\`\`\`"
  summary "ssh -i ~/.ssh/oci_parkgolf ubuntu@${ip:-<IP>}"
  summary "\`\`\`"
  summary ""

  notify_caught "$name" "${instance_id:-unknown}" "${ip:-확인실패}" "$ad" \
                "$(( TARGET_COUNT - count - 1 ))"
}

# 실패 원인 분류. 재시도가 무의미한 오류면 1, 레이트 리밋이면 2를 반환한다.
classify_failure() {
  if grep -qiE 'out of (host )?capacity' <<< "$LAUNCH_OUT"; then
    log "  → 용량 없음"
  # 429는 opc-request-id 같은 16진수 문자열 안에도 흔히 들어가므로 숫자만으로 판별하지 않는다.
  elif grep -qiE 'toomanyrequests|"status": *429|rate limit' <<< "$LAUNCH_OUT"; then
    log "  → ⚠️ 레이트 리밋"
    return 2
  elif grep -qiE 'limitexceeded|quota' <<< "$LAUNCH_OUT"; then
    log "❌ 한도 초과"
    printf '%s\n' "$LAUNCH_OUT" | head -20
    return 1
  elif grep -qiE 'notauthenticated|notauthorized|authentication' <<< "$LAUNCH_OUT"; then
    log "❌ 인증 오류 — Secrets 설정을 확인해야 합니다."
    printf '%s\n' "$LAUNCH_OUT" | head -20
    summary "## ❌ OCI 인증 오류"
    summary "Secrets(키/핑거프린트/OCID)를 확인하세요."
    return 3
  else
    log "  → 알 수 없는 오류:"
    printf '%s\n' "$LAUNCH_OUT" | head -15
  fi
  return 0
}

# ── 보유 현황 확인 ─────────────────────────────────────────────────────
existing_raw=$(list_existing) || { emit caught false; emit complete false; exit 1; }
# mapfile은 bash 4 이상에서만 쓸 수 있다. 러너는 bash 5지만 로컬 검증까지 되도록 이식성 있게 읽는다.
while IFS= read -r line; do
  [[ -n "$line" ]] && existing+=("$line")
done <<< "$existing_raw"
count=${#existing[@]}

if (( count >= TARGET_COUNT )); then
  log "이미 목표 ${TARGET_COUNT}대를 보유하고 있습니다 (${existing[*]}). 시도하지 않습니다."
  summary "✅ 이미 ${count}대를 확보한 상태입니다. 워크플로를 끕니다."
  notify_complete
  emit caught false
  emit complete true
  exit 0
fi

(( count > 0 )) && log "보유 중: ${existing[*]} (${count}/${TARGET_COUNT})"

# ── 확보 루프 ──────────────────────────────────────────────────────────
deadline=$(( SECONDS + RUN_SECONDS ))
attempt=0
throttled=0
rate_limited=0
caught_this_run=0

log "감시 시작: ${SHAPE} ${OCPUS}코어/${MEMORY_GB}GB, 부팅 ${BOOT_GB}GB, 목표 ${TARGET_COUNT}대 (보유 ${count}대), ${RUN_SECONDS}초 동안 ${ATTEMPT_INTERVAL}초 간격 (429 시 ${RATE_LIMIT_BACKOFF}초, 연속 3회면 ${RATE_LIMIT_LONG_BACKOFF}초 대기)"

while (( SECONDS < deadline && count < TARGET_COUNT )); do
  ad="${ADS[$(( attempt % ${#ADS[@]} ))]}"
  attempt=$(( attempt + 1 ))
  name="${DISPLAY_NAME}-$(next_index)"
  log "시도 ${attempt} — AD-${ad##*-} / ${name}"

  if try_launch "$ad" "$name"; then
    on_success "$ad" "$name"
    existing+=("$name")
    count=$(( count + 1 ))
    caught_this_run=$(( caught_this_run + 1 ))
    throttled=0
    if (( count < TARGET_COUNT )); then
      # 용량이 열린 창은 짧다. 쉬지 않고 곧바로 다음 대를 노린다.
      log "목표까지 $(( TARGET_COUNT - count ))대 남았습니다. 대기 없이 계속합니다."
    fi
    continue
  fi

  classify_failure
  case $? in
    1)
      # 한도 초과. 이미 한 대라도 확보했다면 더 받을 수 없다는 뜻이므로 정상 종료하고 워크플로를 끈다.
      # 여기서 실패로 끝내면 5시간마다 실패 메일만 쌓인다.
      if (( count > 0 )); then
        log "이미 ${count}대를 확보한 상태에서 한도 초과입니다. 여기까지가 한도로 보고 종료합니다."
        summary "## ⚠️ 한도 초과로 종료"
        summary "${count}대를 확보한 뒤 한도 초과 응답을 받았습니다. 워크플로를 끕니다."
        emit caught true
        emit complete true
        exit 0
      fi
      log "한 대도 확보하지 못한 상태의 한도 초과입니다. 요청 사양이나 계정 한도를 확인해야 합니다."
      summary "## ❌ 한도 초과"
      summary "무료 한도(${OCPUS} OCPU / ${MEMORY_GB}GB × ${TARGET_COUNT}대, 부팅 ${BOOT_GB}GB)를 넘는 요청이거나 이미 한도를 쓴 상태입니다."
      emit caught false
      emit complete false
      exit 1
      ;;
    3)
      emit caught false
      emit complete false
      exit 1
      ;;
    2)
      throttled=$(( throttled + 1 ))
      rate_limited=$(( rate_limited + 1 ))
      if (( throttled >= 3 )); then
        log "  → 레이트 리밋이 3회 연속입니다. ${RATE_LIMIT_LONG_BACKOFF}초 길게 쉬었다가 계속합니다."
        sleep "$RATE_LIMIT_LONG_BACKOFF"
        throttled=0
      else
        log "  → ${RATE_LIMIT_BACKOFF}초 쉬었다가 계속합니다."
        sleep "$RATE_LIMIT_BACKOFF"
      fi
      continue
      ;;
    *) throttled=0 ;;
  esac

  sleep "$ATTEMPT_INTERVAL"
done

# ── 마무리 ────────────────────────────────────────────────────────────
if (( count >= TARGET_COUNT )); then
  log "✅ 목표 ${TARGET_COUNT}대를 모두 확보했습니다 (${existing[*]}). ${attempt}회 시도, 이번 실행에서 ${caught_this_run}대."
  summary "## ✅ 목표 ${TARGET_COUNT}대 확보 완료"
  summary "이번 실행에서 ${caught_this_run}대를 잡았습니다. 워크플로를 끕니다."
  emit caught true
  emit complete true
  exit 0
fi

log "이번 실행 종료: ${attempt}회 시도, 확보 ${caught_this_run}대, 보유 ${count}/${TARGET_COUNT}, 레이트 리밋 ${rate_limited}회. 다음 스케줄에서 계속합니다."
summary "이번 실행: ${attempt}회 시도, 확보 ${caught_this_run}대, 보유 ${count}/${TARGET_COUNT}, 레이트 리밋 ${rate_limited}회."
emit caught "$( (( caught_this_run > 0 )) && echo true || echo false )"
emit complete false
exit 0
