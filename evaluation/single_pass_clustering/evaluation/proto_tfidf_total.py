"""Prototype (2026-11-09): can the TF-IDF query avoid the aggregation and join on doc_id?

A: the query of hsql_create_tf_idf_tbl; B: the document total from one PL/pgSQL call per document
(tmp_tsv_stats, computed in the workers); C: the total from term_counts with a window over the
document's terms. All three are timed as CREATE UNLOGGED TABLE AS on the current sp_docs and
checked against A (rows whose weight differs). Needs proto_tfidf_total.sql loaded first.
  python3 proto_tfidf_total.py 3 0,2
"""
import statistics, sys, time, psycopg2
N = None
CUR = """CREATE UNLOGGED TABLE tfidf_x AS
WITH dtc AS (
  SELECT src.doc_id, t.term, t.term_count FROM
    (SELECT doc_id, to_tsvector('english', coalesce(txt, '')) AS tsv FROM sp_docs OFFSET 0) src
  CROSS JOIN LATERAL hsql_term_counts(src.tsv) AS t(term, term_count)),
 tf AS (SELECT doc_id, SUM(term_count) AS tf FROM dtc GROUP BY doc_id),
 df AS (SELECT term, COUNT(*) AS df FROM dtc GROUP BY term)
SELECT dtc.doc_id::INTEGER AS doc_id, dtc.term::TEXT AS term,
       ((dtc.term_count::FLOAT / tf.tf) * LOG(%(n)s::FLOAT / df.df))::FLOAT AS weight
FROM dtc JOIN tf ON dtc.doc_id = tf.doc_id JOIN df ON dtc.term = df.term"""
B = """CREATE UNLOGGED TABLE tfidf_x AS
WITH dtc AS (
  SELECT src.doc_id, t.term, t.term_count, (src.st).total AS total FROM
    (SELECT doc_id, tmp_tsv_stats(txt) AS st FROM sp_docs OFFSET 0) src
  CROSS JOIN LATERAL hsql_term_counts((src.st).tsv) AS t(term, term_count)),
 df AS (SELECT term, COUNT(*) AS df FROM dtc GROUP BY term)
SELECT dtc.doc_id::INTEGER AS doc_id, dtc.term::TEXT AS term,
       ((dtc.term_count::FLOAT / dtc.total) * LOG(%(n)s::FLOAT / df.df))::FLOAT AS weight
FROM dtc JOIN df ON dtc.term = df.term"""
C = """CREATE UNLOGGED TABLE tfidf_x AS
WITH dtc AS (
  SELECT src.doc_id, t.term, t.count AS term_count, t.total FROM
    (SELECT doc_id, to_tsvector('english', coalesce(txt, '')) AS tsv FROM sp_docs OFFSET 0) src
  CROSS JOIN LATERAL tmp_term_counts_total(src.tsv) AS t),
 df AS (SELECT term, COUNT(*) AS df FROM dtc GROUP BY term)
SELECT dtc.doc_id::INTEGER AS doc_id, dtc.term::TEXT AS term,
       ((dtc.term_count::FLOAT / dtc.total) * LOG(%(n)s::FLOAT / df.df))::FLOAT AS weight
FROM dtc JOIN df ON dtc.term = df.term"""
def main():
    reps = int(sys.argv[1]); workers = [int(w) for w in sys.argv[2].split(",")]
    conn = psycopg2.connect(""); conn.autocommit = True; cur = conn.cursor()
    cur.execute("SET client_min_messages = warning; SET parallel_tuple_cost = 0")
    cur.execute("SELECT count(*) FROM sp_docs"); n = cur.fetchone()[0]
    cur.execute("DROP TABLE IF EXISTS tfidf_ref"); cur.execute(CUR.replace("tfidf_x", "tfidf_ref") % dict(n=n))
    for w in workers:
        cur.execute(f"ALTER TABLE sp_docs SET (parallel_workers = {max(w,1)})")
        cur.execute(f"SET max_parallel_workers_per_gather = {w}")
        times = {k: [] for k in ("A current", "B stats function", "C term_counts+total")}
        for _ in range(reps):   # interleave the variants within each repetition
            for k, q in zip(times, (CUR, B, C)):
                cur.execute("DROP TABLE IF EXISTS tfidf_x")
                t0 = time.perf_counter(); cur.execute(q % dict(n=n)); times[k].append(time.perf_counter() - t0)
                if _ == 0:
                    cur.execute("""SELECT count(*) FILTER (WHERE r.doc_id IS NULL OR x.doc_id IS NULL OR r.weight IS DISTINCT FROM x.weight)
                                   FROM tfidf_ref r FULL JOIN tfidf_x x USING (doc_id, term)""")
                    times[k].append(("diff", cur.fetchone()[0]))
        for k, v in times.items():
            ts = [t for t in v if not isinstance(t, tuple)]; diff = [t for t in v if isinstance(t, tuple)][0][1]
            print(f"workers={w}  {k:22s} median {statistics.median(ts):6.2f} s  runs {', '.join(f'{t:.2f}' for t in ts)}  rows differing from current: {diff}", flush=True)
    cur.execute("ALTER TABLE sp_docs RESET (parallel_workers)")
main()
