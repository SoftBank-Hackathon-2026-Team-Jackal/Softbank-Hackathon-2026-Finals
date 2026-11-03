#!/usr/bin/env bash
# 사용법: 05_switchover.sh <현재 주 DB> <새 주 DB>
# 정방향 구독(<현재> → <새>)이 streaming 상태일 때 실행한다. 절차:
#   1. PgBouncer PAUSE           새 트랜잭션을 대기시킴 (연결은 유지되므로 앱 에러 없음)
#   2. marker 행 도착 확인         커밋 순서대로 전달되므로, marker가 왔다면 그 앞의 변경도 모두 도착함
#   3. 체크섬 비교                 불일치하면 RESUME 하고 중단 (원래 DB 그대로 계속 서비스)
#   4. 정방향 구독 삭제            역방향과 동시에 살아 있으면 변경이 오가는 루프가 생길 수 있음
#   5. 시퀀스 동기화
#   6. 역방향 복제 생성            <새> → <현재>, copy_data = false (롤백 보험)
#   7. PgBouncer 대상 변경 → RECONNECT → RESUME
source "$(dirname "$0")/lib.sh"
from="${1:?현재 주 DB}" to="${2:?새 주 DB}"
fwd="$(sub_name "$from")" rev="$(sub_name "$to")"
MARKER_TIMEOUT_MS="${MARKER_TIMEOUT_MS:-10000}"

[[ "$(pgb_target)" == "$from" ]] || die "PgBouncer 대상이 $from 이 아닙니다 (현재: $(pgb_target))"
[[ "$(q "$to" "select count(*) from pg_subscription where subname = '$fwd' and subenabled")" == "1" ]] \
  || die "$to 에 활성 구독 $fwd 가 없습니다"
lag="$(slot_lag "$from" "$fwd")"
(( lag >= 0 && lag <= LAG_OK_BYTES )) || die "지연량이 큽니다 (${lag} bytes). 03_wait_sync.sh 를 먼저 실행하세요"

declare -A ts
paused=0 switched=0
on_exit() {
  local rc=$?
  if (( paused && ! switched )); then
    log "중단: PgBouncer RESUME (대상은 계속 $from)"
    pgb "RESUME app;" >/dev/null || true
  fi
  exit $rc
}
trap on_exit EXIT

ts[start]=$(now_ms)
log "1. PAUSE"
pgb "PAUSE app;" >/dev/null
paused=1
ts[paused]=$(now_ms)

log "2. marker 확인"
marker="$(q "$from" "INSERT INTO mig.marker DEFAULT VALUES RETURNING id")"
until [[ "$(q "$to" "select count(*) from mig.marker where id = '$marker'")" == "1" ]]; do
  (( $(now_ms) - ts[paused] > MARKER_TIMEOUT_MS )) && die "marker가 ${MARKER_TIMEOUT_MS}ms 안에 도착하지 않았습니다"
  sleep 0.02
done
ts[marker]=$(now_ms)

log "3. 체크섬 비교"
"$(dirname "$0")/04_compare.sh" "$from" "$to" 2>/dev/null || die "체크섬 불일치. 전환을 중단합니다"
ts[verified]=$(now_ms)

log "4. 정방향 구독 삭제 ($fwd)"
q "$to" "DROP SUBSCRIPTION $fwd" >/dev/null

log "5. 시퀀스 동기화"
q "$from" "select format('select setval(%L, %s, true);', quote_ident(schemaname) || '.' || quote_ident(sequencename), last_value)
           from pg_sequences where last_value is not null" \
  | psql "$(url "$to")" -XAtq -v ON_ERROR_STOP=1 >/dev/null

log "6. 역방향 복제 생성 ($to → $from)"
fix_replica_identity "$to"
q "$to" "GRANT USAGE ON SCHEMA mig TO replicator;
         GRANT SELECT ON ALL TABLES IN SCHEMA public, mig TO replicator" >/dev/null
q "$to" "select 1 from pg_publication where pubname = 'mig_pub'" | grep -q 1 \
  || q "$to" "CREATE PUBLICATION mig_pub FOR ALL TABLES" >/dev/null
q "$from" "CREATE SUBSCRIPTION $rev CONNECTION '$(repl_conn "$to")' PUBLICATION mig_pub
           WITH (copy_data = false, origin = none)" >/dev/null
ts[reverse]=$(now_ms)

log "7. PgBouncer 대상 변경 → RESUME"
pgb_set_target "$to"
pgb "RELOAD;" >/dev/null
pgb "RECONNECT app;" >/dev/null
pgb "RESUME app;" >/dev/null
switched=1
ts[resumed]=$(now_ms)

pause_ms=$(( ts[resumed] - ts[paused] ))
result="$RESULTS_DIR/switchover-$(date +%Y%m%dT%H%M%S)-$from-to-$to.json"
cat > "$result" <<JSON
{
  "from": "$from",
  "to": "$to",
  "write_pause_ms": $pause_ms,
  "steps_ms": {
    "pause": $(( ts[paused] - ts[start] )),
    "marker_wait": $(( ts[marker] - ts[paused] )),
    "checksum": $(( ts[verified] - ts[marker] )),
    "drop_forward_seq_sync_reverse": $(( ts[reverse] - ts[verified] )),
    "retarget_resume": $(( ts[resumed] - ts[reverse] ))
  }
}
JSON
log "완료: $from → $to, 쓰기 중단 ${pause_ms}ms ($result)"
cat "$result"
