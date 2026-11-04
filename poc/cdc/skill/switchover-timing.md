# 전환 시점 고르기 (`db-postgres` Skill 참고 문서)

전환 스크립트(`05_switchover_fast.py`)를 언제 실행할지 정합니다. 쓰기 중단 시간의 하한은 PAUSE 순간에 열려 있는 가장 긴 트랜잭션입니다. 긴 작업이 없는 순간을 고르면 중단은 100ms 안팎이고, 잘못 고르면 몇 초가 됩니다.

판단은 에이전트가 하고, 실행은 스크립트가 합니다. `PAUSE`나 `ALTER SUBSCRIPTION`을 직접 실행하지 않습니다.

## 입력

`scripts/readiness.py <현재 주 DB> [관찰 시간(초)]`가 JSON 한 줄을 출력합니다.

| 필드 | 의미 |
|---|---|
| `ready` | `longest_xact_ms <= 200`, `lock_waiters == 0`, 지연 1MB 이하. 스크립트도 PAUSE 직전에 같은 조건을 다시 확인합니다 |
| `longest_xact_ms`, `top` | 가장 오래된 트랜잭션과 그 사용자, 대기 이벤트, 쿼리. 배치인지 평소 트래픽인지 구분하는 근거입니다 |
| `lock_waiters` | 잠금을 기다리는 세션 수. 0이 아니면 대개 한 트랜잭션이 다른 요청이 필요한 행을 잡고 있다는 뜻입니다 |
| `lag_bytes` | 정방향 복제 지연량 |
| `commits_per_sec` | 관찰 시간 동안의 초당 커밋 수 |

## 절차

1. `readiness.py <주 DB> 1`을 몇 초 간격으로 30초 이상 읽습니다. 값 하나가 아니라 추세를 봅니다.
2. 다음 중 하나라도 해당하면 시작하지 않습니다.
   - `top`에 앱이 아닌 사용자(`postgres`, 배치나 cron 계정)가 있거나, 많은 행을 건드리는 문장(`UPDATE ... WHERE id IN (SELECT ...)`, `DELETE ... WHERE created_at <`, `VACUUM FULL`, `CREATE INDEX`)이 있습니다. 끝날 때까지 기다립니다.
   - 두 번 연속으로 `lock_waiters > 0`입니다.
   - `lag_bytes`가 계속 늘고 있습니다 (대상이 뒤처지는 중).
   - 사용자나 Map이 알려 준 배치 시간이 곧 시작됩니다.
3. `commits_per_sec`가 최근 평균보다 낮은 순간을 고릅니다. 진행 중인 트랜잭션이 적을수록 대기가 짧습니다.
4. 기본값 `WAIT_READY_SEC=30`으로 `05_switchover_fast.py <원본> <대상>`을 실행합니다. 스크립트는 `ready`가 될 때까지 기다린 뒤에 PAUSE합니다. "전환 가능 시점이 오지 않았습니다"로 끝나면 PAUSE는 하지 않은 것이므로, 1단계로 돌아가고 무엇이 막았는지(`대기:` 로그)를 보고합니다.
5. 결과 JSON의 `write_pause_ms`와 `wait_ready (PAUSE 전)`을 보고합니다.

## 스크립트도 확인하는 이유

에이전트가 판단한 뒤 PAUSE하기 전 사이에 긴 트랜잭션이 시작될 수 있습니다. 스크립트가 PAUSE 직전에 다시 확인하므로 그 틈은 약 20ms로 줄어들고, 그래도 PAUSE가 막히면 `PAUSE_TIMEOUT_SEC`(5초)가 전환을 중단합니다. 에이전트의 판단은 30초 대기나 중단을 피하게 해 주고, 스크립트의 확인은 몇 초짜리 중단을 막아 줍니다.

## 측정 (로컬, `scenarios/05_busy_switchover.sh`, 2026-11-04)

배치가 상품 행 전체를 4초 동안 잠근 상태에서 전환을 시작했습니다.

| | 쓰기 중단 |
|---|---|
| `WAIT_READY_SEC=0` (기다리지 않음) | 2,573ms |
| 기본값 (`ready`까지 기다림) | 5ms (2,090ms 기다린 뒤) |
