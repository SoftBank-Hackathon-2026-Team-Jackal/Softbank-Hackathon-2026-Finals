# CDC 설계: PostgreSQL 논리 복제 (v0.1, 2026-10-31)

> 관련 문서: [MVP 설계](./mvp.md) · [아이디어 회의록](./2026-10-31-ideation.md) · [전환 중단을 짧게 만드는 기술](./cdc-short-switchover.md)

---

## 1. 결정 요약

| 항목 | 결정 |
|---|---|
| CDC 수단 | **PostgreSQL 16 내장 논리 복제** (publication / subscription). 별도 CDC 도구 없음 |
| Debezium | 사용하지 않음. **이종 DB 이전으로 확장할 때의 대안**으로 기록 |
| 덤프 + CDC | **방법 A (MVP):** 스키마만 `pg_dump`, 데이터는 `copy_data = true`로 초기 복사와 CDC를 자동으로 이어서 처리 |
| | **방법 B (대용량용):** 슬롯 생성 시 스냅샷을 내보내고 `pg_dump --snapshot`으로 데이터 덤프 → `copy_data = false`로 CDC만 시작 |
| 전환 제어 | PgBouncer `PAUSE` / `RESUME` + marker 행으로 마지막 변경 도착 확인 |
| 롤백 | 전환 직후 역방향 복제(pg-b → pg-a) 생성 |
| 네트워크 | WireGuard 사설망 (10.100.0.0/24) |

---

## 2. CDC의 원리

### 2.1 출발점: WAL

- PostgreSQL은 데이터를 바꿀 때 테이블 파일보다 **WAL(Write-Ahead Log)**에 먼저 기록함
- 각 기록에는 위치 번호 **LSN**(Log Sequence Number)이 붙음
- CDC = **WAL을 읽어서 다른 DB에 똑같이 재생하는 것**
- `wal_level = logical`로 설정해야 행 단위 변경을 복원하는 데 필요한 정보가 WAL에 기록됨

```
WAL:  ... | LSN 100: INSERT orders(id=5) | LSN 101: UPDATE orders(id=3) | LSN 102: COMMIT | ...
```

### 2.2 구성 요소

```
            pg-a (기존 DB, publisher)                         pg-b (새 DB, subscriber)
 ┌──────────────────────────────────────────┐          ┌──────────────────────────────┐
 │ 앱의 쓰기 → [WAL] → [복제 슬롯] → [논리 디코딩] │  스트림   │  [apply worker] → [테이블]     │
 │                                 ↓         │ ───────→ │                              │
 │                          [publication]    │ ←─────── │  "LSN 150까지 반영했다"         │
 └──────────────────────────────────────────┘  피드백   └──────────────────────────────┘
```

| 구성 요소 | 위치 | 하는 일 |
|---|---|---|
| 복제 슬롯 | pg-a | WAL 안의 책갈피. 구독자가 받아 간 위치를 기억하고, 받아 가기 전까지 이후 WAL을 지우지 못하게 붙잡음 |
| 논리 디코딩 (`pgoutput`) | pg-a | WAL을 행 단위 변경으로 변환. **커밋된 트랜잭션만, 커밋 순서대로** 내보냄 |
| publication | pg-a | 어떤 테이블의 변경을 내보낼지 정하는 필터 |
| subscription | pg-b | pg-a에 접속해 변경 스트림을 받음 |
| apply worker | pg-b | 받은 변경을 적용하고, 반영한 위치를 pg-a에 알림 |

- UPDATE와 DELETE는 대상 행을 찾을 키가 필요함 → 기본은 PK, PK가 없으면 `REPLICA IDENTITY FULL`

### 2.3 시간 순서

1. **구독 생성:** pg-a에 복제 슬롯 생성 (LSN 100)
2. **초기 복사 (덤프 역할):** LSN 100 시점의 스냅샷 기준으로 테이블 데이터를 복사
3. **복사 중 들어온 변경:** LSN 101~150의 쓰기는 WAL에 쌓이고 슬롯이 붙잡아 둠
4. **따라잡기:** 복사가 끝나면 101~150을 순서대로 적용 → **빠지는 구간도, 두 번 들어가는 구간도 없음**
5. **정상 상태:** 수십~수백 ms 안에 반영. `지연량 = pg-a 현재 WAL 위치 − 슬롯이 확인받은 위치`
6. **전환:** 아래 5장

> 정확히는 테이블마다 동기화 작업자가 복사를 수행하고, 끝난 테이블부터 메인 스트림에 합류함. 원리는 같음.

---

## 3. 왜 Debezium이 아닌가

변경을 읽는 원리(복제 슬롯 + 논리 디코딩)는 같음. 차이는 **읽은 변경을 어디로 보내는가**.

```
[논리 복제]  pg-a ──WAL 스트림──→ pg-b                            (추가 구성 요소 없음)
[Debezium]   pg-a ──→ Debezium ──→ Kafka ──→ JDBC Sink ──→ pg-b    (Kafka, Connect, 커넥터)
```

| | PostgreSQL 논리 복제 | Debezium + Kafka |
|---|---|---|
| 추가로 띄울 것 | 없음 | Kafka, Kafka Connect, Source/Sink 커넥터 |
| 트랜잭션 단위 | 트랜잭션 단위로 순서대로 적용 | Sink 커넥터에서 트랜잭션 경계가 흐려지기 쉬움 |
| 초기 복사 + CDC 경계 | 자동으로 맞춰짐 | 스냅샷 모드로 지원되지만 Sink 설정 필요 |
| 역방향 복제 (롤백) | 구독 하나 추가 | 파이프라인을 반대로 하나 더 구성 |
| 이종 대상 (MySQL, BigQuery 등) | 불가능 | 가능 |

**결론:** MVP는 PostgreSQL → PostgreSQL이므로 논리 복제가 단순하고 안정화하기 쉬움. 이종 DB 이전으로 확장하면 Debezium을 검토함.

---

## 4. 덤프와 CDC를 잇는 두 가지 방법

### 방법 A: 자동 방식 (MVP 채택)

```bash
# 1. 스키마만 덤프 (논리 복제는 DDL을 옮기지 않음)
pg_dump --schema-only "$PG_A" | psql "$PG_B"
```
```sql
-- 2. pg-a
CREATE PUBLICATION mig_pub FOR ALL TABLES;

-- 3. pg-b: 슬롯 생성 → 초기 복사 → CDC가 이어서 진행
CREATE SUBSCRIPTION mig_sub
  CONNECTION 'host=10.100.0.1 dbname=app user=replicator'
  PUBLICATION mig_pub
  WITH (copy_data = true);
```

- `copy_data = true`가 데이터 덤프 역할
- 진행 상태: `pg_subscription_rel`의 테이블별 `srsubstate` (`i` 초기화 → `d` 복사 중 → `s`/`r` 동기화 완료)

### 방법 B: 명시적 방식 (대용량용, 설계 문서에 경로로 남김)

```
1. pg-a에 복제 연결로 슬롯 생성 + 스냅샷 내보내기
   CREATE_REPLICATION_SLOT mig_slot LOGICAL pgoutput EXPORT_SNAPSHOT
   → 스냅샷 이름과 LSN 반환
   ※ 덤프가 끝날 때까지 이 연결을 열어 둬야 스냅샷이 유지됨 → Python 등 프로그램 필요

2. 그 스냅샷으로 데이터 덤프 → pg-b에 복원
   pg_dump --snapshot=<스냅샷 이름> -Fd -j 4 "$PG_A"  →  pg_restore

3. 만들어 둔 슬롯으로 CDC만 시작
   CREATE SUBSCRIPTION mig_sub ...
     WITH (copy_data = false, create_slot = false, slot_name = 'mig_slot');
```

| | 방법 A | 방법 B |
|---|---|---|
| 구현 난이도 | 낮음 (SQL 몇 줄) | 높음 (연결 유지 프로그램 필요) |
| 대용량 데이터 | 테이블 단위 복사 | **병렬 덤프(`-j`)로 더 빠름** |
| 덤프 파일 | 남지 않음 | 남음 (백업으로도 활용) |

**확장 아이디어:** `db-postgres` Skill이 DB 크기를 보고 A와 B 중 하나를 고르게 함 → "AI가 상황에 따라 판단한다"는 예시

**대시보드 표시:** 내부적으로는 한 명령이지만, `pg_subscription_rel` 상태로 **초기 복사(덤프) → CDC 따라잡기 → 실시간 동기화**를 단계별로 나눠 보여 줌

---

## 5. 전환 (switchover)

```
1. PgBouncer PAUSE                     새 트랜잭션 대기 (연결은 유지, 앱 에러 없음)
2. pg-a에 marker 행 INSERT              → pg-b에 나타날 때까지 대기
3. DROP SUBSCRIPTION mig_sub (pg-b)    정방향 종료 + pg-a의 슬롯 정리
4. 시퀀스 동기화                          pg-a 값을 읽어 pg-b에 setval
5. 역방향 복제 켜기                       PAUSE 전에 pg-a에 SUBSCRIPTION(copy_data = false, enabled = false)을 미리 만들고 여기서 ENABLE
6. PgBouncer 대상을 pg-b로 변경 → RESUME
```

- **marker 행을 쓰는 이유:** 변경은 커밋 순서대로 전달되므로 marker가 도착했다면 그 앞의 모든 변경도 도착한 것. 지연량 숫자는 pg-b의 피드백이 주기적으로만 전송되어 늦게 갱신될 수 있음
- **정방향을 먼저 끄는 이유:** 정방향과 역방향이 동시에 살아 있으면 변경이 양쪽을 오가는 루프가 생길 수 있음. PostgreSQL 16 이상이면 `origin = none`으로 한 번 더 방지
- **PgBouncer 설정:** `pool_mode = transaction` (세션 모드는 연결이 오래 잡혀 있어 `PAUSE`가 늦게 끝남)
- **롤백:** 역방향 복제가 살아 있으므로 같은 절차를 반대 방향으로 실행

---

## 6. 복제되지 않는 것과 운영상 주의점

| 항목 | 대응 |
|---|---|
| DDL | 시작 전에 스키마 복사, 이전 중 DDL 금지 |
| 시퀀스 값 | 전환할 때 직접 동기화 |
| Large Object | 사전 점검에서 사용 여부 확인 |
| PK 없는 테이블 | `REPLICA IDENTITY FULL` 설정 |
| 슬롯이 WAL을 붙잡음 | 구독자가 멈추면 pg-a 디스크가 계속 참 → 지연량 경보, 중단·실패 시 슬롯 삭제 단계 필수 |
| TRUNCATE | 복제되지만 대상에 FK가 있으면 실패할 수 있음 |

---

## 7. PoC 계획

> **2026-11-03 구현 완료:** [`poc/cdc`](../poc/cdc/README.md). 쓰기 중단 436~461ms, 에러 0, 유실 0, 체크섬 일치로 네 가지 성공 기준을 모두 통과했습니다. 전환 중단 시간의 절반이 체크섬이라는 점, REPLICA IDENTITY 누락이 원본 앱의 DELETE를 깨뜨린다는 점을 확인했습니다. 상세 결과는 PoC README에 있습니다.
>
> **같은 날 2단계 완료:** [`poc/cdc/cloud`](../poc/cdc/cloud/README.md). AWS `prod`와 GCP `sbh26-prod`를 WireGuard로 잇고 같은 스크립트로 왕복했습니다. 쓰기 중단은 처음 1.8초였고, 역방향 구독을 PAUSE 전에 미리 만들고 체크섬을 병렬로 계산하도록 바꿔 약 1초로 줄였습니다. 이 방식은 5장 절차에도 반영했습니다.
>
> **5GB 시나리오:** 쇼핑몰 4.4GB, 초당 200 트랜잭션으로 왕복했습니다. 쓰기 중단 1.3~1.5초, 에러 0, 유실 0, 체크섬 일치입니다. 초기 복사는 13.2MB/s로, 네트워크(156MB/s)가 아니라 대상 DB의 인덱스 갱신이 병목이었습니다. 자세한 내용은 [2단계 README](../poc/cdc/cloud/README.md)의 5GB 시나리오 절에 있습니다.

### 성공 기준

| 지표 | 기준 |
|---|---|
| 쓰기 중단 시간 (PAUSE → RESUME) | 2초 이하 |
| 부하 생성기 에러 수 | 0 |
| 유실된 쓰기 | 0 (클라이언트가 커밋 성공을 확인한 모든 ID가 pg-b에 존재) |
| 전환 후 데이터 | 행 수와 체크섬 일치 |

### 구성

```
poc/cdc/
├── docker-compose.yml      # pg-a, pg-b (wal_level=logical), pgbouncer (transaction), loadgen
├── schema.sql              # orders (bigserial PK), audit_log (PK 없음: 사전 점검 검증용)
├── loadgen/loadgen.py      # 초당 50건 쓰기, 커밋 성공 ID·지연 시간을 로컬에 기록
├── scripts/                # → db-postgres Skill의 scripts/로 이동 예정
│   ├── precheck.sql
│   ├── 01_copy_schema.sh
│   ├── 02_start_replication.sh
│   ├── 03_wait_sync.sh
│   ├── 04_verify.py
│   ├── 05_switchover.sh
│   └── 06_rollback.sh
└── results/                # 실행마다 측정 결과 JSON (→ 대시보드 데이터)
```

### 시나리오

1. 정방향 전환: pg-a → pg-b
2. 전환 후 롤백: pg-b에 쓴 데이터가 역방향 복제로 pg-a에 반영되는지 확인
3. 장애 주입: 복제 중 pg-b를 중지했다가 재시작 → 따라잡는지, 그동안 pg-a의 WAL이 쌓이는지 확인
4. 사전 점검: PK 없는 테이블을 잡아내는지 확인
