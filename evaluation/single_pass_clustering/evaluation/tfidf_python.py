"""TF-IDF stage of the external Python pipeline (COMPARISON.md, "External pipeline").

Uses scikit-learn's TfidfVectorizer, the standard Python tool for TF-IDF, with
its default weighting. Starts from a documents table in PostgreSQL and ends with
a TF-IDF table in PostgreSQL with the same schema as the one hsql_create_tf_idf_tbl
builds, (doc_id INTEGER, term TEXT, weight FLOAT), in four timed steps:

  export    SELECT doc_id, txt FROM <docs>                       (one query)
  tokenize  tokenizer_python.Tokenizer.tokens on every document (the same
            preprocessing as to_tsvector('english', ...), so both methods
            produce the same terms)
  weights   TfidfVectorizer().fit_transform on the token lists
  import    CREATE UNLOGGED TABLE <out> and COPY the non-zero weights into it
            (unlogged, as the table of hsql_create_tf_idf_tbl in the comparison)

TfidfVectorizer settings: analyzer = identity on the token lists (the
tokenization is the step above); everything else at its default, that is
raw counts as TF, smoothed IDF ln((1 + N) / (1 + df)) + 1, and each document
vector normalized to unit length (L2). The weights therefore differ from those
of hsql_create_tf_idf_tbl, (count / total terms) * log10(N / df); the
(doc_id, term) pairs are the same.

  python3 tfidf_python.py [--docs sp_docs] [--out tfidf_py]

Prints one JSON object with the time of each step in seconds (connection setup and
Python start-up are not included), the number of rows written, and the peak
resident memory of the process in MB (peak_mb).
Connection: libpq environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE).
Requires psycopg2, PyStemmer, and scikit-learn.
"""
import argparse
import io
import json
import resource
import sys
import time
from pathlib import Path

import psycopg2
from sklearn.feature_extraction.text import TfidfVectorizer

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from tokenizer_python import Tokenizer  # noqa: E402


def _identity(tokens):
    return tokens


def export_docs(conn, docs_tbl):
    with conn.cursor() as cur:
        cur.execute(f'SELECT doc_id, txt FROM "{docs_tbl}"')
        return cur.fetchall()


def tokenize_docs(docs, tokenizer):
    return [tokenizer.tokens(txt or "") for _, txt in docs]


def compute_weights(token_lists):
    vectorizer = TfidfVectorizer(analyzer=_identity)
    matrix = vectorizer.fit_transform(token_lists)  # documents x terms, sparse (CSR)
    return matrix, vectorizer.get_feature_names_out()


def import_weights(conn, out_tbl, doc_ids, matrix, terms):
    coo = matrix.tocoo()
    buf = io.StringIO()
    buf.writelines(f"{doc_ids[i]}\t{terms[j]}\t{w!r}\n"
                   for i, j, w in zip(coo.row.tolist(), coo.col.tolist(), coo.data.tolist()))
    buf.seek(0)
    with conn.cursor() as cur:
        cur.execute(f'DROP TABLE IF EXISTS "{out_tbl}"')
        cur.execute(f'CREATE UNLOGGED TABLE "{out_tbl}" (doc_id INTEGER, term TEXT, weight FLOAT)')
        cur.copy_expert(f'COPY "{out_tbl}" (doc_id, term, weight) FROM STDIN', buf)
    conn.commit()
    return coo.nnz


def peak_rss_mb():
    """Peak resident memory of this process (ru_maxrss: KB on Linux, bytes on macOS)."""
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024


def run(docs_tbl="sp_docs", out_tbl="tfidf_py"):
    tokenizer = Tokenizer()
    conn = psycopg2.connect("")
    try:
        t0 = time.perf_counter()
        docs = export_docs(conn, docs_tbl)
        t1 = time.perf_counter()
        token_lists = tokenize_docs(docs, tokenizer)
        t2 = time.perf_counter()
        matrix, terms = compute_weights(token_lists)
        t3 = time.perf_counter()
        rows = import_weights(conn, out_tbl, [d for d, _ in docs], matrix, terms)
        t4 = time.perf_counter()
        return dict(export_s=t1 - t0, tokenize_s=t2 - t1, weights_s=t3 - t2,
                    import_s=t4 - t3, total_s=t4 - t0, docs=len(docs), rows=rows,
                    peak_mb=peak_rss_mb())
    finally:
        conn.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--docs", default="sp_docs")
    ap.add_argument("--out", default="tfidf_py")
    a = ap.parse_args()
    print(json.dumps(run(a.docs, a.out)))
