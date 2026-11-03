#!/usr/bin/env bash
# 사용법: 04_compare.sh <노드1> <노드2>
# 테이블별 행 수와 체크섬을 비교한다. 쓰기가 멈춘 상태(또는 지연 0)에서 실행해야 의미가 있다.
source "$(dirname "$0")/lib.sh"
a="${1:?노드1}" b="${2:?노드2}"
ca="$(checksums "$a")" cb="$(checksums "$b")"
echo "$ca" | sed "s/^/$a: /" >&2
if [[ "$ca" == "$cb" ]]; then
  log "일치: $a = $b"
else
  diff <(echo "$ca") <(echo "$cb") >&2 || true
  die "불일치: $a ≠ $b"
fi
