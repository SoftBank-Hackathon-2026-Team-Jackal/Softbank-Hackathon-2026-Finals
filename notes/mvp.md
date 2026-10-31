# MVP 설계 (초안 v0.2, 2026-10-31)

> v0.2 변경: 승인 화면 상세 설계(4.7), Git 장부(4.9), 대시보드(4.10) 추가

> 관련 문서: [킥오프 자료](../kickoff.md) · [아이디어 회의록](./2026-10-31-ideation.md)
> 원칙: **가볍게, 그러나 한 경로는 끝까지 실제로 동작하게.** 넓이보다 깊이를 우선한다.

---

## 1. 한 줄 정의

**가동 중인 웹 앱을 스캔해 지도로 만들고, 도메인별 Skill이 이전 계획을 세우고, 샌드박스에서 검증해 승인받으면, 트래픽과 DB(dump + CDC)까지 무중단으로 다른 환경에 옮기는 플랫폼**

## 2. MVP 범위

### 포함

| 영역 | MVP에서 하는 것 |
|---|---|
| 이전 경로 | **하나의 대표 경로**만 지원: 환경 A의 VM → 환경 B의 VM (B는 다른 클라우드 또는 온프레미스 PC) |
| 앱 | 예선 앱 재사용 (컨테이너 1개 + PostgreSQL 16) |
| DB | 양쪽 모두 **VM에 직접 띄운 PostgreSQL 16**, 논리 복제로 CDC |
| 네트워크 | **WireGuard** 메시로 환경 간 사설망 구성 |
| 트래픽 | 엣지 프록시(HAProxy) 가중치 전환 + DB 앞단 PgBouncer |
| 보안 | **읽기 전용 점검과 시각화**만 (공개 포트, 암호화, 권한, 시크릿 노출) |
| AI | Skill 기반 계획 수립 + 샌드박스에서 코드 수정과 테스트 |

### 제외 (확장 후보)

- 관리형 DB(RDS, Cloud SQL) 이전 → 설정 차이만 문서화
- 이종 DB 엔진 이전, 오브젝트 스토리지, AI 리소스 이전, 비용 최적화
- 보안 문제의 자동 수정 (MVP에서는 탐지와 시각화만)
- 3개 이상 환경 동시 관리

## 3. 전체 흐름

```
Scan → Map → Plan(Skills + Orchestrator) → Rehearse(Sandbox) → Approve
     → Provision → Phase A(트래픽 전환) → Phase B(DB 전환 + 역방향 CDC) → Verify / Rollback
```

## 4. 구성 요소

### 4.1 Scanner

| 입력 소스 | 수집하는 것 |
|---|---|
| 클라우드 API (VM 목록, 방화벽 규칙) | 인스턴스, 공개 IP, 열린 포트 |
| SSH + `docker inspect` | 실행 중인 컨테이너, 이미지, 환경 변수 이름, 포트 |
| PostgreSQL 카탈로그 (`precheck.sql`) | 버전, `wal_level`, 테이블별 PK 유무, 시퀀스, 확장, DB 크기 |
| 소스 코드 (import·호출 패턴 검색) | 클라우드 SDK 의존성 (예: `boto3`, `@aws-sdk/*`, `google-cloud-*`) |

출력은 아래의 Map입니다.

### 4.2 Map (클라우드 중립 공통 모델, 최소 스키마)

```yaml
environments:
  - id: env-a
    kind: cloud            # cloud | onprem
    provider: aws          # aws | gcp | ncp | local
resources:
  - id: app-web
    type: compute.container
    env: env-a
    attrs: { image: "app:1.4", port: 8080, env_keys: [DATABASE_URL, S3_BUCKET] }
  - id: app-db
    type: db.postgres
    env: env-a
    attrs: { version: 16, wal_level: replica, size_mb: 120, tables_without_pk: [audit_log] }
edges:
  - { from: app-web, to: app-db, kind: connects }
findings:                  # 보안 점검 결과 (시각화에 사용)
  - { resource: app-db, rule: db-public-port, severity: high }
```

### 4.3 Skills (MVP 5개)

| Skill | 판단하는 것 (LLM) | 실행하는 것 (검증된 스크립트) |
|---|---|---|
| `db-postgres` | 사전 점검 결과 해석, 위험 식별 (PK 없는 테이블 등), 대상 사양 | `precheck.sql`, `start_replication.sh`, `check_lag.sql`, `verify_checksum.py`, `switchover.sh`, `reverse_replication.sh` |
| `compute` | 대상 VM 사양, 환경 변수 매핑, 헬스 체크 경로 | Terraform 모듈, `deploy_container.sh`, `healthcheck.sh` |
| `network-wireguard` | 주소 대역, 피어 구성, 방화벽 규칙, 트래픽 전환 단계와 롤백 조건 | `wg_keygen.sh`, `wg0.conf` 템플릿, `haproxy_set_weight.sh` |
| `security-iam` | 보안 기준선 평가, 이전 전후 비교 | `baseline_check.py` (공개 포트, TLS, 권한, 평문 시크릿) |
| `app-code-adapter` | 클라우드 SDK 호출을 찾아 대상 환경에 맞게 수정안 작성 | 샌드박스에서 테스트 실행 |

설계 원칙: **판단은 LLM이 하고, 순서가 중요한 실행은 검증된 스크립트가 한다.**

### 4.4 계획 조각 공통 계약

모든 Skill은 같은 형식으로 출력합니다.

```yaml
domain: db
mapping: [{ from: env-a/app-db, to: env-b/app-db, reason: "..." }]
prechecks: [{ id: wal-level, check: "SHOW wal_level = logical" }]
requires: [network.tunnel(env-a, env-b)]
provides: [db.endpoint(env-b)]
steps:
  - { id: db-replicate, depends_on: [network.tunnel-up], action: ..., verify: ..., rollback: ... }
risks: ["audit_log에 PK 없음 → REPLICA IDENTITY FULL 필요"]
```

### 4.5 Orchestrator

1. Map을 도메인별로 나눠 각 Skill에 전달
2. 계획 조각들을 `requires`/`provides`로 연결해 DAG 생성 후 위상 정렬
3. 충돌 검사 (짝 없는 요구, 순환 의존, 같은 리소스에 대한 상충 계획) → 해당 Skill에 재계획 요청
4. Rehearse 단계로 전달

### 4.6 Rehearse (샌드박스)

- 이전 대상 환경을 흉내 낸 **격리된 컨테이너 환경**에서 앱을 새 설정으로 띄움
- `app-code-adapter`가 수정한 코드로 테스트를 실행하고, 실패하면 수정을 반복 (횟수 제한)
- 결과물: 테스트 결과, 코드 diff, 남은 위험 목록 → 승인 화면으로 전달

### 4.7 Approve UI

승인 화면은 사람과 AI가 만나는 유일한 지점입니다. 승인자가 아래 질문에 답을 얻도록 구성합니다.

| 승인자의 질문 | 보여 줄 방식 |
|---|---|
| 무엇이 어떻게 바뀌는가? | **Before / After 지도** (추가·변경·삭제를 색으로 표시) |
| 어떤 순서로 실행되는가? | **실행 DAG** (Skill별 레인, Phase 구분, 승인 게이트 표시) |
| 왜 이렇게 바꾸는가? | **매핑 표** (기존 → 대상, 담당 Skill, 근거) |
| 무엇이 위험한가? | **위험 표** (심각도, 대응 방법, 확인 체크) |
| 실제로 검증했는가? | **리허설 결과** (테스트 결과, 코드 diff) |
| 문제가 생기면 되돌릴 수 있는가? | 단계마다 **롤백 가능 여부** 표시 |
| 서비스가 얼마나 멈추는가? | **요약 바** (예상 쓰기 중단 시간) |

```
┌─────────────────────────────────────────────────────────────────────┐
│ env-a (AWS) → env-b (GCP)   쓰기 중단 예상 ~1초   롤백 가능 ●        │
│ 리허설 통과 12/12   위험 High 1 · Med 2   계획 v3 (a91f…)            │
├──────────────────────────────┬──────────────────────────────────────┤
│  Before / After 지도          │  실행 DAG                             │
│  [app]──[db 5432 공개]  →    │  network ─●─────────────────────      │
│  [app]──[db 사설망] (초록)    │  db       ───●(복제)───────●(전환)    │
│  + 추가  ~ 변경  − 삭제       │  compute  ──────●(기동)               │
│                              │  traffic  ─────────●10→50→100%       │
│                              │          ▲ 승인 게이트 1  ▲ 게이트 2   │
├──────────────────────────────┴──────────────────────────────────────┤
│ [매핑]  [위험 3]  [리허설 · 코드 diff]  [실행 로그]                    │
├─────────────────────────────────────────────────────────────────────┤
│ ☐ High 위험 1건을 확인했습니다          [거절]  [Phase A까지 승인]     │
└─────────────────────────────────────────────────────────────────────┘
```

- **단계별 승인 게이트 2개:** 게이트 1은 Phase A(트래픽 전환) 시작 전, 게이트 2는 Phase B(DB 전환) 직전입니다. 게이트 2에서는 실제 CDC 지연량과 체크섬 결과를 보고 다시 판단합니다.
- **High 위험은 확인 체크 필수:** 체크하지 않으면 승인 버튼이 비활성화됩니다.
- **승인은 계획 버전(커밋 해시)에 묶습니다:** 재계획되면 기존 승인은 무효가 됩니다.
- **표와 다이어그램은 구조화된 데이터(Map, 계획 조각)를 그대로 렌더링합니다.** LLM은 맨 위의 짧은 자연어 요약만 작성합니다. 그래야 화면과 실제 실행 내용이 정확히 일치합니다.
- 라이브러리 후보: 지도와 DAG는 React Flow (xyflow), 코드 diff는 Monaco Diff Editor 또는 react-diff-viewer

### 4.8 Executor

- DAG 순서대로 `action` → `verify` 실행
- 어느 단계에서든 실패하면 지금까지 실행한 단계의 `rollback`을 역순으로 실행
- 모든 단계의 실행 로그를 저장하고 UI에 실시간으로 표시

### 4.9 Git: 계획과 승인의 장부

역할 분담: **대시보드는 보고 판단하고 실행을 지켜보는 화면, Git은 무엇을 왜 바꿨는지 남기는 장부**입니다.

```
migrations/2026-11-07-env-a-to-env-b/
├── map.before.yaml        # Scanner 결과
├── plan.yaml              # 오케스트레이터가 합친 DAG
├── skills/                # Skill별 계획 조각 (db.yaml, network.yaml, ...)
├── terraform/             # 생성될 IaC
├── runbook.md             # 계획에서 자동 생성한 사람용 런북
└── rehearsal/             # 리허설 테스트 결과
```

- 계획이 만들어지면 플랫폼이 이전 작업마다 브랜치와 PR을 생성합니다. **재계획 = 새 커밋**이므로 계획 버전이 곧 커밋 해시입니다.
- `app-code-adapter`가 고친 앱 코드는 앱 저장소에 별도 PR로 올립니다.
- **승인은 대시보드에서** 하고, 플랫폼이 GitHub API로 PR 승인·병합과 승인 기록(승인자, 계획 해시, 시각)을 남깁니다. 게이트 2는 같은 PR에 코멘트나 태그로 기록합니다.
- **실행은 Git에 맡기지 않습니다.** 실행은 Executor가 맡고 Git은 기록만 맡습니다.

| 검토한 대안 | 채택하지 않은 이유 |
|---|---|
| GitHub PR 페이지에서 직접 승인 | 데모 화면이 두 곳으로 갈라지고, 승인용 표와 다이어그램을 보여 줄 수 없음 |
| GitHub Actions로 실행 (GitOps) | 실행 상태를 실시간으로 보여 주기 어렵고, CDC 지연량을 보며 다음 단계로 넘어가는 판단을 넣기 어려움 |

### 4.10 대시보드 (웹)

최종 발표는 슬라이드가 금지되고 설계 문서와 데모로만 진행되므로, **대시보드가 사실상 발표 화면**입니다.

| 우선순위 | 화면 | 내용 | 대응하는 데모 장면 |
|---|---|---|---|
| **1** | 실시간 이전 현황 | 트래픽 가중치 그래프, CDC 지연량, p99 지연, 양쪽 DB 행 수, 단계별 실행 로그 | 가동 중인 앱의 이전 |
| **1** | 승인 화면 | 4.7의 구성 | AI 샌드박스 점검·수정 |
| **2** | Map | 환경과 리소스 그래프, 보안 점검 결과를 색으로 표시 | 보안 시각화 |
| 3 | 개요 | 환경별 상태와 보안 점수 카드 | |
| 3 | 이력 | 지난 이전 작업 목록, 각 작업의 Git PR 링크 | 거버넌스 |

- 데이터 흐름: 백엔드가 HAProxy 통계, `pg_stat_*` 뷰, Executor 로그를 수집해 SSE나 WebSocket으로 전송합니다. OpenTelemetry는 확장 단계에서 붙입니다.
- 범위 관리: 우선순위 1인 두 화면을 먼저 완성하고, 개요와 이력은 시간이 남을 때 만듭니다.

```
Skills → plan.yaml 커밋 → PR 생성 → 대시보드에서 승인 → PR 병합 + 승인 기록
                                                      ↓
                                Executor 실행 → 대시보드에 실시간 표시
```

## 5. 네트워크와 데이터 이전 상세

### 5.1 WireGuard 토폴로지

```
env-a VM (10.100.0.1) ◀──── WireGuard (UDP 51820) ────▶ env-b VM (10.100.0.2)
   app, PostgreSQL(publisher)                           app, PostgreSQL(subscriber)
   HAProxy, PgBouncer
```

- `network-wireguard` Skill이 키 쌍을 생성하고 `wg0.conf`를 배포
- PostgreSQL은 **WireGuard 주소(10.100.0.0/24)에서만 5432를 열고**, 공개 인터페이스에서는 닫음 → 보안 점검 항목과 연결됨
- 온프레미스 PC가 NAT 뒤에 있으면 PC 쪽에서 `PersistentKeepalive`를 설정해 먼저 연결을 염

### 5.2 Phase A: 트래픽 전환

1. env-b에 앱 기동, 이때 DB 연결은 **env-a의 PgBouncer**(WireGuard 경유)
2. HAProxy 가중치 10 → 50 → 100 (각 단계에서 오류율·지연 확인)
3. 오류율이 임계값을 넘으면 가중치를 즉시 원래대로 되돌림

### 5.3 Phase B: DB 전환

1. (Phase A 이전부터) 논리 복제로 초기 복사 + CDC 진행
2. 지연량 0 확인, 행 수·체크섬 검증
3. PgBouncer `PAUSE` → 정방향 구독 비활성화 → 시퀀스 동기화
4. 역방향 복제 생성 (env-b → env-a, `copy_data = false`)
5. PgBouncer 대상을 env-b DB로 변경 → `RESUME`

### 5.4 롤백

- Phase A 중: HAProxy 가중치 복구
- Phase B 이후: 역방향 복제가 살아 있으므로 같은 절차를 반대로 실행

## 6. 데모 시나리오 (3분)

1. **상황 제시 (20초):** "env-a 요금이 인상되었다. 서비스를 멈추지 않고 env-b로 옮긴다."
2. **Scan + Map (30초):** 지도 화면에 리소스와 보안 점검 결과가 표시됨 (예: DB 5432 공개 → 빨간색)
3. **Plan + Rehearse (40초):** Skill별 계획, DAG, 샌드박스에서 AI가 SDK 호출을 고치고 테스트를 통과시키는 로그
4. **Approve → 실행 (60초):** 부하 생성기가 계속 쓰기를 넣는 동안 트래픽 그래프 0 → 100%, CDC 지연 그래프, PgBouncer 전환 순간의 짧은 지연 증가
5. **결과 (30초):** 이전 후 보안 지도에서 DB가 사설망 전용으로 바뀌어 초록색, 롤백 버튼으로 되돌릴 수 있음을 언급

## 7. 기술 스택 (가안)

| 영역 | 후보 |
|---|---|
| 플랫폼 백엔드 | Python (FastAPI) 또는 TypeScript, 예선 시스템에 맞춰 결정 |
| AI 에이전트 | Claude Agent SDK + Agent Skills |
| 대시보드 | 예선 UI 확장, React Flow (지도·DAG), Monaco Diff Editor, SSE/WebSocket |
| 계획·승인 기록 | Git + GitHub API (브랜치, PR, 승인 기록) |
| IaC | Terraform |
| 네트워크 | WireGuard |
| 트래픽 | HAProxy (Runtime API로 가중치 변경), PgBouncer |
| DB | PostgreSQL 16 논리 복제 |
| 샌드박스 | Docker 컨테이너 (네트워크 격리) |

## 8. 작업 순서 (본선 11/7까지)

| 기간 | 작업 | 산출물 |
|---|---|---|
| 11/1 ~ 11/2 | **CDC PoC** (Docker Compose: PG 2대 + PgBouncer + 부하 생성기, 전환·롤백 왕복) / Map 스키마와 계획 조각 계약 확정 | 로컬에서 무중단 전환 성공 / 스키마 문서 |
| 11/2 ~ 11/3 | WireGuard로 실제 두 환경 연결, PoC를 실제 VM 위에서 재현 | 환경 간 전환 성공 |
| 11/3 ~ 11/5 | Skill 5개 병렬 개발 (담당자별), Scanner, Orchestrator | 계획 조각 출력, DAG 생성 |
| 11/5 ~ 11/6 | Rehearse, Git 기록, 대시보드(승인 화면 + 실시간 이전 현황), Executor 연결 | 처음부터 끝까지 한 번 동작 |
| 11/6 | 데모 리허설, 설계 문서 정리 | 제출용 링크 |
| 11/7 ~ 11/8 | 현장 개발: 다듬기와 확장 (관리형 DB, 보안 자동 수정 등) | 최종 데모 |

## 9. 미결정 사항

- [ ] 대표 이전 경로의 env-a와 env-b를 실제로 무엇으로 할지 (예: AWS → GCP, AWS → 온프레미스 PC)
- [ ] 예선 시스템의 언어와 구조, 재사용 범위
- [ ] Skill별 담당자
- [ ] HAProxy를 어디에 둘지 (env-a에 두면 env-a가 단일 장애 지점이 됨 → MVP에서는 허용하고 문서에 한계로 명시)
- [ ] 샌드박스의 범위 (코드 테스트만 할지, 인프라 적용까지 흉내 낼지)
