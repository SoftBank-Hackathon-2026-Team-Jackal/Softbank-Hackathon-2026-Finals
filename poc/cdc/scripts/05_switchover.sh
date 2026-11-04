#!/usr/bin/env bash
# 사용법: 05_switchover.sh <현재 주 DB> <새 주 DB>
# 정방향 구독(<현재> → <새>)이 streaming 상태일 때 실행한다. 절차:
#   1. PgBouncer PAUSE           새 트랜잭션을 대기시킴 (연결은 유지되므로 앱 에러 없음)
#   2. marker 행 도착 확인         커밋 순서대로 전달되므로, marker가 왔다면 그 앞의 변경도 모두 도착함
#   3. 체크섬 비교                 불일치하면 RESUME 하고 중단 (원래 DB 그대로 계속 서비스)
#   4. 정방향 구독 끄기            역방향과 동시에 살아 있으면 변경이 오가는 루프가 생길 수 있음
#                                  삭제하지 않고 끄기만 하므로, 이후 단계에서 실패해도 다시 켜면 복제가 그대로 이어진다
#   5. 시퀀스 동기화
#   6. 역방향 복제 켜기            <새> → <현재>, copy_data = false (롤백 보험)
#      구독은 PAUSE 전에 enabled = false 로 미리 만든다(원격 슬롯 생성이 느리기 때문).
#      전환 전까지 <새>에 들어오는 변경은 모두 복제로 받은 것이라 origin = none 이 걸러 내므로 안전하다.
#   7. PgBouncer 대상 변경 → RECONNECT → RESUME
#   8. 정방향 구독 삭제 (쓰기 중단 밖)
# 장애 주입: FAULT_AT=<지점> 이면 그 지점에서 결과 폴더에 .fault-<지점> 파일을 만들고,
#   호스트가 장애를 일으킨 뒤 .fault-<지점>.done 을 만들 때까지 최대 5초 기다린다 (poc/demo/bin/fault)
source "$(dirname "$0")/lib.sh"
from="${1:?현재 주 DB}" to="${2:?새 주 DB}"
fwd="$(sub_name "$from")" rev="$(sub_name "$to")"
MARKER_TIMEOUT_MS="${MARKER_TIMEOUT_MS:-10000}"
# PAUSE는 진행 중인 트랜잭션이 끝날 때까지 기다리고, 그동안 새 요청도 막힌다. 이 시간 안에 끝나지 않으면 포기한다
PAUSE_TIMEOUT_SEC="${PAUSE_TIMEOUT_SEC:-5}"
# PAUSE 안에서 하는 검증: checksum(전체 체크섬) | light(테이블별 max(id)) | auto(DB 200MB 이하면 checksum)
VERIFY_IN_PAUSE="${VERIFY_IN_PAUSE:-auto}"
if [[ "$VERIFY_IN_PAUSE" == auto ]]; then
  (( $(db_bytes "$from") <= 200 * 1024 * 1024 )) && VERIFY_IN_PAUSE=checksum || VERIFY_IN_PAUSE=light
fi

[[ "$(pgb_target)" == "$from" ]] || die "PgBouncer 대상이 $from 이 아닙니다 (현재: $(pgb_target))"
[[ "$(q "$to" "select count(*) from pg_subscription where subname = '$fwd' and subenabled")" == "1" ]] \
  || die "$to 에 활성 구독 $fwd 가 없습니다"
lag="$(slot_lag "$from" "$fwd")"
(( lag >= 0 && lag <= LAG_OK_BYTES )) || die "지연량이 큽니다 (${lag} bytes). 03_wait_sync.sh 를 먼저 실행하세요"

fault_point() {
  [[ "${FAULT_AT:-}" == "$1" ]] || return 0
  log "장애 주입 지점: $1"
  touch "$RESULTS_DIR/.fault-$1"
  for _ in $(seq 100); do [[ -e "$RESULTS_DIR/.fault-$1.done" ]] && break; sleep 0.05; done
  rm -f "$RESULTS_DIR/.fault-$1" "$RESULTS_DIR/.fault-$1.done"
}

declare -A ts
prepared=0 paused=0 fwd_disabled=0 switched=0
on_exit() {
  local rc=$?
  (( switched )) && exit $rc
  if (( paused )); then
    pgb "RESUME app;" >/dev/null || true
    log "중단: PgBouncer RESUME, 대상은 계속 $from (쓰기 중단 $(( $(now_ms) - ts[start] ))ms)"
  fi
  if (( prepared )); then
    log "중단: 미리 만든 역방향 구독 $rev 삭제"
    if ! q "$from" "DROP SUBSCRIPTION IF EXISTS $rev" >/dev/null 2>&1; then
      # $to 가 죽어서 원격 슬롯을 지울 수 없으면 슬롯 연결을 끊고 구독만 지운다. $to 의 슬롯은 나중에 지워야 한다
      q "$from" "ALTER SUBSCRIPTION $rev DISABLE; ALTER SUBSCRIPTION $rev SET (slot_name = NONE)" >/dev/null 2>&1 || true
      q "$from" "DROP SUBSCRIPTION IF EXISTS $rev" >/dev/null 2>&1 || true
      log "주의: $to 에 남은 복제 슬롯 $rev 는 $to 가 돌아오면 지워야 합니다"
    fi
  fi
  if (( fwd_disabled )); then
    if q "$to" "ALTER SUBSCRIPTION $fwd ENABLE" >/dev/null 2>&1; then
      log "중단: 정방향 구독 $fwd 다시 켬 ($from → $to 복제 계속)"
    else
      log "주의: $to 에 접속할 수 없어 정방향 구독을 켜지 못했습니다. $to 가 돌아오면 ALTER SUBSCRIPTION $fwd ENABLE"
    fi
  fi
  exit $rc
}
trap on_exit EXIT

ts[prepare]=$(now_ms)
log "0. 역방향 복제 준비 ($to → $from, 꺼진 상태)"
fix_replica_identity "$to"
q "$to" "GRANT USAGE ON SCHEMA mig TO replicator;
         GRANT SELECT ON ALL TABLES IN SCHEMA public, mig TO replicator" >/dev/null
q "$to" "select 1 from pg_publication where pubname = 'mig_pub'" | grep -q 1 \
  || q "$to" "CREATE PUBLICATION mig_pub FOR ALL TABLES" >/dev/null
[[ "$(q "$from" "select count(*) from pg_subscription where subname = '$rev'")" == "0" ]] \
  || die "$from 에 이미 구독 $rev 가 있습니다"
prepared=1
q "$from" "CREATE SUBSCRIPTION $rev CONNECTION '$(repl_conn "$to")' PUBLICATION mig_pub
           WITH (copy_data = false, origin = none, enabled = false)" >/dev/null

ts[start]=$(now_ms)
log "1. PAUSE (최대 ${PAUSE_TIMEOUT_SEC}초)"
paused=1
if ! timeout "$PAUSE_TIMEOUT_SEC" psql "$PGB_ADMIN_URL" -XAtq -c "PAUSE app;" >/dev/null; then
  q "$from" "select format('  긴 트랜잭션: pid %s, %s, %s', pid, now() - xact_start, left(query, 60))
             from pg_stat_activity where usename = 'app' and xact_start < now() - interval '1 second'
             order by xact_start limit 5" >&2 || true
  die "PAUSE가 ${PAUSE_TIMEOUT_SEC}초 안에 끝나지 않았습니다 (긴 트랜잭션). 전환을 중단합니다"
fi
ts[paused]=$(now_ms)
fault_point paused

log "2. marker 확인"
marker="$(q "$from" "INSERT INTO mig.marker DEFAULT VALUES RETURNING id")"
until [[ "$(q "$to" "select count(*) from mig.marker where id = '$marker'")" == "1" ]]; do
  (( $(now_ms) - ts[paused] > MARKER_TIMEOUT_MS )) && die "marker가 ${MARKER_TIMEOUT_MS}ms 안에 도착하지 않았습니다"
  sleep 0.02
done
ts[marker]=$(now_ms)

log "3. 검증 ($VERIFY_IN_PAUSE)"
if [[ "$VERIFY_IN_PAUSE" == checksum ]]; then
  "$(dirname "$0")/04_compare.sh" "$from" "$to" 2>/dev/null || die "체크섬 불일치. 전환을 중단합니다"
else
  ma="$(max_ids "$from")" mb="$(max_ids "$to")"
  [[ "$ma" == "$mb" ]] || { diff <(echo "$ma") <(echo "$mb") >&2 || true; die "max(id) 불일치. 전환을 중단합니다"; }
fi
ts[verified]=$(now_ms)

log "4. 정방향 구독 끄기 ($fwd)"
q "$to" "ALTER SUBSCRIPTION $fwd DISABLE" >/dev/null
fwd_disabled=1
fault_point forward-disabled

log "5. 시퀀스 동기화"
q "$from" "select format('select setval(%L, %s, true);', quote_ident(schemaname) || '.' || quote_ident(sequencename), last_value)
           from pg_sequences where last_value is not null" \
  | psql "$(url "$to")" -XAtq -v ON_ERROR_STOP=1 >/dev/null

log "6. 역방향 복제 켜기 ($rev)"
q "$from" "ALTER SUBSCRIPTION $rev ENABLE" >/dev/null
ts[reverse]=$(now_ms)

log "7. PgBouncer 대상 변경 → RESUME"
pgb_set_target "$to"
pgb "RELOAD;" >/dev/null
pgb "RECONNECT app;" >/dev/null
pgb "RESUME app;" >/dev/null
switched=1
ts[resumed]=$(now_ms)

log "8. 정방향 구독 삭제 ($fwd, 쓰기 중단 밖)"
q "$to" "DROP SUBSCRIPTION $fwd" >/dev/null || log "주의: 정방향 구독 $fwd 삭제 실패. 직접 지워야 되돌리기를 할 수 있습니다"

# 쓰기 중단 = PAUSE 명령을 보낸 순간부터 RESUME까지 (PAUSE 대기 중에도 새 요청은 막힌다)
pause_ms=$(( ts[resumed] - ts[start] ))
result="$RESULTS_DIR/switchover-$(date +%Y%m%dT%H%M%S)-$from-to-$to.json"
cat > "$result" <<JSON
{
  "from": "$from",
  "to": "$to",
  "write_pause_ms": $pause_ms,
  "verify_in_pause": "$VERIFY_IN_PAUSE",
  "steps_ms": {
    "prepare_reverse (PAUSE 전)": $(( ts[start] - ts[prepare] )),
    "pause_wait_inflight": $(( ts[paused] - ts[start] )),
    "marker_wait": $(( ts[marker] - ts[paused] )),
    "verify": $(( ts[verified] - ts[marker] )),
    "disable_forward_seq_sync_enable_reverse": $(( ts[reverse] - ts[verified] )),
    "retarget_resume": $(( ts[resumed] - ts[reverse] ))
  }
}
JSON
log "완료: $from → $to, 쓰기 중단 ${pause_ms}ms ($result)"
cat "$result"
