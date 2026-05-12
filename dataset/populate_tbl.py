#!/usr/bin/env python3
"""
Populate a documents table with content from a paragraphs file.
Each document has at least 20 words. Content can be repeated with different timestamps.
"""

import os
import psycopg2
from psycopg2 import sql
from datetime import datetime, timedelta
import random

# Directory containing this script
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# Default paragraphs file (same directory as script)
PARAGRAPHS_FILE = os.path.join(SCRIPT_DIR, "short_paragraphs.txt")

# Database connection parameters (match tf_idf/python/demo_usage.py)
DB_CONFIG = {
    "host": "127.0.0.1",
    "port": "5432",
    "database": "hadathdb",
    "user": "postgres",
    "password": "postgres",
}


def load_paragraphs(filepath=None):
    """
    Load paragraphs from a file. One paragraph per line. Empty lines are skipped.

    Args:
        filepath: Path to file. Defaults to paragraphs.txt in the script directory.

    Returns:
        List of non-empty paragraphs.
    """
    path = filepath or PARAGRAPHS_FILE
    with open(path, encoding="utf-8") as f:
        paragraphs = [line.strip() for line in f if line.strip()]
    if not paragraphs:
        raise ValueError(f"No paragraphs found in {path}")
    return paragraphs


def get_random_timestamp(base_year=2025):
    """Generate a random timestamp within the given year."""
    start = datetime(base_year, 1, 1)
    end = datetime(base_year, 12, 31, 23, 59, 59)
    delta = end - start
    random_seconds = random.randint(0, int(delta.total_seconds()))
    return start + timedelta(seconds=random_seconds)


def populate_dataset(num_documents=100, allow_repeats=True, paragraphs_file=None, table_name=None):
    """
    Populate a table with documents. Creates the table if it does not exist.

    Args:
        num_documents: Number of documents to insert
        allow_repeats: If True, same content can appear with different timestamps
        paragraphs_file: Path to paragraphs file. Defaults to paragraphs.txt in script directory.
        table_name: Name of the table to populate (required).
    """
    if not table_name:
        raise ValueError("table_name is required")

    paragraphs = load_paragraphs(paragraphs_file)
    conn = None
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cursor = conn.cursor()

        # Create table if it does not exist
        cursor.execute(
            sql.SQL("""
                CREATE TABLE IF NOT EXISTS {} (
                    doc_id SERIAL PRIMARY KEY,
                    txt TEXT,
                    ts TIMESTAMP DEFAULT NULL
                )
            """).format(sql.Identifier(table_name))
        )

        # Clear existing data (optional - comment out to append)
        cursor.execute(
            sql.SQL("TRUNCATE TABLE {} RESTART IDENTITY").format(sql.Identifier(table_name))
        )

        if allow_repeats:
            selected_paragraphs = [random.choice(paragraphs) for _ in range(num_documents)]
        else:
            if num_documents > len(paragraphs):
                raise ValueError(
                    f"Requested {num_documents} documents without repeats, "
                    f"but only {len(paragraphs)} paragraphs are available."
                )
            selected_paragraphs = random.sample(paragraphs, num_documents)

        for paragraph in selected_paragraphs:
            ts = get_random_timestamp()
            cursor.execute(
                sql.SQL("INSERT INTO {} (txt, ts) VALUES (%s, %s)").format(
                    sql.Identifier(table_name)
                ),
                (paragraph, ts),
            )

        conn.commit()
        print(f"Successfully inserted {num_documents} documents into {table_name}")

        # Verify word count
        cursor.execute(
            sql.SQL("""
                SELECT doc_id, txt, ts,
                       array_length(string_to_array(trim(txt), ' '), 1) as word_count
                FROM {}
                ORDER BY doc_id
            """).format(sql.Identifier(table_name)))
        rows = cursor.fetchall()
        min_words = min(r[3] for r in rows if r[3])
        print(f"Word count range: min={min_words} words per document")

        cursor.close()
    except psycopg2.Error as e:
        print(f"Database error: {e}")
        if conn:
            conn.rollback()
    finally:
        if conn:
            conn.close()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Populate a documents table with content from a paragraphs file")
    parser.add_argument(
        "-n", "--num",
        type=int,
        required=True,
        help="Number of documents to insert",
    )
    parser.add_argument(
        "--no-repeats",
        action="store_true",
        help="Use each paragraph only once (may need more paragraphs for large n)",
    )
    parser.add_argument(
        "-f", "--file",
        default=PARAGRAPHS_FILE,
        help="Path to paragraphs file",
    )
    parser.add_argument(
        "-t", "--table",
        required=True,
        help="Table name to populate",
    )
    args = parser.parse_args()

    random.seed(42)  # Reproducible results
    populate_dataset(
        num_documents=args.num,
        allow_repeats=not args.no_repeats,
        paragraphs_file=args.file,
        table_name=args.table,
    )
