#!/usr/bin/env bash
# Oracle Cloud Ampere A1 인스턴스 확보 시도.
# GitHub Actions에서 주기적으로 호출되며, 주어진 시간 동안 LaunchInstance를 반복한다.
#
# 종료 코드: 0 = 정상(확보 성공 또는 용량 없음), 1 = 재시도해도 소용없는 오류

set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

SHAPE="VM.Standard.A1.Flex"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_GB="${BOOT_GB:-100}"
DISPLAY_NAME="${DISPLAY_NAME:-parkgolf-api}"

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

emit() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >> "$GITHUB_OUTPUT"; }

summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$1" >> "$GITHUB_STEP_SUMMARY"; }

# ── 이미 인스턴스가 있으면 절대 또 만들지 않는다 ────────────────────────
existing=$(oci compute instance list \
  --compartment-id "$OCI_CLI_TENANCY" \
  --display-name "$DISPLAY_NAME" \
  --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`].id | [0]' \
  --raw-output 2>/dev/null)

if [[ -n "$existing" && "$existing" != "null" ]]; then
  log "이미 '$DISPLAY_NAME' 인스턴스가 있습니다 ($existing). 아무것도 하지 않고 종료합니다."
  summary "✅ 이미 확보된 인스턴스가 있어 시도하지 않았습니다."
  emit caught false
  emit already_exists true
  exit 0
fi

# ── 생성 시도 ──────────────────────────────────────────────────────────
try_launch() {
  local ad="$1"
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
    --display-name "$DISPLAY_NAME" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_GB" \
    --metadata "{\"ssh_authorized_keys\":\"$OCI_SSH_PUBKEY\"}" 2>&1)
  return $?
}

on_success() {
  local ad="$1" instance_id ip=""
  instance_id=$(echo "$LAUNCH_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)

  if [[ -z "$instance_id" ]]; then
    log "생성 호출은 성공했는데 응답에서 instance-id를 못 읽었습니다. 원본 출력:"
    echo "$LAUNCH_OUT" | head -30
  fi

  log "🎉 생성 성공! AD-${ad##*-} / instance-id: ${instance_id:-unknown}"

  # 아래 RUNNING 대기 중에 job이 끊기더라도 알림·비활성화 스텝이 돌도록 결과부터 기록한다.
  emit caught true
  emit instance_id "${instance_id:-unknown}"

  if [[ -n "$instance_id" ]]; then
    # RUNNING이 될 때까지 기다렸다가 공인 IP를 읽는다. 실패해도 인스턴스는 이미 만들어졌다.
    oci compute instance get --instance-id "$instance_id" \
      --wait-for-state RUNNING --wait-interval-seconds 10 --max-wait-seconds 300 >/dev/null 2>&1

    ip=$(oci compute instance list-vnics --instance-id "$instance_id" \
         --query 'data[0]."public-ip"' --raw-output 2>/dev/null)
  fi

  log "공인 IP: ${ip:-확인실패}"
  emit public_ip "${ip:-unknown}"

  summary "## 🎉 A1 인스턴스 확보 성공"
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
    log "❌ 한도 초과 — 재시도해도 소용없습니다."
    echo "$LAUNCH_OUT" | head -20
    summary "## ❌ 한도 초과"
    summary "무료 한도(2 OCPU / 12GB)를 넘는 요청이거나 이미 한도를 쓴 상태입니다."
    return 1
  elif grep -qiE 'notauthenticated|notauthorized|authentication' <<< "$LAUNCH_OUT"; then
    log "❌ 인증 오류 — Secrets 설정을 확인해야 합니다."
    echo "$LAUNCH_OUT" | head -20
    summary "## ❌ OCI 인증 오류"
    summary "Secrets(키/핑거프린트/OCID)를 확인하세요."
    return 1
  else
    log "  → 알 수 없는 오류:"
    echo "$LAUNCH_OUT" | head -15
  fi
  return 0
}

deadline=$(( SECONDS + RUN_SECONDS ))
attempt=0
throttled=0
rate_limited=0

log "감시 시작: ${SHAPE} ${OCPUS}코어/${MEMORY_GB}GB, 부팅 ${BOOT_GB}GB, ${RUN_SECONDS}초 동안 ${ATTEMPT_INTERVAL}초 간격 (429 시 ${RATE_LIMIT_BACKOFF}초, 연속 3회면 ${RATE_LIMIT_LONG_BACKOFF}초 대기)"

while (( SECONDS < deadline )); do
  ad="${ADS[$(( attempt % ${#ADS[@]} ))]}"
  attempt=$(( attempt + 1 ))
  log "시도 ${attempt} — AD-${ad##*-}"

  if try_launch "$ad"; then
    on_success "$ad"
    exit 0
  fi

  classify_failure
  case $? in
    1) emit caught false; exit 1 ;;
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

log "이번 실행에서는 확보 실패 (${attempt}회 시도, 레이트 리밋 ${rate_limited}회). 다음 스케줄에서 계속합니다."
summary "이번 실행: ${attempt}회 시도, 레이트 리밋 ${rate_limited}회. 확보 실패."
emit caught false
exit 0
