"""TF-IDF stage: HadathSQL (hsql_create_tf_idf_tbl) against the same weights computed
in standard SQL only (tfidf_standard.sql). See COMPARISON.md, "TF-IDF stage in
standard SQL".

For each dataset and size: generate sp_docs with gen_synthetic_data.sql (same
settings and seed as run_point.sh and run_tfidf_comparison.py), then time

  hadath    SELECT hsql_create_tf_idf_tbl('sp_docs', 'doc_id', 'txt', 'tfidf_sql', true, false)
  standard  psql -f tfidf_standard.sql   (creates tfidf_std)

Both create a regular (logged) table, since standard SQL has no UNLOGGED tables, and
both run with PostgreSQL's configuration (by default up to 2 parallel workers per
query, chosen by the planner). After the runs, the two tables are compared: they
must have the same (doc_id, term) pairs and the same weights (up to 1e-9); the
number of differing rows is recorded as "mismatches".

The stop-word table std_stopwords(word) is loaded from PostgreSQL's own English list
(<sharedir>/tsearch_data/english.stop, located with pg_config; --stopwords overrides).

Each method is run up to --reps times (median reported) while a run takes less than
--rep-max seconds; slower runs are measured once. A run is stopped after --timeout
seconds, and a method that reaches it is not run at larger sizes of the same dataset
(its time is then "timeout").

  python3 run_tfidf_standard.py --timeout 900
  python3 run_tfidf_standard.py --settings synthetic_tweets --sizes 125 250 --reps 1
  uv run --no-project --with psycopg2-binary python run_tfidf_standard.py --timeout 900

Appends one line per size to results_tfidf_standard_<setting>.csv and skips sizes
already in it, so an interrupted sweep resumes where it stopped.
Connection: PGHOST, PGPORT, PGUSER, PGDATABASE (defaults as in run_point.sh:
localhost 54329 test hadath). The database must have HadathSQL installed
(setup_db.sh). Requires psycopg2.
"""
import argparse
import csv
import os
import statistics
import subprocess
import time
from pathlib import Path

import psycopg2

HERE = Path(__file__).resolve().parent
for k, v in dict(PGHOST="localhost", PGPORT="54329", PGUSER="test", PGDATABASE="hadath").items():
    os.environ.setdefault(k, v)

GEN = {
    "synthetic_tweets": dict(topic_words=8, vocab=12, bg_words=4, bg_vocab=2000),
    "synthetic_news": dict(topic_words=200, vocab=200, bg_words=200, bg_vocab=20000),
}
SIZES = {
    "synthetic_tweets": [125 * 2 ** i for i in range(14)],  # 125 .. 1,024,000
    "synthetic_news": [125 * 2 ** i for i in range(12)],    # 125 .. 256,000
}
HDR = ["setting", "n", "rows", "hadath_s", "standard_s", "ratio", "std_rows",
       "mismatches", "max_abs_diff", "load_start", "load_end"]
HADATH_SQL = "SELECT hsql_create_tf_idf_tbl('sp_docs', 'doc_id', 'txt', 'tfidf_sql', true, false)"
STANDARD_SQL = (HERE / "tfidf_standard.sql").read_text()


def loadavg():
    try:
        return f"{os.getloadavg()[0]:.2f}"
    except OSError:
        return "NA"


def psql(*args):
    subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", *args],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=HERE)


def generate(setting, n):
    gen = [x for k, v in GEN[setting].items() for x in ("-v", f"{k}={v}")]
    psql("-v", f"n={n}", "-v", "topics=50", "-v", "seed=0.42", *gen, "-f", "gen_synthetic_data.sql")
    psql("-c", "VACUUM ANALYZE sp_docs")


def load_stopwords(path):
    words = sorted({w.strip() for w in Path(path).read_text().splitlines() if w.strip()})
    with psycopg2.connect("") as conn, conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS std_stopwords")
        cur.execute("CREATE TABLE std_stopwords (word VARCHAR(64) PRIMARY KEY)")
        cur.executemany("INSERT INTO std_stopwords VALUES (%s)", [(w,) for w in words])
    print(f"loaded {len(words)} stop words from {path}")


def stopword_file():
    share = subprocess.run(["pg_config", "--sharedir"], capture_output=True, text=True,
                           check=True).stdout.strip()
    return Path(share) / "tsearch_data" / "english.stop"


def run_once(sql, timeout):
    """Seconds for one run of sql, or None if it reaches the timeout."""
    conn = psycopg2.connect("", options=f"-c statement_timeout={timeout}s -c client_min_messages=warning")
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            t = time.perf_counter()
            try:
                cur.execute(sql)
            except psycopg2.errors.QueryCanceled:
                return None
            return time.perf_counter() - t
    finally:
        conn.close()


def timed(sql, reps, rep_max, timeout):
    times = []
    for _ in range(reps):
        s = run_once(sql, timeout)
        if s is None:
            return None
        times.append(s)
        if s >= rep_max:
            break
    return statistics.median(times)


def compare():
    with psycopg2.connect("") as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM tfidf_sql")
        rows = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM tfidf_std")
        std_rows = cur.fetchone()[0]
        cur.execute("""
            SELECT COUNT(*) FILTER (WHERE h.weight IS NULL OR s.weight IS NULL
                                    OR abs(h.weight - s.weight) > 1e-9),
                   COALESCE(MAX(abs(h.weight - s.weight)), 0)
            FROM tfidf_sql AS h FULL JOIN tfidf_std AS s USING (doc_id, term)""")
        mismatches, max_diff = cur.fetchone()
    return rows, std_rows, mismatches, max_diff


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--settings", nargs="+", default=list(GEN), choices=list(GEN))
    ap.add_argument("--sizes", nargs="+", type=int)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--rep-max", type=float, default=60)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--stopwords", help="stop-word file (default: PostgreSQL's english.stop)")
    ap.add_argument("--prefix", default="results_tfidf_standard_")
    args = ap.parse_args()

    load_stopwords(args.stopwords or stopword_file())
    for setting in args.settings:
        out = HERE / f"{args.prefix}{setting}.csv"
        done = set()
        if out.exists():
            with out.open() as f:
                done = {int(r["n"]) for r in csv.DictReader(f)}
        else:
            with out.open("w", newline="") as f:
                csv.writer(f).writerow(HDR)
        stopped = set()
        for n in args.sizes or SIZES[setting]:
            if n in done:
                continue
            start = loadavg()
            generate(setting, n)
            times = {}
            for name, sql in (("hadath", HADATH_SQL), ("standard", STANDARD_SQL)):
                times[name] = None if name in stopped else timed(sql, args.reps, args.rep_max, args.timeout)
                if times[name] is None:
                    stopped.add(name)
            if "hadath" in stopped and "standard" in stopped:
                break
            if times["hadath"] is not None and times["standard"] is not None:
                rows, std_rows, mismatches, max_diff = compare()
                ratio = f"{times['standard'] / times['hadath']:.1f}"
            else:
                rows = std_rows = mismatches = max_diff = ratio = "NA"
            fmt = lambda s: "timeout" if s is None else f"{s:.3f}"
            row = [setting, n, rows, fmt(times["hadath"]), fmt(times["standard"]), ratio, std_rows,
                   mismatches, max_diff if max_diff == "NA" else f"{max_diff:.2e}", start, loadavg()]
            with out.open("a", newline="") as f:
                csv.writer(f).writerow(row)
            print(*row, sep=",", flush=True)


if __name__ == "__main__":
    main()
