# OCI A1 Catcher

Oracle Cloud Always Free의 Ampere A1 인스턴스는 인기 리전에서 거의 항상 `Out of host capacity` 상태다.
이 리포지토리는 GitHub Actions에서 쉬지 않고 생성을 재시도해서, 용량이 열리는 순간을 잡는다.

노트북에서 스크립트를 돌리면 절전에 들어갈 때마다 시도가 멈춘다. Actions는 그 문제가 없다.

## 동작

- 워크플로 실행 하나가 **5시간** 동안 30초 간격으로 `LaunchInstance`를 호출한다 (공개 리포는 Actions 분량이 무료)
- 스케줄은 10분마다 걸려 있어서, 실행 중에 다음 실행이 대기열에 잡히고 끝나자마자 이어서 돈다.
  한 번에 하나만 돌도록 concurrency 그룹으로 묶여 있으므로 대기 중이던 나머지가 `cancelled`로 남는 건 정상이다.
- 3개 AD를 번갈아 시도
- 429(레이트 리밋)를 맞으면 90초, 연속 3회면 10분 쉬었다가 계속한다
- **이미 같은 이름의 인스턴스가 있으면 아무것도 하지 않는다** (중복 생성 방지)
- 확보에 성공하면 이슈를 생성하고 (GitHub이 메일로 알려줌) 워크플로를 스스로 끈다
- 한도 초과·인증 오류처럼 재시도가 무의미한 오류면 작업을 실패시킨다 (실패 알림 메일이 옴)
- 매 실행 끝에 워크플로 enable API를 호출해 60일 자동 비활성화 타이머를 리셋한다

## 필요한 Secrets

| 이름 | 설명 |
|---|---|
| `OCI_CLI_USER` | 사용자 OCID |
| `OCI_CLI_TENANCY` | 테넌시 OCID (compartment로도 쓰임) |
| `OCI_CLI_FINGERPRINT` | API 키 핑거프린트 |
| `OCI_CLI_KEY_CONTENT` | API 개인키 전문 (PEM) |
| `OCI_CLI_REGION` | 예: `us-chicago-1` |
| `OCI_SUBNET` | 공인 서브넷 OCID |
| `OCI_IMAGE` | 부팅 이미지 OCID (Ubuntu aarch64) |
| `OCI_SSH_PUBKEY` | 접속용 SSH 공개키 |
| `OCI_ADS` | AD 이름들, 콤마로 구분 |

## 사양·주기 변경

`catch.sh` 상단의 기본값을 고치거나, 워크플로에서 환경변수로 덮어쓴다.

```
OCPUS=2  MEMORY_GB=12  BOOT_GB=100  DISPLAY_NAME=parkgolf-api
RUN_SECONDS=18000  ATTEMPT_INTERVAL=30  RATE_LIMIT_BACKOFF=90  RATE_LIMIT_LONG_BACKOFF=600
```

`RUN_SECONDS`를 늘리면 워크플로의 `timeout-minutes`도 같이 늘려야 한다 (job 상한 360분).

Always Free 한도는 2026-06-15부터 **2 OCPU / 12GB**로 축소됐다 (이전 4 OCPU / 24GB).
이를 넘겨 요청하면 용량이 있어도 한도 초과로 실패한다.

## 주의

- 공개 리포의 스케줄 워크플로는 **60일간 리포에 활동이 없으면 자동 비활성화**된다.
  마지막 스텝이 매 실행마다 타이머를 리셋하지만, 혹시 꺼져 있으면 Actions 탭에서 다시 켜거나 커밋을 하나 넣는다.
- 스케줄 실행은 GitHub 부하에 따라 지연되거나 건너뛸 수 있다. 실행 하나를 길게 잡은 이유가 이것이다.
- 확보에 성공한 뒤에는 워크플로가 스스로 꺼진다. 안 꺼졌다면 중복 생성 방지 로직이 막아주지만 Actions 탭에서 꺼두는 편이 깔끔하다.
- 용량이 열리는 건 오라클 쪽 사정이라 코드로 확률을 올리는 데는 한계가 있다. 이 스크립트는 "열렸을 때 놓치지 않기"에 집중한다.
