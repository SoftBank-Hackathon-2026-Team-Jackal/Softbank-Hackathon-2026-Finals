#!/usr/bin/env bash
# 사용법: 03_wait_sync.sh <원본> <대상> [제한 시간(초)]
# 단계: copying(초기 복사) → catching_up(복사 중 쌓인 변경 적용) → streaming(실시간 동기화)
# POLL_SEC(기본 1초)마다 results/replication-<구독>.jsonl 에 기록한다 (대시보드 데이터).
#   copied_pct     대상 DB 크기 / 원본 DB 크기 (인덱스 포함 근사치)
#   retained_bytes 원본 슬롯이 붙잡고 있는 WAL (구독자가 늦으면 원본 디스크가 찬다)
#   lag_bytes      아직 대상에 반영되지 않은 WAL
source "$(dirname "$0")/lib.sh"
src="${1:?원본}" dst="${2:?대상}" timeout="${3:-300}"
sub="$(sub_name "$src")"
out="$RESULTS_DIR/replication-$sub.jsonl"
poll="${POLL_SEC:-1}"
start=$(date +%s)
src_bytes="$(db_bytes "$src")"

while :; do
  IFS='|' read -r total ready copying <<<"$(q "$dst" "
    select count(*), count(*) filter (where srsubstate = 'r'), count(*) filter (where srsubstate in ('i','d','f'))
    from pg_subscription_rel r join pg_subscription s on s.oid = r.srsubid where s.subname = '$sub'")"
  lag="$(slot_lag "$src" "$sub")"
  retained="$(q "$src" "select coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), 0)::bigint from pg_replication_slots")"
  dst_bytes="$(db_bytes "$dst")"
  if (( copying > 0 )); then phase=copying
  elif (( ready < total || lag < 0 || lag > LAG_OK_BYTES )); then phase=catching_up
  else phase=streaming; fi

  printf '{"t":%s,"sub":"%s","phase":"%s","tables_ready":%s,"tables_total":%s,"copied_pct":%s,"retained_bytes":%s,"lag_bytes":%s}\n' \
    "$(now_ms)" "$sub" "$phase" "$ready" "$total" "$(( dst_bytes * 100 / (src_bytes > 0 ? src_bytes : 1) ))" "$retained" "$lag" \
    | tee -a "$out" >&2
  [[ "$phase" == streaming ]] && exit 0
  (( $(date +%s) - start > timeout )) && die "$timeout초 안에 동기화되지 않았습니다"
  sleep "$poll"
done
