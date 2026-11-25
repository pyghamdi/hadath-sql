"""Clustering stage of the external Python pipeline (STANDARD_SQL_COMPARISON.md, "Python scripts: correctness checks only").

The baseline of an application without a driver UDF: it reads HadathSQL's TF-IDF
weights table out of PostgreSQL, runs single-pass clustering in Python, and writes
the clusters back into tables with the same schema as the output tables of the
HadathSQL driver (hsql_single_pass_clustering_tfidf, sp_clustering.sql). Three timed
steps:

  export   SELECT doc_id FROM <docs> ORDER BY <ts>, doc_id, and
           SELECT doc_id, term, weight FROM <tfidf>                 (two queries)
  cluster  single-pass clustering in pure Python, in memory (below)
  import   create <out>, <out>_summed_centroid, <out>_cluster_assignments with
           hsql_create_tbls_for_single_pass_clustering (the driver's schema, keys,
           and indexes) and COPY the clusters, centroids, and assignments into them;
           one transaction, logged tables, as the driver's

The clustering follows the driver rule by rule, so that both assign every document
to the same cluster (run_comparison_python.py checks this):
  - documents in timestamp order; each document's vector is its rows of <tfidf>;
  - candidates: the clusters whose centroid shares a term with the document (found
    through a dictionary from each term to those clusters, the counterpart of the
    driver's term index), plus the newest cluster with similarity 0;
  - similarity: cosine of the document vector and the cluster's summed centroid,
    dot / (||doc|| * sqrt(sum_sq_norm)), 0 when either norm is 0;
  - the best candidate is the one with the highest similarity, ties going to the
    newest cluster (highest cid); the document joins it if the similarity reaches
    the threshold (>=), and otherwise starts a new cluster (cid = previous + 1);
  - adding a document adds its positive weights to the centroid sums and updates
    sum_sq_norm by sum(w * (2 * old + w)) over those terms (Equation 3 of the paper),
    as the driver does, instead of recomputing the norm;
  - the centroids are written as sums, with sum_sq_norm, as the driver leaves them.

  python3 external_pipeline_clustering.py --threshold 0.4 [--docs sp_docs]
      [--ts ts] [--tfidf sp_tfidf] [--out dpy] [--timeout 1800]

Prints one JSON object with the time of each step in seconds (connection setup and
Python start-up are not included), the numbers of documents, weights rows, and
clusters, the peak resident memory of the process in MB (peak_mb), and the volume of
data transferred in each direction in MB (export_mb, import_mb), so that the cost of
the transfers can be estimated for any network bandwidth. export_mb is the size of the
rows that PostgreSQL sends in its text protocol (DataRow messages: 7 bytes per row and
4 bytes plus the text of each value), computed from the rows received; import_mb is
the size of the COPY data sent.

Placement: run on the database server with PGHOST=localhost, the transfers cross the
loopback interface, which is the most favorable case for the pipeline: the times
include converting the rows to and from PostgreSQL's text format, but almost no
network cost. If the
clustering takes longer than --timeout seconds, it stops, prints {"timeout": true},
and exits with status 3.
Connection: libpq environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE).
Requires psycopg2. The database must have HadathSQL installed.
"""
import argparse
import io
import json
import math
import resource
import sys
import time

import psycopg2


class Timeout(Exception):
    pass


def row_bytes(values):
    """Size of one DataRow message of PostgreSQL's protocol in text format: message
    type (1), length (4), number of columns (2), and per value its length (4) and
    text. Floats are sent in their shortest exact form, as repr writes them."""
    return 7 + sum(4 + len((repr(v) if isinstance(v, float) else str(v)).encode()) for v in values)


def export(conn, docs_tbl, ts_col, tfidf_tbl):
    """Document ids in timestamp order, and each document's (term, weight) rows."""
    with conn.cursor() as cur:
        cur.execute(f'SELECT doc_id FROM "{docs_tbl}" ORDER BY "{ts_col}", doc_id')
        order = [r[0] for r in cur.fetchall()]
        cur.execute(f'SELECT doc_id, term, weight FROM "{tfidf_tbl}"')
        rows = cur.fetchall()
    vectors = {}
    for doc_id, term, weight in rows:
        vectors.setdefault(doc_id, []).append((term, weight))
    return order, vectors, rows


def cluster(order, vectors, threshold, deadline):
    """Single-pass clustering with the rules of the driver (see the module docstring).
    Returns the assignments {doc_id: cid}, and per cluster (cid - 1) its centroid sums
    {term: sum}, its sum_sq_norm, and its size."""
    centroids = []      # centroids[cid - 1]: {term: sum of the weights of its documents}
    sum_sq = []         # sum_sq[cid - 1]: squared norm of the summed centroid
    sizes = []          # sizes[cid - 1]: number of documents
    term_index = {}     # term -> list of the cids whose centroid contains the term
    assignments = {}
    for k, doc_id in enumerate(order):
        if k % 256 == 0 and time.perf_counter() > deadline:
            raise Timeout
        doc = vectors.get(doc_id, ())
        best_cid = None
        if centroids:
            doc_norm = math.sqrt(sum(w * w for _, w in doc))
            dots = {}
            for term, w in doc:
                for cid in term_index.get(term, ()):
                    dots[cid] = dots.get(cid, 0.0) + w * centroids[cid - 1][term]
            newest = len(centroids)
            best_cid, best_sim = newest, -math.inf
            for cid in list(dots) + [newest]:
                prod = dots.get(cid) if cid in dots else None
                denom = doc_norm * math.sqrt(sum_sq[cid - 1])
                sim = prod / denom if prod is not None and denom != 0.0 else 0.0
                if sim > best_sim or (sim == best_sim and cid > best_cid):
                    best_cid, best_sim = cid, sim
            if not best_sim >= threshold:
                best_cid = None
        if best_cid is None:                       # new, empty cluster
            centroids.append({})
            sum_sq.append(0.0)
            sizes.append(0)
            best_cid = len(centroids)
        centroid = centroids[best_cid - 1]
        delta = 0.0
        for term, w in doc:
            if w > 0.0:
                old = centroid.get(term)
                if old is None:
                    centroid[term] = w
                    term_index.setdefault(term, []).append(best_cid)
                    delta += w * w
                else:
                    centroid[term] = old + w
                    delta += w * (2.0 * old + w)
        sum_sq[best_cid - 1] += delta
        sizes[best_cid - 1] += 1
        assignments[doc_id] = best_cid
    return assignments, centroids, sum_sq, sizes


def import_clusters(conn, out_tbl, assignments, centroids, sum_sq, sizes):
    """Writes the clusters into the driver's output tables (one transaction)."""
    sent = []

    def copy(cur, table, columns, lines):
        buf = io.StringIO()
        buf.writelines(lines)
        buf.seek(0)
        cur.copy_expert(f'COPY "{table}" ({columns}) FROM STDIN', buf)
        sent.append(buf)

    with conn.cursor() as cur:
        cur.execute("SET client_min_messages = warning")
        cur.execute("SELECT hsql_create_tbls_for_single_pass_clustering(%s, %s, %s, TRUE)",
                    (out_tbl, out_tbl + "_summed_centroid", out_tbl + "_cluster_assignments"))
        copy(cur, out_tbl, "cid, doc_count, sum_sq_norm",
             (f"{i + 1}\t{n}\t{s!r}\n" for i, (n, s) in enumerate(zip(sizes, sum_sq))))
        copy(cur, out_tbl + "_summed_centroid", "cid, term, weight",
             (f"{i + 1}\t{term}\t{w!r}\n"
              for i, (c, n) in enumerate(zip(centroids, sizes)) for term, w in c.items()))
        copy(cur, out_tbl + "_cluster_assignments", "doc_id, cid",
             (f"{d}\t{c}\n" for d, c in assignments.items()))
        if sizes:   # keep the SERIAL sequence of cid consistent with the rows copied
            cur.execute("SELECT setval(pg_get_serial_sequence(%s, 'cid'), %s)",
                        (f'"{out_tbl}"', len(sizes)))
    conn.commit()
    return sent


def peak_rss_mb():
    """Peak resident memory of this process (ru_maxrss: KB on Linux, bytes on macOS)."""
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024


def run(threshold, docs_tbl="sp_docs", ts_col="ts", tfidf_tbl="sp_tfidf", out_tbl="dpy",
        timeout=1800):
    conn = psycopg2.connect("")
    try:
        t0 = time.perf_counter()
        order, vectors, rows = export(conn, docs_tbl, ts_col, tfidf_tbl)
        t1 = time.perf_counter()
        assignments, centroids, sum_sq, sizes = cluster(order, vectors, threshold, t0 + timeout)
        t2 = time.perf_counter()
        sent = import_clusters(conn, out_tbl, assignments, centroids, sum_sq, sizes)
        t3 = time.perf_counter()
        # Volumes, computed after the timed steps so that they do not add to the times.
        export_bytes = sum(row_bytes((d,)) for d in order) + sum(row_bytes(r) for r in rows)
        import_bytes = sum(len(buf.getvalue().encode()) for buf in sent)
        return dict(export_s=t1 - t0, cluster_s=t2 - t1, import_s=t3 - t2, total_s=t3 - t0,
                    docs=len(order), rows=len(rows), clusters=len(sizes), peak_mb=peak_rss_mb(),
                    export_mb=export_bytes / 1e6, import_mb=import_bytes / 1e6)
    finally:
        conn.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--threshold", type=float, required=True)
    ap.add_argument("--docs", default="sp_docs")
    ap.add_argument("--ts", default="ts")
    ap.add_argument("--tfidf", default="sp_tfidf")
    ap.add_argument("--out", default="dpy")
    ap.add_argument("--timeout", type=float, default=1800,
                    help="seconds after which the run stops (export and clustering)")
    a = ap.parse_args()
    try:
        print(json.dumps(run(a.threshold, a.docs, a.ts, a.tfidf, a.out, a.timeout)))
    except Timeout:
        print(json.dumps({"timeout": True}))
        sys.exit(3)
