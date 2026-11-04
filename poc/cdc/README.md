# CDC PoC: PostgreSQL 논리 복제로 무중단 DB 전환

[CDC 설계](../../notes/cdc.md) 7절의 PoC입니다. 쓰기가 계속 들어오는 상태에서 DB를 pg-a에서 pg-b로 옮기고, 역방향 복제로 다시 되돌릴 수 있는지 로컬에서 검증합니다.

## 구성

```
loadgen ──▶ PgBouncer (transaction 모드) ──▶ pg-a ══ 논리 복제 ══▶ pg-b
 초당 50건                 │ 전환 시 대상만 바꿈        (전환 후에는 pg-b ══▶ pg-a 역방향)
                           └──────────────────────────────▶ pg-b
toolbox: scripts/ 를 실행하는 컨테이너 (psql, pg_dump)
```

| 서비스 | 내용 |
|---|---|
| `pg-a`, `pg-b` | PostgreSQL 16, `wal_level=logical`. pg-a에만 스키마가 있고, 기존 데이터는 `scripts/seed.sh`가 만듭니다 (쇼핑몰 7개 테이블, SCALE 1 ≈ 60MB, 100 ≈ 4.4GB) |
| `pgbouncer` | 앱이 접속하는 유일한 주소. `PAUSE`, `RELOAD`, `RECONNECT`, `RESUME`으로 대상을 바꿉니다 |
| `loadgen` | 주문 INSERT, 일부 UPDATE, `audit_log` INSERT와 주기적 DELETE. 커밋에 성공한 주문 ID를 `results/committed_ids.txt`에 남깁니다 |
| `toolbox` | 스크립트 실행 환경. 실제 환경에서는 같은 스크립트에 접속 URL만 바꿔서 실행합니다 |

`audit_log`는 일부러 PK 없이 만들었습니다. 사전 점검이 이 테이블을 잡아내는지 확인하기 위해서입니다.

## 실행

Docker만 있으면 됩니다.

```bash
scenarios/01_round_trip.sh                 # 전환과 롤백을 한 번씩 하고 성공 기준으로 판정
scenarios/02_subscriber_outage.sh          # 복제 중 pg-b를 20초 멈췄다가 재시작
scenarios/03_missing_replica_identity.sh   # 사전 점검을 건너뛰면 무엇이 깨지는지 확인
SCALE=2 RATE=100 scenarios/04_realistic.sh # 운영에 가까운 이전 (클라우드에서는 SCALE=100 RATE=200 ≈ 4.4GB)
scenarios/05_busy_switchover.sh            # 배치가 행을 잠근 순간에 전환을 시작하면 (전환 시점 대기 효과)
scenarios/06_physical_copy.sh              # 초기 복사를 물리 복사(PostgreSQL 17 pg_createsubscriber)로
```

시나리오는 기본으로 빠른 전환(`05_switchover_fast.py`)을 씁니다. `SWITCHOVER=classic`이면 예전 `05_switchover.sh`를 씁니다. 가볍게 확인할 때는 `SCALE=10 RATE=200 STEADY_SEC=20 HOLD_SEC=20 scenarios/04_realistic.sh`(약 450MB, 한 번에 4~5분)를 권합니다.

같은 Docker에서 다른 작업 폴더의 PoC가 이미 돌고 있으면, 시나리오가 시작할 때 실행하는 `down -v`가 그 환경까지 지웁니다. 이때는 `COMPOSE_PROJECT_NAME`을 다르게 주고, PgBouncer의 호스트 포트(6432)를 열지 않는 덮어쓰기 파일을 `COMPOSE_FILE`에 더합니다.

단계별로 직접 실행하려면 다음 순서를 따릅니다.

```bash
docker compose up -d --build --wait
docker compose --profile load up -d --build loadgen     # 부하 시작. docker compose logs -f loadgen 으로 관찰

bin/tool 00_precheck.sh pg-a                 # 사전 점검
bin/tool 01_copy_schema.sh pg-a pg-b         # 스키마 복사 + marker 테이블
bin/tool 02_start_replication.sh pg-a pg-b   # REPLICA IDENTITY 보정 → publication → subscription (copy_data = true)
bin/tool 03_wait_sync.sh pg-a pg-b           # copying → catching_up → streaming
bin/tool 05_switchover.sh pg-a pg-b          # 전환 (역방향 복제까지 생성)
bin/tool 06_rollback.sh pg-a                 # 롤백

docker compose --profile load stop loadgen
bin/tool 07_check_lost.sh pg-a               # 커밋된 쓰기가 모두 있는지
bin/tool 04_compare.sh pg-a pg-b             # 행 수와 체크섬 비교

docker compose --profile load --profile tools down -v   # 정리
```

## 스크립트

| 스크립트 | 하는 일 |
|---|---|
| `00_precheck.sh`, `precheck.sql` | 버전, `wal_level`, 슬롯 여유, DB 크기, PK 없는 테이블, 시퀀스, Large Object, unlogged 테이블, 확장 |
| `01_copy_schema.sh` | `mig.marker` 테이블 생성 후 `pg_dump --schema-only`로 스키마 복사. 대상이 비어 있지 않으면 중단 |
| `02_start_replication.sh` | PK 없는 테이블에 `REPLICA IDENTITY FULL`, `mig_pub` publication, `mig_from_<원본>` subscription 생성 |
| `03_wait_sync.sh` | `pg_subscription_rel` 상태와 슬롯 지연량으로 단계를 판정. 1초마다 `results/replication-*.jsonl`에 기록 (대시보드 데이터) |
| `04_compare.sh` | `public` 스키마 테이블별 행 수와 md5 비교 |
| `05_switchover_fast.py` | **기본 전환.** PAUSE 안에는 진행 중 트랜잭션 대기, marker 커밋, 스냅샷 고정, 구독 전환, 대상 변경만 남깁니다. 절차는 아래 [빠른 전환](#빠른-전환-2026-11-04) 절에 있습니다. 결과는 `results/switchover-*.json` |
| `readiness.py` | 지금 전환해도 되는지 판단하는 신호(가장 오래된 트랜잭션, 잠금 대기, 지연량, 초당 커밋)를 JSON으로 출력합니다. 에이전트가 읽는 입력이며, 빠른 전환도 PAUSE 직전에 같은 조건을 확인합니다. 판단 방법은 [`skill/switchover-timing.md`](skill/switchover-timing.md) |
| `05_switchover.sh` | (예전 방식, `SWITCHOVER=classic`) (PAUSE 전에 역방향 구독을 꺼진 상태로 생성) PAUSE → marker 도착 확인 → 체크섬 → 정방향 구독 삭제 → 시퀀스 동기화 → 역방향 구독 켜기 → 대상 변경 → RESUME. 체크섬 단계까지 실패하면 RESUME하고 원래 DB로 계속 서비스합니다. 단계별 소요 시간을 `results/switchover-*.json`에 남깁니다 |
| `06_rollback.sh` | 현재 주 DB에서 지정한 DB로 같은 절차를 반대로 실행 |
| `07_check_lost.sh` | `committed_ids.txt`의 주문 ID가 모두 있는지 확인 |
| `02p_prepare_physical.sh`, `physical_clone.sh` | 물리 복사 경로. 원본에 marker 테이블과 REPLICA IDENTITY를 먼저 만들고, `pg-b-clone` 컨테이너가 pg-b 데이터 디렉터리를 `pg_basebackup`으로 채운 뒤 `pg_createsubscriber`로 논리 구독자로 바꿉니다 |
| `reset_node.sh` | 원격 노드의 구독, 슬롯, publication, 스키마를 지워 시작 전 상태로 되돌림 (`RESET_OK=yes` 필요) |

노드 이름 규칙: `pg-a`의 관리 접속은 `PG_A_URL`, 복제 접속 호스트는 `PG_A_REPL_HOST`(기본값은 노드 이름)입니다. 실제 환경에서는 이 환경 변수만 WireGuard 주소로 바꿉니다.

## 결과 (2026-11-03, MacBook, Docker Desktop)

### 시나리오 1: 전환과 롤백 왕복

| 성공 기준 | 결과 |
|---|---|
| 쓰기 중단 2초 이하 | **PASS:** 전환 461ms, 롤백 436ms (아래 개선 후 261ms, 268ms) |
| 부하 생성기 에러 0 | **PASS:** 1,280건 성공, 에러 0 |
| 유실 0 | **PASS:** pg-a와 pg-b 모두 유실 0 |
| 전환 후 데이터 일치 | **PASS:** 3개 테이블 행 수와 체크섬 일치 |

전환 한 번의 단계별 소요 시간(ms)은 다음과 같습니다.

| PAUSE | marker 도착 | 체크섬 | 구독 삭제 + 시퀀스 + 역방향 생성 | 대상 변경 + RESUME |
|---|---|---|---|---|
| 18 | 34 | 210 | 160 | 48 |

부하 생성기 입장에서는 전환하는 순간 한 번만 지연이 약 430ms로 늘었고(평소 p99 20ms), 에러는 없었습니다. PAUSE 동안 PgBouncer가 요청을 붙잡아 두었기 때문입니다. 전환 후 `SHOW SERVERS`와 `pg_stat_activity`로 앱 연결이 모두 pg-b로 옮겨 간 것을 확인했습니다.

### 시나리오 2: 구독자 중단

pg-b를 20초 멈춘 동안 pg-a의 슬롯이 WAL을 계속 붙잡았습니다(5초마다 857kB → 1.4MB → 2.0MB → 2.5MB, 초당 50건 기준 약 110kB/s). 재시작 후 바로 따라잡았고, 유실 0, 체크섬 일치를 확인했습니다. 구독자가 오래 멈추면 원본 디스크가 찬다는 위험이 실제로 보입니다.

### 시나리오 3: REPLICA IDENTITY 누락

PK 없는 `audit_log`를 보정하지 않고 publication을 만들자, **원본 앱의 DELETE가 실패했습니다** (`cannot delete from table "audit_log" because it does not have a replica identity and publishes deletes`). 복제를 시작하는 것만으로 운영 중인 앱이 깨질 수 있으므로, 이 보정은 publication을 만들기 **전에** 해야 합니다.

### 빠른 전환 (2026-11-04)

[전환 중단을 짧게 만드는 기술 정리](../../notes/cdc-short-switchover.md)의 A3~A6과 E1을 `05_switchover_fast.py`에 적용했습니다.

| 시점 | 하는 일 |
|---|---|
| PAUSE 전 | 역방향 구독을 꺼진 상태로 생성, 대상 시퀀스를 원본 값 + 10,000으로 설정, 동기 복제 창 열기 (`synchronous_standby_names`를 정방향 구독으로, 앱은 `synchronous_commit = local`), 전환 가능 시점 대기 |
| PAUSE 안 | marker를 `remote_apply`로 커밋 (대상에 반영되면 돌아오므로 폴링 없음), 두 DB에서 스냅샷 고정과 시퀀스 확인, 정방향 `DISABLE`과 역방향 `ENABLE`, PgBouncer 대상 변경 |
| RESUME 후 | 동기 복제 창 닫기, 정방향 구독 삭제, PAUSE 안에서 고정한 스냅샷으로 두 DB 비교 |

접속은 처음에 한 번만 열고, PAUSE 안에서는 SQL만 보냅니다. 동기 대기는 marker 커밋 하나에만 걸리므로 앱 커밋은 느려지지 않습니다.

| 시나리오 (로컬) | 예전 방식 | 빠른 전환 |
|---|---|---|
| 1. 왕복 (SCALE 1, 초당 50건) | 261ms / 268ms | **18ms / 7ms** |
| 5. 운영에 가까운 이전 (SCALE 10 ≈ 450MB, 초당 200건) | 246ms / 252ms | **18ms / 13ms** |

두 경우 모두 에러 0, 유실 0, 체크섬 일치입니다. 클라우드 결과는 [2단계 README](cloud/README.md)에 있습니다.

### 시나리오 6: 배치 중 전환

배치가 상품 행 전체를 4초 동안 잠근 상태에서 전환을 시작했습니다. 앱의 주문 트랜잭션이 잠금에 막혀 길어지므로, PAUSE가 이 트랜잭션들을 기다립니다.

| | 쓰기 중단 |
|---|---|
| `WAIT_READY_SEC=0` (기다리지 않음) | 2,573ms |
| 기본값 (`ready`까지 기다림) | **5ms** (PAUSE 전에 2,090ms 기다림) |

### 시나리오 7: 물리 복사 (PostgreSQL 17)

SCALE 10(클러스터 475MB)에서 초당 200건을 넣으면서 물리 복사로 시작했습니다.

| 항목 | 결과 |
|---|---|
| `pg_basebackup` | 0.7초 |
| `pg_createsubscriber` (따라잡기, 승격, 구독 생성) | 0.5초 |
| pg-b 중지부터 실시간 동기화까지 | 5.2초 (컨테이너 재시작 포함) |
| 같은 데이터의 논리 복제 초기 복사 | 7초 |
| 이후 전환 / 롤백 | 9ms / 5ms |
| 에러, 유실, 체크섬 | 0, 0, 일치 |

로컬은 디스크와 네트워크가 빨라서 차이가 작습니다. 효과는 대상 DB의 인덱스 갱신이 병목이던 클라우드에서 클 것으로 예상하지만, 아직 측정하지 않았습니다.

## 알게 된 것

- **개선 (2단계 중 반영):** 체크섬을 두 DB에서 동시에 계산하고, 역방향 구독을 PAUSE 전에 꺼진 상태로 미리 만들어 PAUSE 안에서는 `ENABLE`만 하도록 바꿨습니다. 로컬 중단 시간이 약 450ms에서 265ms로 줄었습니다. 자세한 내용은 [2단계 README](cloud/README.md)에 있습니다.
- **전환 중단 시간의 절반이 체크섬이었습니다.** 체크섬은 테이블 전체를 읽으므로 데이터 크기에 비례해 늘어납니다. 큰 DB에서는 PAUSE 안에서는 행 수만 비교하고, 체크섬은 PAUSE 전에 지연 0 상태에서 미리 하거나 전환 후에 하는 방식으로 바꿔야 합니다.
- **PgBouncer는 PAUSE 중 `RELOAD` 후 `RECONNECT`로 대상을 바꿉니다.** 서버 연결이 모두 반납된 상태이므로 새 대상으로 다시 연결되며, 클라이언트 연결은 끊기지 않습니다.
- **PostgreSQL 15부터 `public` 스키마에 일반 사용자가 객체를 만들 수 없습니다.** 앱 역할에 `GRANT CREATE ON SCHEMA public`이 필요했습니다.
- **복제 루프는 정방향 구독을 먼저 지우고 `origin = none`을 함께 써서 막았습니다.**
- **주문 5만 건은 초기 복사가 1초 안에 끝나서 `copying` 단계가 거의 보이지 않습니다.** 시연에서 단계를 보여 주려면 데이터를 늘리거나 `03_wait_sync.sh`의 기록 간격을 줄여야 합니다.

## 2단계: 실제 클라우드

AWS `prod`와 GCP `sbh26-prod` 사이를 WireGuard로 잇고 같은 스크립트로 왕복 시나리오를 통과했습니다(쓰기 중단 약 1초). [cloud/README.md](cloud/README.md)를 참고합니다.

- **동기 대기는 marker 커밋에만 걸어야 합니다.** 처음에는 marker를 커밋한 세션으로 역방향 구독도 `ENABLE`했는데, 같은 순간 정방향 구독(동기 대기 대상)이 꺼지면서 그 커밋이 영원히 돌아오지 않았습니다. marker 직후 세션을 `synchronous_commit = local`로 되돌려 해결했습니다. 왕복 시나리오는 경합에서 운 좋게 이겨 통과했고, 배치가 섞인 시나리오에서 드러났습니다.
- **동기 복제 창이 남으면 노드 초기화도 멈춥니다.** 실패한 전환이 `synchronous_standby_names`를 남기면 구독을 바꾸는 커밋이 모두 동기 대기에 걸립니다. `reset_node.sh`는 이 설정을 가장 먼저 지웁니다.
- **전환 직후 전체 체크섬은 앱을 느리게 합니다.** 450MB에서 새 DB가 체크섬을 계산하는 15초 동안 앱 최대 지연이 1.1초까지 올랐습니다. 100MB가 넘는 DB는 기본으로 `max(id)`만 비교하고(`VERIFY_AFTER=auto`), 전체 체크섬은 한가한 시간에 `04_compare.sh`로 따로 합니다.
- **`pg_createsubscriber`는 대기 서버의 접속 계정을 `-P`로 준 계정으로 바꿉니다.** replication 접속을 `replicator`에만 허용하면 대기 서버가 원본에 붙지 못해 따라잡기에서 멈춥니다. `init/00-hba-replication.sh`가 모든 계정의 replication 접속을 비밀번호 인증으로 허용합니다.

## 아직 하지 않은 것

- 물리 복사를 클라우드에서 측정하기. env-b는 WireGuard만 열려 있어 pg-b를 멈추고 데이터 디렉터리를 채울 방법이 없습니다
- 대상 연결 미리 열기 (A7). 전환 직후 첫 요청들이 대상 DB에 연결을 새로 맺습니다

- 대용량 경로(방법 B: 스냅샷 내보내기 + `pg_dump --snapshot`)
- `cloud-migration-platform`의 `copy_data` Activity로 옮기기 (단계별 Activity로 나누고, 게이트 2에서 지연량을 보고 승인)
- 비밀번호는 PoC용 고정값입니다. 실제 환경에서는 Secret으로 주입해야 합니다
