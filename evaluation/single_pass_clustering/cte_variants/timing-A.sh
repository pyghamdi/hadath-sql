#!/bin/bash
# Times the array-packed recursive CTE (Test 1) at growing input sizes.
psql() { /Applications/Postgres.app/Contents/Versions/latest/bin/psql -h localhost -p 54329 -U test -d postgres -X "$@"; }

for N in 250 500 1000 2000 4000; do
  psql -q -c "TRUNCATE docs" -c "SELECT setseed(0.42)" \
       -c "INSERT INTO docs SELECT g, g, ARRAY(SELECT 't' || floor(random()*400)::int FROM generate_series(1,3) s WHERE s > g*0) FROM generate_series(1,$N) g" >/dev/null
  start=$(perl -MTime::HiRes=time -e 'print time')
  out=$(psql -Atc "WITH RECURSIVE sp(i, clusters) AS (
      SELECT 0, '{}'::cluster[]
      UNION ALL
      SELECT sp.i + 1, assign(d, sp.clusters,
             (SELECT c FROM unnest(sp.clusters) c ORDER BY sim(d.terms, c.terms) DESC LIMIT 1))
      FROM sp JOIN docs d ON d.rn = sp.i + 1)
    SELECT cardinality(clusters) FROM sp ORDER BY i DESC LIMIT 1")
  end=$(perl -MTime::HiRes=time -e 'print time')
  printf "N=%-5s clusters=%-5s seconds=%.2f\n" "$N" "$out" "$(echo "$end - $start" | bc)"
done
