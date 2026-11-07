#!/bin/bash
# Prepares an empty PostgreSQL database for the evaluation (e.g. on the remote
# server): installs HadathSQL, the Standard SQL CTE's helpers, and every driver
# variant (regenerating the ablation variants from sp_clustering.sql first), then
# records the machine and server configuration in machine.txt.
#
# Usage: setup_db.sh
# Connection: PGHOST, PGPORT, PGUSER, PGDATABASE (defaults as in run_point.sh:
# localhost 54329 test hadath); PSQL for the client path. The database must exist and
# must not contain HadathSQL yet (install.sql does not drop existing objects).
set -e
cd "$(dirname "$0")"
export PGHOST=${PGHOST:-localhost} PGPORT=${PGPORT:-54329} PGUSER=${PGUSER:-test} PGDATABASE=${PGDATABASE:-hadath}
APP_BIN=/Applications/Postgres.app/Contents/Versions/latest/bin
if [ -z "$PSQL" ]; then if [ -x "$APP_BIN/psql" ]; then PSQL=$APP_BIN/psql; else PSQL=$(command -v psql); fi; fi
# A full path: the wrapper function below is itself named psql.
[ -n "$PSQL" ] || { echo "psql not found; set PSQL or add it to the PATH" >&2; exit 1; }
psql() { $PSQL -X -q -v ON_ERROR_STOP=1 "$@"; }
REPO=$(cd ../../.. && pwd)

python3 make_ablation_variants.py
(cd "$REPO" && psql -f install.sql >/dev/null)
files=(-f setup_cte.sql); for f in driver_variant_*.sql; do files+=(-f "$f"); done
psql -c "SET client_min_messages = warning" "${files[@]}" >/dev/null
echo "installed: HadathSQL, CTE helpers, $(ls driver_variant_*.sql | wc -l | tr -d ' ') driver variants"

# Machine and server configuration, for the setup section of the paper.
{
  echo "date: $(date '+%F %T %z')"
  echo "host: $(uname -a)"
  if command -v lscpu >/dev/null; then lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket'
  else sysctl -n machdep.cpu.brand_string hw.ncpu 2>/dev/null; fi
  if [ -r /proc/meminfo ]; then grep MemTotal /proc/meminfo
  else echo "memory bytes: $(sysctl -n hw.memsize 2>/dev/null)"; fi
  psql -At -c "SELECT version()"
  psql -At -c "SELECT name || ' = ' || setting || COALESCE(' ' || unit, '') FROM pg_settings
               WHERE name IN ('shared_buffers','work_mem','effective_cache_size','maintenance_work_mem',
                              'random_page_cost','max_parallel_workers_per_gather','jit')
               ORDER BY name"
} > machine.txt
echo "wrote machine.txt"
