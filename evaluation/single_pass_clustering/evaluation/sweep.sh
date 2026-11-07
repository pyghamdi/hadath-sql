#!/bin/bash
# Evaluation sweep: for each data setting, threshold, and size, run run_point.sh with
# the selected methods and append one CSV line per point to <PREFIX><setting>.csv.
# Within each (setting, threshold) series, a method that hits the time limit is not
# run at larger sizes; a point during which the machine slept is measured again (up to
# twice); a sweep that is interrupted resumes where it stopped (points already in the
# CSV file are skipped). The results sections of ABLATION.md and COMPARISON.md are
# regenerated after
# every point.
#
# Usage: sweep.sh [config]        (default config: ablation.conf)
# The config file sets the variables below; any of them can also be overridden from
# the environment, e.g.  METHODS=sum,sumidx PREFIX=results_test_ bash sweep.sh
#   METHODS      comma-separated method keys (see run_point.sh)
#   SETTINGS     data settings (synthetic_tweets, synthetic_news)
#   THRESHOLDS   similarity thresholds
#   SIZES_SYNTHETIC_TWEETS, SIZES_SYNTHETIC_NEWS   numbers of documents per setting
#   TIMEOUT      time limit per run, in seconds
#   REPS, REP_MAX  repetitions per point (median reported) while a run takes < REP_MAX s
#   PREFIX       prefix of the result files
cd "$(dirname "$0")"
CONFIG=${1:-ablation.conf}
# Environment values take precedence over the config file (bash 3.2: no associative arrays).
VARS="METHODS SETTINGS THRESHOLDS SIZES_SYNTHETIC_TWEETS SIZES_SYNTHETIC_NEWS TIMEOUT REPS REP_MAX PREFIX"
for v in $VARS; do [ -n "${!v+x}" ] && eval "ENV_$v=\"\${$v}\""; done
if [ -f "$CONFIG" ]; then source "$CONFIG"; else echo "config $CONFIG not found" >&2; exit 1; fi
for v in $VARS; do e="ENV_$v"; [ -n "${!e+x}" ] && printf -v "$v" '%s' "${!e}"; done
export REPS REP_MAX

# Keep macOS awake for the whole sweep (idle sleep; system sleep on AC power). Lid-close
# sleep on battery cannot be prevented, so run_point.sh also detects sleeps.
if command -v caffeinate >/dev/null && [ -z "$SWEEP_CAFFEINATED" ]; then
  SWEEP_CAFFEINATED=1 exec caffeinate -i -s bash "$0" "$@"
fi
export PGHOST=${PGHOST:-localhost} PGPORT=${PGPORT:-54329}
APP_BIN=/Applications/Postgres.app/Contents/Versions/latest/bin
if [ -z "$PG_ISREADY" ]; then if [ -x "$APP_BIN/pg_isready" ]; then PG_ISREADY=$APP_BIN/pg_isready; else PG_ISREADY=$(command -v pg_isready); fi; fi
if ! $PG_ISREADY -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; then
  echo "PostgreSQL is not reachable at $PGHOST:$PGPORT; start it first (see ABLATION.md)." >&2
  exit 1
fi

HDR="setting,n,threshold,clusters,tfidf_s,d1_s,sum_s,sumidx_s,sumidxp_s,d2_s,driver_s,noidx_s,mean_s,noprep_s,noopt_s,cte-array_s,cte-standard_s,mismatches,load_start,load_end"
KEYS="d1 sum sumidx sumidxp d2 driver noidx mean noprep noopt cte-array cte-standard"     # order of the method columns in HDR

# Stop (without recording anything) if the server is down; the sweep resumes from the
# next missing point once the server is started again and the sweep is rerun.
server_up() { $PG_ISREADY -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; }
server_down_exit() {
  echo "$(date '+%F %T') PostgreSQL at $PGHOST:$PGPORT is down before $1; sweep stopped." \
       "Start the server and rerun the same command to resume." >&2
  exit 2
}

echo "sweep: methods=$METHODS settings=$SETTINGS thresholds=$THRESHOLDS timeout=${TIMEOUT}s reps=$REPS prefix=$PREFIX"
for SETTING in $SETTINGS; do
  OUT=$PREFIX$SETTING.csv
  [ -f "$OUT" ] || echo "$HDR" > "$OUT"
  # A results file written with other columns cannot take lines in the current format.
  if [ "$(head -1 "$OUT")" != "$HDR" ]; then
    echo "$OUT has other columns than the current runner; use another PREFIX." >&2
    exit 1
  fi
  sizes_var="SIZES_$(echo "$SETTING" | tr a-z A-Z)"
  for TH in $THRESHOLDS; do
    methods=$METHODS
    for N in ${!sizes_var}; do
      if grep -q "^$SETTING,$N,$TH," "$OUT"; then
        line=$(grep "^$SETTING,$N,$TH," "$OUT" | tail -1)
      else
        server_up || server_down_exit "$SETTING,$N,$TH"
        for attempt in 1 2 3; do
          line=$(bash run_point.sh "$SETTING" "$N" "$TH" "$methods" "$TIMEOUT")
          [[ "$line" == *SLEPT* ]] || break
        done
        # Errors caused by the server stopping during the point are not results.
        if [[ "$line" == *ERROR* || -z "$line" ]] && ! server_up; then
          server_down_exit "the end of $SETTING,$N,$TH (point discarded)"
        fi
        echo "$line" >> "$OUT"
        python3 render_results.py
      fi
      echo "$line"
      # drop methods that hit the time limit from the rest of this series
      IFS=, read -r -a f <<< "$line"
      i=5
      for m in $KEYS; do
        [ "${f[$i]}" = TIMEOUT ] && methods=$(echo ",$methods," | sed "s/,$m,/,/; s/^,//; s/,$//")
        i=$((i + 1))
      done
      [ -z "$methods" ] && break
    done
  done
done
echo DONE
