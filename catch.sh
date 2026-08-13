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

# 한 번의 워크플로 실행이 시도를 이어가는 시간과 시도 간격
RUN_SECONDS="${RUN_SECONDS:-480}"
ATTEMPT_INTERVAL="${ATTEMPT_INTERVAL:-75}"

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
  LAUNCH_OUT=$(oci compute instance launch \
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
  local ad="$1" instance_id ip
  instance_id=$(echo "$LAUNCH_OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)

  log "🎉 생성 성공! ${ad##*-} / instance-id: $instance_id"

  # RUNNING이 될 때까지 기다렸다가 공인 IP를 읽는다. 실패해도 인스턴스는 이미 만들어졌다.
  oci compute instance get --instance-id "$instance_id" \
    --wait-for-state RUNNING --wait-interval-seconds 10 --max-wait-seconds 300 >/dev/null 2>&1

  ip=$(oci compute instance list-vnics --instance-id "$instance_id" \
       --query 'data[0]."public-ip"' --raw-output 2>/dev/null)

  log "공인 IP: ${ip:-확인실패}"

  emit caught true
  emit instance_id "$instance_id"
  emit public_ip "${ip:-unknown}"

  summary "## 🎉 A1 인스턴스 확보 성공"
  summary ""
  summary "| 항목 | 값 |"
  summary "|---|---|"
  summary "| Availability Domain | \`${ad##*-}\` |"
  summary "| Instance ID | \`$instance_id\` |"
  summary "| 공인 IP | \`${ip:-확인실패}\` |"
  summary "| 사양 | ${OCPUS} OCPU / ${MEMORY_GB}GB / 부팅 ${BOOT_GB}GB |"
  summary ""
  summary "\`\`\`"
  summary "ssh -i ~/.ssh/oci_parkgolf ubuntu@${ip:-<IP>}"
  summary "\`\`\`"
}

# 실패 원인 분류. 재시도가 무의미한 오류면 1을 반환한다.
classify_failure() {
  if grep -qiE 'out of (host )?capacity' <<< "$LAUNCH_OUT"; then
    log "  → 용량 없음"
  elif grep -qiE 'toomanyrequests|429|rate limit' <<< "$LAUNCH_OUT"; then
    log "  → ⚠️ 레이트 리밋. 이번 실행은 여기서 접습니다."
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

log "감시 시작: ${SHAPE} ${OCPUS}코어/${MEMORY_GB}GB, 부팅 ${BOOT_GB}GB, ${RUN_SECONDS}초 동안 ${ATTEMPT_INTERVAL}초 간격"

while (( SECONDS < deadline )); do
  ad="${ADS[$(( attempt % ${#ADS[@]} ))]}"
  attempt=$(( attempt + 1 ))
  log "시도 ${attempt} — ${ad##*-}"

  if try_launch "$ad"; then
    on_success "$ad"
    exit 0
  fi

  classify_failure
  case $? in
    1) emit caught false; exit 1 ;;
    2) break ;;
  esac

  sleep "$ATTEMPT_INTERVAL"
done

log "이번 실행에서는 확보 실패 (${attempt}회 시도). 다음 스케줄에서 계속합니다."
emit caught false
exit 0
