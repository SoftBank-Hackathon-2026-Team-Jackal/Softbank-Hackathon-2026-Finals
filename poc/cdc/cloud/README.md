# CDC PoC 2단계: AWS ↔ GCP

1단계 PoC(`../`)를 실제 클라우드 두 곳에 올려서, 클라우드 사이에서도 무중단 전환과 롤백이 되는지 검증합니다. 스크립트는 1단계와 같은 것을 그대로 씁니다.

## 구성

```
AWS prod 계정 (ap-northeast-2)                         GCP sbh26-prod (asia-northeast3)
┌──────────────────────────────────────┐            ┌──────────────────────────────┐
│ EC2 t3.small  env-a                  │  WireGuard │ GCE e2-small  env-b          │
│  loadgen → PgBouncer → pg-a          │◀══════════▶│  pg-b                        │
│  toolbox (scripts/)                  │ UDP 51820  │                              │
│  wg0 10.100.0.1                      │  RTT ~3ms  │  wg0 10.100.0.2              │
└──────────────────────────────────────┘            └──────────────────────────────┘
```

| 항목 | 내용 |
|---|---|
| 열린 포트 | 양쪽 모두 **WireGuard(UDP 51820)만**, 그것도 상대 VM의 고정 IP에서 오는 것만 허용합니다. SSH는 열지 않습니다 |
| DB 포트 | pg-a와 pg-b의 5432는 WireGuard 주소에만 바인딩합니다 |
| env-a 접속 | SSM `send-command` (`run.sh`). 로컬에 session-manager-plugin이 없어도 됩니다 |
| env-b 확인 | `gcloud compute instances get-serial-port-output` (시작 스크립트 로그) |
| PoC 파일 전달 | Terraform이 `../`를 zip으로 묶어 S3에 올리고, env-a가 받아 갑니다 |
| 이름 | pg-b가 원격에 있어도 이름은 그대로 `pg-b`입니다. `../compose.cloud-a.yml`이 `/etc/hosts`로 10.100.0.2를 가리키게 하므로 스크립트를 고치지 않습니다 |

## 실행

```bash
aws sso login --sso-session sbh26
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account=alus20x@gmail.com)

terraform init
terraform apply                       # VM 2대 생성. 시작 스크립트가 끝날 때까지 약 3분

./run.sh 'wg show; ping -c3 10.100.0.2'         # 터널 확인
./run.sh 'scenarios/01_round_trip.sh'           # 왕복 시나리오

# PoC 파일을 고친 뒤
terraform apply && ./run.sh sync

terraform destroy                     # 다 쓰면 지운다
```

`run.sh`는 env-a의 `/opt/cdc`에서 `REMOTE_NODES=pg-b`를 설정하고 명령을 실행합니다. 시나리오는 시작할 때 env-a를 `docker compose down -v`로 지우고, 원격 pg-b는 `scripts/reset_node.sh`로 초기화합니다.

## 결과 (2026-11-03)

| 성공 기준 | 처음 | 개선 후 |
|---|---|---|
| 쓰기 중단 2초 이하 | PASS (1,807ms, 1,579ms) | **PASS (978ms, 987ms)** |
| 부하 생성기 에러 0 | PASS | **PASS** |
| 유실 0 | PASS | **PASS** |
| 체크섬 일치 | PASS | **PASS** |

전환 한 번의 단계별 소요 시간(ms)은 다음과 같습니다.

| 단계 | 처음 | 개선 후 | 바꾼 것 |
|---|---|---|---|
| (PAUSE 전) 역방향 구독 준비 | - | 412~578 | 꺼진 상태로 미리 생성 |
| PAUSE | 68 | 약 70 | |
| marker 도착 | 136 | 126 | |
| 체크섬 | 765 | 420 | 두 DB를 동시에 계산 |
| 정방향 삭제 + 시퀀스 + 역방향 | 741 | 273 | 역방향은 `ENABLE`만 |
| 대상 변경 + RESUME | 165 | 159 | |

처음 실행에서 쓰기 중단이 기준(2초)에 가까웠던 원인은 두 가지였습니다. 하나는 원격 슬롯을 만드는 `CREATE SUBSCRIPTION`이었고, 다른 하나는 두 DB의 체크섬을 차례로 계산한 것이었습니다. 개선 후에는 로컬에서도 450ms가 265ms로 줄었습니다.

## 더 줄일 수 있는 곳

- **체크섬(420ms):** 데이터 크기에 비례합니다. PAUSE 안에서는 행 수만 비교하고, 체크섬은 전환 직후 지연 0 상태에서 하는 방식이 다음 후보입니다.
- **연결 비용:** 스크립트가 단계마다 psql을 새로 실행하므로, 매번 WireGuard 위에서 SCRAM 인증을 다시 합니다. 한 세션을 유지하면 단계마다 수십 ms씩 줄어듭니다.

## 주의

- WireGuard 개인 키가 Terraform state(S3, 암호화)와 VM user_data, metadata에 들어 있습니다. PoC 한정입니다.
- DB 비밀번호는 1단계와 같은 고정값이며, WireGuard 주소에서만 접근할 수 있습니다.
- 켜 두는 동안 비용이 나갑니다. EC2 t3.small, EIP, GCE e2-small, 고정 IP를 합쳐 시간당 약 0.06달러(하루 약 1.5달러)입니다.
