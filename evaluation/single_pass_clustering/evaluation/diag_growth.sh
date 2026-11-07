#!/bin/bash
# Diagnostic for the faster-than-linear growth of the HadathSQL driver at large sizes
# (ABLATION.md, observation 7). For each (setting, threshold, size), it clusters the
# documents with the HadathSQL driver inside one transaction and then records, before
# committing:
#   - the number of centroid entries and of candidate clusters that the term index
#     returns for the last 200 documents (what the best-cluster query joins), and
#   - the time of those 200 joins while the old row versions of the pass still exist;
# after committing, the number of dead row versions in the centroid table
# (pgstattuple), and the time of the same 200 joins after VACUUM has removed them.
# If the joins are much faster after VACUUM, the growth comes from row versions
# accumulated during the single transaction of the pass; if the number of candidates
# grows with the size, it comes from the candidate search itself.
#
# Usage: diag_growth.sh "<setting> <threshold> <sizes...>" ...   (appends to diag_growth.csv)
cd "$(dirname "$0")"
export PGHOST=${PGHOST:-localhost} PGPORT=${PGPORT:-54329} PGUSER=${PGUSER:-test} PGDATABASE=${PGDATABASE:-hadath}
PSQL=${PSQL:-$(command -v psql)}
q() { $PSQL -X -q -At -v ON_ERROR_STOP=1 "$@"; }
OUT=diag_growth.csv
[ -f $OUT ] || echo "setting,n,threshold,clusters,driver_s,centroid_live,centroid_dead,join_rows_per_doc,cand_clusters_per_doc,join_ms_with_versions,join_ms_after_vacuum" > $OUT
q -c "CREATE EXTENSION IF NOT EXISTS pgstattuple" >/dev/null

# the 200 joins of the best-cluster query (dot product part) for the last documents
JOIN="SELECT count(*) FROM (SELECT l.doc_id, b.cid, SUM(a.weight * b.weight)
       FROM (SELECT doc_id FROM sp_docs ORDER BY ts DESC LIMIT 200) l
       JOIN sp_tfidf a ON a.doc_id = l.doc_id
       JOIN drv_centroid b ON b.term = a.term
       GROUP BY l.doc_id, b.cid) s"

for spec in "$@"; do
  set -- $spec; SETTING=$1; TH=$2; shift 2
  case $SETTING in
    synthetic_tweets) GEN="-v topic_words=8 -v vocab=12 -v bg_words=4 -v bg_vocab=2000" ;;
    synthetic_news)   GEN="-v topic_words=200 -v vocab=200 -v bg_words=200 -v bg_vocab=20000" ;;
  esac
  for N in "$@"; do
    q -v n=$N -v topics=50 -v seed=0.42 $GEN -f gen_synthetic_data.sql >/dev/null 2>&1
    q -c "SET client_min_messages = warning" -c "SELECT hsql_create_tf_idf_tbl('sp_docs','doc_id','txt','sp_tfidf',TRUE)" \
      -c "CREATE INDEX ON sp_tfidf (doc_id)" -c "ANALYZE sp_tfidf" >/dev/null
    # one session: pass and measurements inside the pass's transaction, then commit
    res=$(q -v th=$TH <<SQL
SET client_min_messages = warning;
SET random_page_cost = 1.1;
BEGIN;
SELECT clock_timestamp() AS t0 \gset
SELECT hsql_single_pass_clustering_tfidf('sp_docs','doc_id','ts','sp_tfidf','drv',:th,TRUE);
SELECT round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)::numeric, 3) AS secs \gset
SELECT count(*) AS clusters FROM drv \gset
SELECT round(avg(r)::numeric, 1) AS jr, round(avg(c)::numeric, 1) AS cc FROM (
  SELECT count(*) AS r, count(DISTINCT b.cid) AS c
  FROM (SELECT doc_id FROM sp_docs ORDER BY ts DESC LIMIT 200) l
  JOIN sp_tfidf a ON a.doc_id = l.doc_id JOIN drv_centroid b ON b.term = a.term
  GROUP BY l.doc_id) s \gset
SELECT clock_timestamp() AS t1 \gset
$JOIN \g /dev/null
SELECT round(extract(epoch FROM clock_timestamp() - :'t1'::timestamptz)::numeric * 1000, 1) AS ms_versions \gset
COMMIT;
SELECT tuple_count AS live, dead_tuple_count AS dead FROM pgstattuple('drv_centroid') \gset
VACUUM drv_centroid;
SELECT clock_timestamp() AS t2 \gset
$JOIN \g /dev/null
SELECT round(extract(epoch FROM clock_timestamp() - :'t2'::timestamptz)::numeric * 1000, 1) AS ms_vacuum \gset
SELECT :clusters || ',' || :secs || ',' || :live || ',' || :dead || ',' || :jr || ',' || :cc || ',' || :ms_versions || ',' || :ms_vacuum;
SQL
)
    res=$(echo "$res" | tail -1)
    line="$SETTING,$N,$TH,$res"
    echo "$line" | tee -a $OUT
  done
done
echo DONE
