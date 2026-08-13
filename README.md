# OCI A1 Catcher

Oracle Cloud Always Free의 Ampere A1 인스턴스는 인기 리전에서 거의 항상 `Out of host capacity` 상태다.
이 리포지토리는 GitHub Actions에서 10분마다 생성을 재시도해서, 용량이 열리는 순간을 잡는다.

노트북에서 스크립트를 돌리면 절전에 들어갈 때마다 시도가 멈춘다. Actions는 그 문제가 없다.

## 동작

- 10분마다 워크플로 실행 → 한 번에 약 8분 동안 75초 간격으로 `LaunchInstance` 호출
- 3개 AD를 번갈아 시도
- **이미 같은 이름의 인스턴스가 있으면 아무것도 하지 않는다** (중복 생성 방지)
- 확보에 성공하면 이슈를 생성한다 (GitHub이 메일로 알려줌)
- 한도 초과·인증 오류처럼 재시도가 무의미한 오류면 작업을 실패시킨다 (실패 알림 메일이 옴)

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

## 사양 변경

`catch.sh` 상단의 기본값을 고치거나, 워크플로에서 환경변수로 덮어쓴다.

```
OCPUS=2  MEMORY_GB=12  BOOT_GB=100  DISPLAY_NAME=parkgolf-api
```

Always Free 한도는 2026-06-15부터 **2 OCPU / 12GB**로 축소됐다 (이전 4 OCPU / 24GB).
이를 넘겨 요청하면 용량이 있어도 한도 초과로 실패한다.

## 주의

- 공개 리포지토리의 스케줄 워크플로는 **60일간 리포에 활동이 없으면 자동 비활성화**된다.
  오래 못 잡으면 커밋을 하나 넣거나 Actions 탭에서 다시 켠다.
- 스케줄 실행은 GitHub 부하에 따라 지연되거나 건너뛸 수 있다. 정확히 10분마다는 아니다.
- 확보에 성공한 뒤에는 중복 생성 방지 로직이 막아주지만, Actions 탭에서 워크플로를 꺼두는 편이 깔끔하다.
