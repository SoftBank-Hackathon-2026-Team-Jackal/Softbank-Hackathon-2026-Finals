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
| `pg-a`, `pg-b` | PostgreSQL 16, `wal_level=logical`. pg-a에만 스키마와 기존 데이터(주문 5만 건)가 있습니다 |
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
```

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
| `05_switchover.sh` | PAUSE → marker 도착 확인 → 체크섬 → 정방향 구독 삭제 → 시퀀스 동기화 → 역방향 구독 생성 → 대상 변경 → RESUME. 체크섬 단계까지 실패하면 RESUME하고 원래 DB로 계속 서비스합니다. 단계별 소요 시간을 `results/switchover-*.json`에 남깁니다 |
| `06_rollback.sh` | 현재 주 DB에서 지정한 DB로 같은 절차를 반대로 실행 |
| `07_check_lost.sh` | `committed_ids.txt`의 주문 ID가 모두 있는지 확인 |

노드 이름 규칙: `pg-a`의 관리 접속은 `PG_A_URL`, 복제 접속 호스트는 `PG_A_REPL_HOST`(기본값은 노드 이름)입니다. 실제 환경에서는 이 환경 변수만 WireGuard 주소로 바꿉니다.

## 결과 (2026-11-03, MacBook, Docker Desktop)

### 시나리오 1: 전환과 롤백 왕복

| 성공 기준 | 결과 |
|---|---|
| 쓰기 중단 2초 이하 | **PASS:** 전환 461ms, 롤백 436ms |
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

## 알게 된 것

- **전환 중단 시간의 절반이 체크섬입니다.** 체크섬은 테이블 전체를 읽으므로 데이터 크기에 비례해 늘어납니다. 큰 DB에서는 PAUSE 안에서는 행 수만 비교하고, 체크섬은 PAUSE 전에 지연 0 상태에서 미리 하거나 전환 후에 하는 방식으로 바꿔야 합니다.
- **PgBouncer는 PAUSE 중 `RELOAD` 후 `RECONNECT`로 대상을 바꿉니다.** 서버 연결이 모두 반납된 상태이므로 새 대상으로 다시 연결되며, 클라이언트 연결은 끊기지 않습니다.
- **PostgreSQL 15부터 `public` 스키마에 일반 사용자가 객체를 만들 수 없습니다.** 앱 역할에 `GRANT CREATE ON SCHEMA public`이 필요했습니다.
- **복제 루프는 정방향 구독을 먼저 지우고 `origin = none`을 함께 써서 막았습니다.**
- **주문 5만 건은 초기 복사가 1초 안에 끝나서 `copying` 단계가 거의 보이지 않습니다.** 시연에서 단계를 보여 주려면 데이터를 늘리거나 `03_wait_sync.sh`의 기록 간격을 줄여야 합니다.

## 아직 하지 않은 것

- 실제 클라우드(AWS `prod`, GCP `sbh26-prod`)와 WireGuard 위에서 재현
- 대용량 경로(방법 B: 스냅샷 내보내기 + `pg_dump --snapshot`)
- `cloud-migration-platform`의 `copy_data` Activity로 옮기기 (단계별 Activity로 나누고, 게이트 2에서 지연량을 보고 승인)
- 비밀번호는 PoC용 고정값입니다. 실제 환경에서는 Secret으로 주입해야 합니다
