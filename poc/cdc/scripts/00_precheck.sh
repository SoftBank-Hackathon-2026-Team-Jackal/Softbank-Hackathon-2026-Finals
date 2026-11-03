#!/usr/bin/env bash
# 사용법: 00_precheck.sh <노드>
source "$(dirname "$0")/lib.sh"
db="${1:?노드 이름}"
psql "$(url "$db")" -X -v ON_ERROR_STOP=1 -f "$(dirname "$0")/precheck.sql"
[[ "$(q "$db" "show wal_level")" == "logical" ]] || die "$db: wal_level 이 logical 이 아닙니다 (재시작 필요)"
