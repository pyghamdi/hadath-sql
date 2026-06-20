#!/usr/bin/env python3
"""
Generate a single-pass clustering benchmark corpus: many rows of ~N words each,
with a monotonic timestamp column for clustering iteration order.

Documents use real English words from dataset/1000_long.txt when available,
with the same Gutenberg/common-word fallbacks as dataset/generate_long_texts.py.
Rows may repeat documents from the source pool.

Usage (from repository root):
  PGPASSWORD=postgres python3 single_pass_clustering/eval/generate_eval_data.py

  # Override defaults:
  PGPASSWORD=postgres python3 single_pass_clustering/eval/generate_eval_data.py \
    --table sp_eval_data --rows 10000 --words 1000
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timedelta
from io import StringIO

import psycopg2
from psycopg2 import sql

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
DATASET_DIR = os.path.join(REPO_ROOT, "dataset")
sys.path.insert(0, DATASET_DIR)

from generate_long_texts import (  # noqa: E402
    DEFAULT_TEXTS_FILE,
    load_document_source_pool,
)

DEFAULT_DB_CONFIG = {
    "host": "127.0.0.1",
    "port": "5432",
    "database": "hadathdb",
    "user": "postgres",
    "password": "postgres",
}
DEFAULT_BATCH_SIZE = 1_000
BASE_TS = datetime(2020, 1, 1, 0, 0, 0)


def env_int(name: str, default: str) -> int:
    raw = os.environ.get(name, default)
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(
            f"Invalid integer for {name}={raw!r}. "
            "When passing psql -v options across multiple shell lines, "
            "put a space before each trailing backslash "
            "(e.g. `-v words_per_row=100 \\`, not `-v words_per_row=100\\`)."
        ) from None


def resolve_texts_file(path: str | None) -> str | None:
    if not path:
        return None
    if os.path.isfile(path):
        return path
    repo_path = os.path.join(REPO_ROOT, path)
    if os.path.isfile(repo_path):
        return repo_path
    return path


def populate_table(
    table_name: str,
    num_rows: int,
    words_per_row: int,
    db_config: dict[str, str],
    batch_size: int = DEFAULT_BATCH_SIZE,
    texts_file: str | None = DEFAULT_TEXTS_FILE,
    use_download: bool = True,
) -> None:
    if num_rows < 1:
        raise ValueError(f"num_rows must be >= 1, got {num_rows}")
    if words_per_row < 1:
        raise ValueError(f"words_per_row must be >= 1, got {words_per_row}")
    if batch_size < 1:
        raise ValueError(f"batch_size must be >= 1, got {batch_size}")

    document_pool = load_document_source_pool(
        min_words=words_per_row,
        use_download=use_download,
        texts_file=resolve_texts_file(texts_file),
    )
    print(f"Using {len(document_pool)} source document(s); rows cycle through the pool")

    conn = None
    try:
        conn = psycopg2.connect(**db_config)
        conn.autocommit = False
        cursor = conn.cursor()

        cursor.execute(
            sql.SQL("DROP TABLE IF EXISTS {} CASCADE").format(sql.Identifier(table_name))
        )
        cursor.execute(
            sql.SQL(
                """
                CREATE TABLE {} (
                    doc_id integer PRIMARY KEY,
                    txt text NOT NULL,
                    ts timestamp NOT NULL
                )
                """
            ).format(sql.Identifier(table_name))
        )

        next_doc_id = 1
        while next_doc_id <= num_rows:
            batch_end = min(next_doc_id + batch_size - 1, num_rows)
            buffer = StringIO()
            for doc_id in range(next_doc_id, batch_end + 1):
                document = document_pool[(doc_id - 1) % len(document_pool)]
                ts = BASE_TS + timedelta(seconds=doc_id - 1)
                buffer.write(f"{doc_id}\t{document}\t{ts.isoformat(sep=' ')}\n")
            buffer.seek(0)
            cursor.copy_from(buffer, table_name, columns=("doc_id", "txt", "ts"))
            next_doc_id = batch_end + 1

        cursor.execute(sql.SQL("ANALYZE {}").format(sql.Identifier(table_name)))
        conn.commit()

        cursor.execute(
            sql.SQL(
                """
                SELECT
                    COUNT(*) AS row_count,
                    MIN(array_length(string_to_array(trim(txt), ' '), 1)) AS min_words,
                    MAX(array_length(string_to_array(trim(txt), ' '), 1)) AS max_words,
                    MIN(ts) AS min_ts,
                    MAX(ts) AS max_ts
                FROM {}
                """
            ).format(sql.Identifier(table_name))
        )
        row_count, min_words, max_words, min_ts, max_ts = cursor.fetchone()
        print(
            f"Loaded {row_count} rows into {table_name} "
            f"(words/row: min={min_words}, max={max_words}; ts: {min_ts} .. {max_ts})"
        )
    except psycopg2.Error as exc:
        if conn is not None:
            conn.rollback()
        raise SystemExit(f"Database error: {exc}") from exc
    finally:
        if conn is not None:
            conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Populate a single-pass clustering benchmark table with real-word documents"
    )
    parser.add_argument(
        "-t",
        "--table",
        default=os.environ.get("SP_EVAL_TABLE", "sp_eval_data"),
        help="Target table name (default: sp_eval_data)",
    )
    parser.add_argument(
        "-n",
        "--rows",
        type=int,
        default=env_int("SP_EVAL_ROWS", "100"),
        help="Number of documents to insert (default: 100)",
    )
    parser.add_argument(
        "-w",
        "--words",
        type=int,
        default=env_int("SP_EVAL_WORDS", "100"),
        help="Target words per document (default: 100)",
    )
    parser.add_argument(
        "-f",
        "--texts-file",
        default=os.environ.get("SP_EVAL_TEXTS_FILE", DEFAULT_TEXTS_FILE),
        help="Source texts file, one document per line (default: dataset/1000_long.txt)",
    )
    parser.add_argument(
        "--no-download",
        action="store_true",
        help="Do not download from Project Gutenberg if the texts file is missing",
    )
    parser.add_argument("--host", default=os.environ.get("PGHOST", DEFAULT_DB_CONFIG["host"]))
    parser.add_argument("--port", default=os.environ.get("PGPORT", DEFAULT_DB_CONFIG["port"]))
    parser.add_argument(
        "--database",
        default=os.environ.get("PGDATABASE", DEFAULT_DB_CONFIG["database"]),
    )
    parser.add_argument("--user", default=os.environ.get("PGUSER", DEFAULT_DB_CONFIG["user"]))
    parser.add_argument(
        "--password",
        default=os.environ.get("PGPASSWORD", DEFAULT_DB_CONFIG["password"]),
    )
    args = parser.parse_args()

    db_config = {
        "host": args.host,
        "port": args.port,
        "database": args.database,
        "user": args.user,
        "password": args.password,
    }

    populate_table(
        table_name=args.table,
        num_rows=args.rows,
        words_per_row=args.words,
        db_config=db_config,
        texts_file=args.texts_file,
        use_download=not args.no_download,
    )


if __name__ == "__main__":
    main()
