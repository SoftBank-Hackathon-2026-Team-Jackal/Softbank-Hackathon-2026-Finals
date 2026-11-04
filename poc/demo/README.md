# 이전 리허설 환경: CDC PoC + 데모 앱 + HAProxy

[CDC PoC](../cdc/README.md)의 pg-a, pg-b, PgBouncer 위에 [데모 앱](https://github.com/SoftBank-Hackathon-2026-Team-Jackal/demo-app) 2개(env-a, env-b)와 HAProxy를 얹어서, 앱 이전(Phase A)과 DB 전환(Phase B)을 한 번에 리허설합니다.

```
에이전트(호스트) ─▶ HAProxy :8090 ─┬─▶ app-a (env-a) ─┐
브라우저                           └─▶ app-b (env-b) ─┴─▶ PgBouncer ─▶ pg-a ══ 논리 복제 ══▶ pg-b
loadgen ────────────────────────────────────────────────▶ PgBouncer
```

`compose.yml`은 단독으로 쓰지 않고 `../cdc/docker-compose.yml` 위에 겹쳐 씁니다. `bin/demo`가 두 파일을 묶어서 `docker compose`를 실행하고, 프로젝트 이름이 PoC와 같은 `cdc-poc`라서 PoC의 `bin/tool`을 그대로 쓸 수 있습니다. 데모 앱은 `~/workspace/jackal-demo-app`(또는 `DEMO_APP_SRC`)에서 빌드합니다. GHCR 이미지는 비공개라 받을 수 없습니다.

## 제어판

```bash
python3 poc/demo/panel/server.py    # http://localhost:8091
```

버튼으로 환경 준비, 에이전트 시작·중지, 이전, 되돌리기, 검증을 실행하고 다음을 실시간으로 보여 줍니다.

- 구성도: HAProxy 가중치, 앱 상태, PgBouncer 대상, 주 DB, 복제 방향과 지연
- CDC: 스키마 덤프 → 초기 복사 → 변경 따라잡기 → 실시간 동기화 단계, 테이블별 복사 진행, 복제 지연 추이 (초기 복사를 눈으로 보려면 데이터 약 1GB로 준비)
- 이전 진행: 단계별 경과 시간, DB 전환 세부 시간(쓰기 중단), 전환 기록
- 트래픽: 부하 처리량과 지연, 채팅 메시지 수, 메시지를 처리한 앱 환경과 저장된 DB 비율
- 검증 결과: 에이전트 유실·중복, 부하 에러, 커밋된 주문 유실, pg-a와 pg-b 체크섬 비교
- 전환 가능 시점: 주 DB에서 가장 긴 트랜잭션, 잠금 대기, 초당 커밋 수를 1초마다 보여 줍니다 (`readiness.py`와 같은 기준)

전환 방식과 초기 복사 방식을 고를 수 있습니다. 기본값은 빠른 전환과 논리 복사입니다.

| 선택 | 값 | 설명 |
|---|---|---|
| 전환 방식 (`SWITCHOVER`) | `fast` (기본) | `05_switchover_fast.py`. 전환 가능 시점까지 기다린 뒤 PAUSE하고, PAUSE 안에서는 marker 커밋과 구독 전환만 합니다. 검증은 RESUME 뒤에 전환 순간의 스냅샷으로 합니다. 로컬에서 쓰기 중단 4~8ms |
| | `classic` | `05_switchover.sh`. PAUSE 안에서 체크섬을 확인합니다. 로컬에서 쓰기 중단 약 600ms |
| 초기 복사 (`COPY`) | `logical` (기본) | `pg_dump --schema-only` 뒤 `copy_data = true`로 복사. CDC 단계 시각화를 보기 좋습니다 |
| | `physical` | pg-b를 멈추고 `pg_basebackup` + `pg_createsubscriber`로 블록을 그대로 복사한 뒤 논리 구독자로 바꿉니다. 90MB에서 0.7초 |

데모 환경은 물리 복사 때문에 PostgreSQL 17을 씁니다 (`PG_IMAGE`로 바꿀 수 있음). 물리 복사는 pg-a의 DB 설정까지 복사하므로 `bin/prepare`가 pg-b의 노드 이름(`app.node_name`)을 다시 지정합니다.

에이전트는 제어판의 `/api/metrics`(주 DB, 앱 가중치, 복제 단계와 지연, 마지막 전환의 쓰기 중단 시간, 최근 60초 부하 p50/p95/p99와 에러, 지금 진행 중인 이전 단계)를 말하기 전마다 읽고, 숫자는 이 지표에 있는 값만 인용합니다. 에이전트가 직접 잰 채팅 전송 지연(p95)도 함께 씁니다.

서버는 표준 라이브러리만 씁니다. 1초마다 `docker exec`로 두 DB의 `pg_subscription_rel`, `pg_replication_slots`, `pg_stat_progress_copy`를 조회하고, 버튼은 아래 `bin/` 스크립트를 실행합니다.

| 스크립트 | 하는 일 |
|---|---|
| `bin/prepare` | 전부 지우고 다시 만든 뒤 복제를 streaming까지 진행 (`SCALE`, `RATE`) |
| `bin/migrate` | 트래픽 50:50 → 0:100 → app-a 종료 → DB pg-a → pg-b 전환 |
| `bin/rollback` | DB pg-b → pg-a 전환 → app-a 시작 → 트래픽 50:50 → 100:0 |
| `bin/verify` | 부하 중지 → 유실 확인 → 데이터 비교 |
| `bin/fault <장애>` | 장애 주입 (`kill-app`, `tamper`, `kill-target`). 마지막 줄에 `FAULT_RESULT {...}` 출력 |

## 장애 주입

제어판의 "장애 주입" 카드나 `bin/fault`로 실행합니다. 장애마다 기대 결과와 실제 측정값을 비교해 판정하고, 결과는 `/api/metrics`의 `last_fault_test`로 에이전트에게도 전달됩니다. 메시지 유실 여부는 장애 뒤에 검증으로 확인합니다.

| 장애 | 주입 방법 | 작동하는 장치 | 기대 결과 |
|---|---|---|---|
| `kill-app` 앱 강제 종료 | 트래픽 50:50에서 app-a를 SIGKILL, 10초 뒤 원래 상태로 | HAProxy 헬스 체크, `retry-on`, SSE 재접속, `client_msg_id` | 사용자 5xx 0, 메시지 유실 0 |
| `tamper` 대기 DB 몰래 수정 | 대기 DB의 채팅 메시지 하나를 직접 수정한 뒤 DB 전환 시도 (끝나면 원래대로 되돌림) | PAUSE 안 체크섬 검증 | 전환 거부, 주 DB 유지 |
| `kill-target` 전환 도중 대기 DB 다운 | `FAULT_AT=forward-disabled`로 정방향 구독을 끈 직후 대상 DB를 SIGKILL | 전환 스크립트의 중단 처리 | 원래 DB로 RESUME, 대상 DB가 돌아오면 정방향 구독을 다시 켜서 복제 재개 |
| `batch-switch` 배치 잠금 중 전환 | 배치가 상품 행 전체를 5초 동안 잠근 상태에서 빠른 전환, 끝나면 원래 DB로 되돌림 | 전환 가능 시점 대기 | 잠금이 풀릴 때까지 PAUSE하지 않음, 쓰기 중단 1초 미만 |

`tamper`는 PAUSE 안에서 체크섬을 확인하는 기존 전환으로 시험합니다. 빠른 전환은 검증을 RESUME 뒤로 미루므로, 같은 상황에서는 전환한 다음에 불일치를 보고합니다.

두 전환 스크립트 모두 `FAULT_AT=<paused|forward-disabled>`이면 그 지점에서 결과 폴더에 `.fault-<지점>` 파일을 만들고, 호스트가 장애를 일으킨 뒤 `.done` 파일을 만들 때까지 최대 5초 기다립니다.

이 시험을 위해 전환 절차를 고쳤습니다. 예전에는 4단계에서 정방향 구독을 **삭제**해서, 그 뒤 RESUME 전에 실패하면 대상 DB가 복제를 잃었습니다. 지금은 4단계에서 구독을 **끄기만** 하고 RESUME 뒤에 삭제합니다. 중간에 실패하면 구독을 다시 켜서 그대로 이어지고, 대상 DB에 접속할 수 없으면 남은 역방향 슬롯 정리 방법을 로그로 안내합니다.

**장애 주입으로 빠른 전환의 버그를 찾았습니다.** 빠른 전환은 4단계(구독 전환) 뒤로 대상 DB에 SQL을 보내지 않아서, 그사이 대상 DB가 죽어도 죽은 DB로 PgBouncer 대상을 바꾸고 RESUME했습니다. 1분 동안 모든 쓰기가 실패했습니다. 기존 전환은 5단계에서 대상 DB의 시퀀스를 맞추느라 우연히 실패를 알아챘습니다. 지금은 대상을 바꾸기 직전에 대상 DB에 `select 1`을 보내고, 실패하면 원래 DB로 되돌립니다.

결과 (2026-11-04, 기존 전환, 주 DB pg-b, 부하 50 tx/s, 에이전트 실행 중):

| 장애 | 측정값 |
|---|---|
| 앱 강제 종료 | 감지까지 3,953ms, HAProxy 재시도 2건, 사용자 5xx 0건 |
| 대기 DB 몰래 수정 | 전환 거부, 쓰기 중단 710ms, 주 DB pg-b 유지 |
| 전환 도중 대기 DB 다운 | 전환 거부, 쓰기 중단 869ms, 복제 재개까지 1,483ms |
| 이후 검증 | 에이전트 메시지 6건 유실 0, 부하 92,344건 에러 0, 커밋된 주문 55,660건 유실 0, 체크섬 일치 |

결과 (2026-11-04, PostgreSQL 17, 빠른 전환, 부하 50 tx/s, 에이전트 실행 중):

| 항목 | 측정값 |
|---|---|
| 물리 복사로 준비 | pg_basebackup 0.2초 + 구독자 변환 0.5초 (90MB) |
| 이전과 되돌리기 | 쓰기 중단 6ms, 7ms (2회차), 4ms, 6ms. 전환 순간 스냅샷 비교 모두 일치 |
| 전환 도중 대기 DB 다운 | 대상 생존 확인에서 중단, 쓰기 중단 215ms, 주 DB pg-a 유지, 복제 재개까지 1,392ms |
| 배치 잠금 중 전환 | 전환 가능 시점까지 4,642ms 대기, 쓰기 중단 6ms |
| 앱 강제 종료, 대기 DB 몰래 수정 | 사용자 5xx 0건 / 전환 거부, 쓰기 중단 350ms |
| 이후 검증 | 에이전트 메시지 15건 유실 0, 중복 0, 부하 5,989건 에러 0, 커밋된 주문 3,617건 유실 0, 체크섬 일치. 부하 최대 지연 4.9초는 배치가 상품 행을 잠근 시간입니다 |

## 단계별 실행

```bash
cd poc/demo
bin/demo up -d --build --wait                # http://localhost:8090, HAProxy 통계 http://localhost:8404
../cdc/bin/tool seed.sh pg-a 1               # 쇼핑몰 기존 데이터 (약 50MB)
(cd ../cdc && docker compose --profile load up -d --build loadgen)
(cd ~/workspace/jackal-demo-app/agents && uv run --env-file .env chatbots.py --url http://localhost:8090)  # 다른 터미널

# CDC 준비
../cdc/bin/tool 01_copy_schema.sh pg-a pg-b
../cdc/bin/tool 02_start_replication.sh pg-a pg-b
../cdc/bin/tool 03_wait_sync.sh pg-a pg-b

# Phase A: 앱 이전
bin/weight 50 50
bin/weight 0 100
bin/demo stop app-a

# Phase B: DB 전환
../cdc/bin/tool 05_switchover.sh pg-a pg-b

# 검증: 에이전트를 Ctrl-C로 끄면 유실·중복 집계가 출력된다
(cd ../cdc && docker compose --profile load stop loadgen)
../cdc/bin/tool 07_check_lost.sh pg-b
../cdc/bin/tool 04_compare.sh pg-b pg-a

bin/demo --profile load --profile tools down -v   # 정리
```

포트는 `DEMO_PORT`(기본 8090), `DEMO_STATS_PORT`(8404), `HAPROXY_RUNTIME_PORT`(9999)로 바꿀 수 있습니다. 8080은 데모 앱 저장소의 개발용 Compose가 씁니다.

## 결과 (2026-11-04, MacBook, Docker Desktop, 에이전트는 실제 Claude 호출)

| 항목 | 결과 |
|---|---|
| 에이전트 메시지 | 보냄 70, 저장 확인 70, 스트림 수신 70, 유실 0, 중복 0, 스트림 재접속 1회 (app-a 종료 시) |
| 메시지 분포 | env-a 58 / env-b 12, pg-a 64 / pg-b 6 |
| 부하 생성기 | 23,825건 성공, 에러 0, p99 13ms, 최대 472ms |
| DB 전환 | 쓰기 중단 520ms (체크섬 검증 318ms 포함) |
| 유실 검증 | pg-b에서 커밋된 주문 14,353건 중 유실 0 |
| 데이터 비교 | 7개 테이블 행 수와 체크섬 일치 (pg-b = pg-a, 역방향 복제 동작) |

### 실행 중 발견한 문제

- **앱이 나중에 만든 테이블은 초기 복사가 무한 재시도됨.** PoC는 DB 초기화 시점에만 `replicator`에 SELECT 권한을 주므로, 그 뒤에 앱이 만든 `chat_messages`는 `permission denied`로 tablesync worker가 5초마다 재시작했습니다. `03_wait_sync.sh`는 `copying`에서 멈춘 채 제한 시간을 넘깁니다. `02_start_replication.sh`가 복제 직전에 권한을 다시 부여하도록 고쳤습니다. 사전 점검에서 "복제 계정이 읽을 수 없는 테이블"을 잡아내는 항목도 있어야 합니다.
- **HAProxy 50:50에서도 에이전트 요청은 대부분 env-a로 감.** 25초 동안 env-b는 1건이었습니다. 에이전트가 HTTP 연결을 재사용하기 때문으로 보입니다. 가중치를 0:100으로 바꾸면 모두 env-b로 넘어갑니다.
- **에이전트가 정상 과정을 사고로 해석함.** Phase A에서 env-b 앱이 pg-a에 쓰는 것은 의도된 상태인데, 보안봇과 SRE봇이 "쓰기 경로가 둘로 갈라졌다", "롤백 판단을 미뤄야 한다"고 경고했습니다. 에이전트 프롬프트에 이전 순서(앱 먼저, DB 나중)와 제어판이 계산한 현재 단계를 넣어 해결했습니다.
- **에이전트가 지표를 지어냄.** "p95", "최근 7일 평균" 같은 수치를 근거 없이 말했습니다. 실측 지표를 프롬프트에 넣고, 지표에 없는 숫자는 말하지 않도록 했습니다.
- **부하 시작 버튼이 PgBouncer까지 다시 만듦.** `up --build loadgen`이 의존 서비스도 재생성해서 1초 동안 에러 8건이 났습니다. `--no-deps`로 고쳤습니다.
