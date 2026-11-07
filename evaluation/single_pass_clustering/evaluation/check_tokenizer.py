"""Check that tokenizer_python.Tokenizer yields the same terms and counts as
to_tsvector('english', txt).

  python3 check_tokenizer.py vocab   # every word gen_synthetic_data.sql can produce
  python3 check_tokenizer.py docs    # every document of the current sp_docs table

Connection: libpq environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE).
Result on 2026-11-07 (PostgreSQL 18, PyStemmer 3): vocab 30,000 words, 0 differ;
Synthetic-Tweets 64,000 docs, 0 differ; Synthetic-News 16,000 docs, 0 differ.
"""
import subprocess
import sys
from collections import Counter

from tokenizer_python import Tokenizer

VOCAB = """
WITH v AS (
  SELECT 'x' || translate((t * 1000 + k)::text, '0123456789', 'qwrzjkvbpm') AS w
  FROM generate_series(1, 50) t, generate_series(0, 199) k
  UNION ALL
  SELECT 'y' || translate(k::text, '0123456789', 'qwrzjkvbpm') FROM generate_series(0, 19999) k)
SELECT w, w, 1 FROM v"""
DOCS_PG = """SELECT doc_id, u.lexeme, array_length(u.positions, 1)
             FROM sp_docs, unnest(to_tsvector('english', txt)) u"""


def q(sql):
    out = subprocess.run(["psql", "-At", "-F", "\t", "-c", sql],
                         capture_output=True, text=True, check=True).stdout
    return [line.split("\t") for line in out.splitlines() if line]


def main(mode):
    tok = Tokenizer()
    if mode == "vocab":
        rows = q(VOCAB)
        bad = [w for w, _, _ in rows if tok(w) != Counter({w: 1})]
        print(f"vocab: {len(rows)} words, {len(bad)} differ {bad[:5]}")
        return
    pg = {}
    for d, t, c in q(DOCS_PG):
        pg.setdefault(d, Counter())[t] = int(c)
    docs = q("SELECT doc_id, txt FROM sp_docs")
    bad = [d for d, txt in docs if tok(txt) != pg.get(d, Counter())]
    print(f"docs: {len(docs)} documents, {len(bad)} differ {bad[:5]}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "vocab")
