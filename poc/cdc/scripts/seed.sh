#!/usr/bin/env bash
# 사용법: seed.sh <노드> [scale]   scale 1 ≈ 60MB, 100 ≈ 5GB
source "$(dirname "$0")/lib.sh"
db="${1:?노드}" scale="${2:-1}"
[[ "$(q "$db" "select count(*) from orders")" == "0" ]] || die "$db 에 이미 데이터가 있습니다"
log "$db: 기존 데이터 생성 (scale = $scale)"
start=$(now_ms)
psql "$(url "$db")" -Xq -v scale="$scale" -f "$(dirname "$0")/seed.sql" | grep -E "^Time" | awk '{s+=$2} END {printf "  SQL 합계 %.1f초\n", s/1000}' >&2
log "완료: $(q "$db" "select pg_size_pretty(pg_database_size(current_database()))"), $(( ($(now_ms) - start) / 1000 ))초"
