#!/usr/bin/env python3
"""
Populate tfidf_from_python (doc_id, term, weight) using python/tf_idf.TFIDF + the same
PostgreSQL tokenizer as tf_idf.sql (hsql_process_text).

Prerequisite: table tfidf_parity_corpus(doc_id, txt) already exists and is filled
(see tf_idf/tests/test_sql_vs_python_parity.sql). Functions from tf_idf.sql must be loaded in the database.

Usage (from repository root, after corpus table exists):
  python3 tf_idf/python/generate_sql_python_parity_reference.py

Connection: requires libpq env vars (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD).
`tf_idf/tests/test_sql_vs_python_parity.sql` sets these before invoking this script.
"""

from __future__ import annotations

import os
import sys

import psycopg2
from psycopg2.extras import execute_values

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from tf_idf import TFIDF


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def _connect():
    return psycopg2.connect(
        host=_required_env("PGHOST"),
        port=_required_env("PGPORT"),
        dbname=_required_env("PGDATABASE"),
        user=_required_env("PGUSER"),
        password=_required_env("PGPASSWORD"),
    )


def _make_tokenizer(conn):
    def tokenize(text: str):
        if not text:
            return []
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM hsql_process_text(%s)", (text,))
            rows = cur.fetchall()
        tokens: list[str] = []
        for term, freq in rows:
            if term and freq:
                tokens.extend([term] * int(freq))
        return tokens

    return tokenize


def main() -> int:
    conn = _connect()
    conn.autocommit = True
    try:
        tokenizer = _make_tokenizer(conn)
        model = TFIDF(tokenizer=tokenizer)

        with conn.cursor() as cur:
            cur.execute(
                "SELECT doc_id, txt FROM tfidf_parity_corpus ORDER BY doc_id"
            )
            corpus = cur.fetchall()

        if not corpus:
            print("tfidf_parity_corpus is empty; nothing to do.", file=sys.stderr)
            return 1

        for _doc_id, txt in corpus:
            model.insert(txt if txt is not None else "")

        rows_out: list[tuple[int, str, float]] = []
        for doc_id, txt in corpus:
            vec = model.get_tfidf_vector(txt if txt is not None else "")
            for term, weight in vec.items():
                rows_out.append((doc_id, term, float(weight)))

        with conn.cursor() as cur:
            cur.execute("DROP TABLE IF EXISTS tfidf_from_python CASCADE")
            cur.execute(
                "CREATE TABLE tfidf_from_python ("
                "doc_id INTEGER NOT NULL, term TEXT NOT NULL, weight FLOAT NOT NULL)"
            )
            execute_values(
                cur,
                "INSERT INTO tfidf_from_python (doc_id, term, weight) VALUES %s",
                rows_out,
                page_size=500,
            )
        print(f"Inserted {len(rows_out)} rows into tfidf_from_python.")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
