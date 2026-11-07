#!/bin/bash
psql() { /Applications/Postgres.app/Contents/Versions/latest/bin/psql -h localhost -p 54329 -U test -d postgres -X "$@"; }
D="$(dirname "$0")"
for N in 250 500 1000 2000; do
  psql -q -c "TRUNCATE docs2, doc_terms" -c "SELECT setseed(0.42)" \
       -c "INSERT INTO docs2 SELECT g, g FROM generate_series(1,$N) g" \
       -c "INSERT INTO doc_terms SELECT DISTINCT g, 't' || floor(random()*400)::int FROM generate_series(1,$N) g, generate_series(1,3)" >/dev/null
  start=$(perl -MTime::HiRes=time -e 'print time')
  out=$(psql -Atf "$D/rows_count.sql")
  end=$(perl -MTime::HiRes=time -e 'print time')
  printf "N=%-5s clusters=%-5s seconds=%.2f\n" "$N" "$out" "$(echo "$end - $start" | bc)"
done
