#!/bin/bash
# One experiment point: generate the data, build TF-IDF once, then time the
# clustering of each method on the same TF-IDF table and check that every method's
# assignments equal those of the HadathSQL driver.
#
# Usage: run_point.sh <setting> <n> <threshold> <methods> [timeout_s]
#   setting: synthetic_tweets | synthetic_news (datasets of gen_synthetic_data.sql)
#   methods: comma-separated subset of
#            driver,noidx,mean,noprep,noopt,d1,sum,sumidx,sumidxp,d2,cte-standard,cte-array
#     d1 = basic driver, no optimization (reads an unindexed copy of the TF-IDF table)
#     sum = summed driver: basic driver with summed centroids (unindexed copy too)
#     sumidx = summed + indexed driver: summed driver with the indexing optimization
#     sumidxp = summed + indexed + prepared: sumidx with prepared statements only
#     d2 = mean + indexed driver: basic driver + indexes and stored norms, mean centroids
#     driver = HadathSQL driver, hsql_single_pass_clustering_tfidf (sp_clustering.sql)
#     noidx  = HadathSQL driver without indexes (reads the unindexed copy)
#     mean   = HadathSQL driver without summed centroids (running means)
#     noprep = HadathSQL driver without prepared statements
#     noopt  = HadathSQL driver without all three (reads the unindexed copy)
#     cte-array    = Array CTE (non-standard; input preparation included in its time)
#     cte-standard = Standard SQL CTE (input preparation included in its time)
# Prints one CSV line:
#   setting,n,threshold,clusters,tfidf_s,d1_s,sum_s,sumidx_s,sumidxp_s,d2_s,driver_s,noidx_s,mean_s,noprep_s,noopt_s,cte-array_s,cte-standard_s,mismatches,load_start,load_end
# Each method is run REPS times (default 3) while its runs take less than REP_MAX
# seconds (default 60), and the median time is reported; slower runs are measured once.
# A method not run prints NA; one that exceeds the timeout prints TIMEOUT; one during
# which the machine slept prints SLEPT (its wall-clock time would include the sleep).
# Connection: PGHOST, PGPORT, PGUSER, PGDATABASE (defaults: localhost 54329 test hadath).
SETTING=$1; N=$2; TH=$3; METHODS=$4; TIMEOUT=${5:-300}
cd "$(dirname "$0")"
export PGHOST=${PGHOST:-localhost} PGPORT=${PGPORT:-54329} PGUSER=${PGUSER:-test} PGDATABASE=${PGDATABASE:-hadath}
# Client: $PSQL if set, else Postgres.app's psql on macOS, else psql on the PATH.
APP_BIN=/Applications/Postgres.app/Contents/Versions/latest/bin
if [ -z "$PSQL" ]; then if [ -x "$APP_BIN/psql" ]; then PSQL=$APP_BIN/psql; else PSQL=$(command -v psql); fi; fi
# A full path: the wrapper function below is itself named psql.
[ -n "$PSQL" ] || { echo "psql not found; set PSQL or add it to the PATH" >&2; exit 1; }
psql() { $PSQL -X -q -v ON_ERROR_STOP=1 "$@"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
has() { [[ ",$METHODS," == *",$1,"* ]]; }
# 1-minute load average of the machine, recorded at the start and end of the point so
# that interference from other jobs on a shared machine can be seen afterwards.
loadavg() { if [ -r /proc/loadavg ]; then cut -d' ' -f1 /proc/loadavg; else sysctl -n vm.loadavg | awk '{print $2}'; fi; }
load_start=$(loadavg)
ERR=$(mktemp)
# slept_between <t0> <t1>: true if macOS logged a sleep between the two epoch times
# (`pmset -g log`; on other systems this check is skipped).
slept_between() {
  command -v pmset >/dev/null || return 1
  pmset -g log 2>/dev/null | python3 -c '
import sys, datetime
t0, t1 = float(sys.argv[1]), float(sys.argv[2])
for line in sys.stdin:
    if " Sleep " not in line or "Entering Sleep" not in line: continue
    try: ts = datetime.datetime.strptime(line[:25], "%Y-%m-%d %H:%M:%S %z").timestamp()
    except ValueError: continue
    if t0 - 1 <= ts <= t1 + 1: sys.exit(0)
sys.exit(1)' "$1" "$2"
}
# timed <psql args...>: runs psql under the statement timeout; prints seconds, TIMEOUT,
# SLEPT, or ERROR
timed() {
  local t0 t1
  t0=$(now)
  if PGOPTIONS="-c statement_timeout=${TIMEOUT}s -c client_min_messages=warning" psql "$@" >/dev/null 2>"$ERR"; then
    t1=$(now)
    if slept_between "$t0" "$t1"; then echo SLEPT; else echo "$t1 - $t0" | bc; fi
  elif grep -q "statement timeout" "$ERR"; then
    t1=$(now)
    if slept_between "$t0" "$t1"; then echo SLEPT; else echo TIMEOUT; fi
  else
    cat "$ERR" >&2; echo ERROR
  fi
}

REPS=${REPS:-3}; REP_MAX=${REP_MAX:-60}
# measure <psql args...>: median of up to REPS timed runs (stops repeating once a run
# takes REP_MAX seconds or more, or does not complete)
measure() {
  local times=() t
  for ((r = 1; r <= REPS; r++)); do
    t=$(timed "$@")
    if ! [[ "$t" =~ ^[0-9.]+$ ]]; then echo "$t"; return; fi
    times+=("$t")
    (( $(echo "$t >= $REP_MAX" | bc) )) && break
  done
  printf '%s\n' "${times[@]}" | sort -g | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'
}

case $SETTING in
  synthetic_tweets) GEN="-v topic_words=8 -v vocab=12 -v bg_words=4 -v bg_vocab=2000" ;;
  synthetic_news)   GEN="-v topic_words=200 -v vocab=200 -v bg_words=200 -v bg_vocab=20000" ;;
  *) echo "unknown setting $SETTING" >&2; exit 1 ;;
esac

# Data (not timed).
psql -v n="$N" -v topics=50 -v seed=0.42 $GEN -f gen_synthetic_data.sql >/dev/null 2>&1
psql -c "VACUUM ANALYZE sp_docs" >/dev/null

# TF-IDF, built once and indexed on doc_id (timed separately, not part of any method).
tfidf=$(timed -c "SELECT hsql_create_tf_idf_tbl('sp_docs','doc_id','txt','sp_tfidf',TRUE)" \
              -c "CREATE INDEX ON sp_tfidf (doc_id)" -c "ANALYZE sp_tfidf")
# Unindexed copy for the basic driver, which uses no index on doc_id (not timed).
psql -c "DROP TABLE IF EXISTS sp_tfidf_noidx" -c "CREATE TABLE sp_tfidf_noidx AS SELECT * FROM sp_tfidf" \
     -c "ANALYZE sp_tfidf_noidx" >/dev/null

d1=NA; sum=NA; sumidx=NA; sumidxp=NA; d2=NA; driver=NA; noidx=NA; mean=NA; noprep=NA; noopt=NA; cte_array=NA; cte_standard=NA
has driver && driver=$(measure -c "SELECT hsql_single_pass_clustering_tfidf('sp_docs','doc_id','ts','sp_tfidf','drv',$TH,TRUE)")
has noidx && noidx=$(measure -c "SELECT hsql_spc_hadathsql_noidx('sp_docs','doc_id','ts','sp_tfidf_noidx','dnoidx',$TH,TRUE)")
has mean && mean=$(measure -c "SELECT hsql_spc_hadathsql_mean('sp_docs','doc_id','ts','sp_tfidf','dmean',$TH,TRUE)")
has noprep && noprep=$(measure -c "SELECT hsql_spc_hadathsql_noprep('sp_docs','doc_id','ts','sp_tfidf','dnoprep',$TH,TRUE)")
has noopt && noopt=$(measure -c "SELECT hsql_spc_hadathsql_noopt('sp_docs','doc_id','ts','sp_tfidf_noidx','dnoopt',$TH,TRUE)")
has d2 && d2=$(measure -c "SELECT hsql_spc_mean_indexed('sp_docs','doc_id','ts','sp_tfidf','d2',$TH,TRUE)")
has d1 && d1=$(measure -c "SELECT hsql_spc_basic('sp_docs','doc_id','ts','sp_tfidf_noidx','d1',$TH,TRUE)")
has sum && sum=$(measure -c "SELECT hsql_spc_summed('sp_docs','doc_id','ts','sp_tfidf_noidx','dsum',$TH,TRUE)")
has sumidx && sumidx=$(measure -c "SELECT hsql_spc_sumidx('sp_docs','doc_id','ts','sp_tfidf','dsumidx',$TH,TRUE)")
has sumidxp && sumidxp=$(measure -c "SELECT hsql_spc_sumidxp('sp_docs','doc_id','ts','sp_tfidf','dsumidxp',$TH,TRUE)")
has cte-array && cte_array=$(measure -v th="$TH" -f prep_cte_array.sql -f run_cte_array.sql)
has cte-standard && cte_standard=$(measure -v th="$TH" -f prep_cte_standard.sql -f run_cte_standard.sql)

# Equivalence with a reference for every method that completed: the HadathSQL driver if it ran,
# otherwise the first of its ablation variants (without prepared statements, with mean
# centroids, without indexes) that ran, otherwise the basic, summed, or summed + indexed driver.
num='^[0-9.]+$'
clusters=NA; mism=0; ref=""
if [[ "$driver" =~ $num ]]; then ref=drv; elif [[ "$noprep" =~ $num ]]; then ref=dnoprep; elif [[ "$mean" =~ $num ]]; then ref=dmean; elif [[ "$noidx" =~ $num ]]; then ref=dnoidx; elif [[ "$noopt" =~ $num ]]; then ref=dnoopt; elif [[ "$d1" =~ $num ]]; then ref=d1; elif [[ "$sum" =~ $num ]]; then ref=dsum; elif [[ "$sumidx" =~ $num ]]; then ref=dsumidx; fi
if [ -n "$ref" ]; then
  clusters=$(psql -At -c "SELECT COUNT(DISTINCT cid) FROM ${ref}_cluster_assignments")
  chk() { psql -At -c "SELECT COUNT(*) FROM ${ref}_cluster_assignments r FULL JOIN $1 x ON x.$2 = r.doc_id WHERE x.cid IS DISTINCT FROM r.cid"; }
  [[ "$ref" != d1 && "$d1" =~ $num ]] && mism=$((mism + $(chk d1_cluster_assignments doc_id)))
  [[ "$ref" != dsum && "$sum" =~ $num ]] && mism=$((mism + $(chk dsum_cluster_assignments doc_id)))
  [[ "$ref" != dsumidx && "$sumidx" =~ $num ]] && mism=$((mism + $(chk dsumidx_cluster_assignments doc_id)))
  [[ "$sumidxp" =~ $num ]] && mism=$((mism + $(chk dsumidxp_cluster_assignments doc_id)))
  [[ "$ref" != dnoidx && "$noidx" =~ $num ]] && mism=$((mism + $(chk dnoidx_cluster_assignments doc_id)))
  [[ "$ref" != dmean && "$mean" =~ $num ]] && mism=$((mism + $(chk dmean_cluster_assignments doc_id)))
  [[ "$ref" != dnoprep && "$noprep" =~ $num ]] && mism=$((mism + $(chk dnoprep_cluster_assignments doc_id)))
  [[ "$ref" != dnoopt && "$noopt" =~ $num ]] && mism=$((mism + $(chk dnoopt_cluster_assignments doc_id)))
  [[ "$d2" =~ $num ]] && mism=$((mism + $(chk d2_cluster_assignments doc_id)))
  [[ "$cte_array" =~ $num ]] && mism=$((mism + $(chk cte_array_out did)))
  [[ "$cte_standard" =~ $num ]] && mism=$((mism + $(chk cte_rows_out did)))
else
  mism=NA
fi
rm -f "$ERR"
echo "$SETTING,$N,$TH,$clusters,$tfidf,$d1,$sum,$sumidx,$sumidxp,$d2,$driver,$noidx,$mean,$noprep,$noopt,$cte_array,$cte_standard,$mism,$load_start,$(loadavg)"
