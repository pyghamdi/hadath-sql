"""TF-IDF stage: HadathSQL (hsql_create_tf_idf_tbl) against the Python pipeline
(tfidf_python.py). See COMPARISON.md, "TF-IDF stage".

For each dataset and size: generate sp_docs with gen_synthetic_data.sql (same
settings and seed as run_point.sh), then time

  python  tfidf_python.py (scikit-learn TfidfVectorizer, single-threaded): export +
          tokenize + weights + import, each step timed; its time includes the
          export and the import
  sql     SELECT hsql_create_tf_idf_tbl('sp_docs', 'doc_id', 'txt', 'tfidf_sql', true, true)
          with parallel workers and work_mem as below

Both start from sp_docs and end with a TF-IDF table in PostgreSQL. Both tables are
UNLOGGED (no write-ahead log), so that the times measure computing the weights rather
than PostgreSQL's logging of the rows written.

Parallelism: the point of the comparison is the benefit of running TF-IDF inside a
DBMS that computes in parallel, against single-threaded scikit-learn. PostgreSQL
therefore uses --workers parallel workers (default: physical cores - 1; the leader
process works too, so all cores are used): max_parallel_workers_per_gather and
max_parallel_workers are set for the session, and the parallel_workers storage
parameter of sp_docs is set so that the planner does not reduce the number for a
small table. The server's max_worker_processes (postgresql.conf, restart needed)
must be at least --workers; the script stops otherwise. The number of workers
PostgreSQL actually launches is recorded for every size (sql_workers_launched).

Memory: PostgreSQL's work_mem is set, for every size, to the peak resident memory
of the Python process at that size (Python runs first), so that both methods have
a similar memory budget (--work-mem sets a fixed value instead).

Each method is run up to --reps times (median reported) while a run takes less than
--rep-max seconds; slower runs are measured once. A run is stopped after --timeout
seconds, and a method that reaches it is not run at larger sizes of the same
dataset. After the runs, the two tables are compared on their (doc_id, term) pairs,
which must be the same; the weights differ, since TfidfVectorizer uses its own
default formula (see tfidf_python.py).

  python3 run_tfidf_comparison.py                       # full sweep
  python3 run_tfidf_comparison.py --settings synthetic_news --sizes 125 250 --reps 1

Appends one line per point to results_tfidf_<setting>.csv and skips points already
in it, so an interrupted sweep resumes where it stopped.
Connection: PGHOST, PGPORT, PGUSER, PGDATABASE (defaults as in run_point.sh:
localhost 54329 test hadath). The database must have HadathSQL installed
(setup_db.sh). Requires psycopg2, PyStemmer, and scikit-learn.
"""
import argparse
import csv
import json
import math
import os
import platform
import subprocess
import sys
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
    "synthetic_tweets": [125 * 2 ** i for i in range(12)],  # 125 .. 256,000
    "synthetic_news": [125 * 2 ** i for i in range(10)],    # 125 .. 64,000
}
PY_STEPS = ["export_s", "tokenize_s", "weights_s", "import_s"]
HDR = (["setting", "n", "rows", "sql_s", "py_s"] + ["py_" + s for s in PY_STEPS]
       + ["py_peak_mb", "work_mem_mb", "sql_workers", "sql_workers_launched",
          "py_rows", "missing", "load_start", "load_end"])


def physical_cores():
    """Number of physical cores (not hardware threads) of this machine."""
    try:
        if platform.system() == "Darwin":
            return int(subprocess.run(["sysctl", "-n", "hw.physicalcpu"], capture_output=True,
                                      text=True, check=True).stdout)
        out = subprocess.run(["lscpu", "-p=Core,Socket"], capture_output=True, text=True,
                             check=True).stdout
        return len({line for line in out.splitlines() if not line.startswith("#")})
    except (OSError, subprocess.CalledProcessError, ValueError):
        return os.cpu_count() or 1


def loadavg():
    try:
        return f"{os.getloadavg()[0]:.2f}"
    except OSError:
        return "NA"


def psql(*args):
    subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", *args],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=HERE)


def generate(setting, n, workers):
    gen = [x for k, v in GEN[setting].items() for x in ("-v", f"{k}={v}")]
    psql("-v", f"n={n}", "-v", "topics=50", "-v", "seed=0.42", *gen, "-f", "gen_synthetic_data.sql")
    psql("-c", f"ALTER TABLE sp_docs SET (parallel_workers = {workers})", "-c", "VACUUM ANALYZE sp_docs")


def session_options(timeout, workers, work_mem_mb):
    return (f"-c statement_timeout={timeout}s -c client_min_messages=warning"
            f" -c max_parallel_workers_per_gather={workers} -c max_parallel_workers={workers}"
            f" -c work_mem={work_mem_mb}MB")


def workers_launched(workers, work_mem_mb):
    """Workers PostgreSQL launches for the parallel tokenization of sp_docs (as in
    hsql_create_tf_idf_tbl, which sets parallel_tuple_cost = 0)."""
    conn = psycopg2.connect("", options=session_options(3600, workers, work_mem_mb)
                            + " -c parallel_tuple_cost=0")
    try:
        with conn.cursor() as cur:
            # The same tokenization as the query of hsql_create_tf_idf_tbl; the terms are
            # used, so the planner cannot drop the to_tsvector call.
            cur.execute("""EXPLAIN (ANALYZE, FORMAT JSON) SELECT count(*) FROM
                           (SELECT doc_id, to_tsvector('english', coalesce(txt, '')) AS tsv
                            FROM sp_docs OFFSET 0) src
                           CROSS JOIN LATERAL hsql_term_counts(src.tsv) AS t""")
            plan = cur.fetchone()[0][0]["Plan"]
    finally:
        conn.close()
    stack = [plan]
    while stack:
        node = stack.pop()
        if "Workers Launched" in node:
            return node["Workers Launched"]
        stack.extend(node.get("Plans", []))
    return 0


def run_sql(timeout, workers, work_mem_mb):
    """One timed run of hsql_create_tf_idf_tbl; seconds or 'TIMEOUT'."""
    conn = psycopg2.connect("", options=session_options(timeout, workers, work_mem_mb))
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            t0 = time.perf_counter()
            try:
                cur.execute("SELECT hsql_create_tf_idf_tbl('sp_docs', 'doc_id', 'txt', 'tfidf_sql', true, true)")
            except psycopg2.errors.QueryCanceled:
                return "TIMEOUT"
            return time.perf_counter() - t0
    finally:
        conn.close()


def run_python(timeout):
    """One run of tfidf_python.py in its own process; dict of step times or 'TIMEOUT'."""
    try:
        out = subprocess.run([sys.executable, str(HERE / "tfidf_python.py"), "--out", "tfidf_py"],
                             capture_output=True, text=True, check=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    return json.loads(out)


def measure(fn, key, reps, rep_max):
    """Median over up to `reps` runs of fn(); returns the run whose `key` is the median."""
    runs = []
    for _ in range(reps):
        r = fn()
        if r == "TIMEOUT":
            return "TIMEOUT"
        runs.append(r)
        if (r[key] if isinstance(r, dict) else r) >= rep_max:
            break
    runs.sort(key=lambda r: r[key] if isinstance(r, dict) else r)
    return runs[(len(runs) - 1) // 2]


def compare():
    conn = psycopg2.connect("")
    try:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT (SELECT count(*) FROM tfidf_sql), (SELECT count(*) FROM tfidf_py),
                       count(*) FILTER (WHERE s.doc_id IS NULL OR p.doc_id IS NULL)
                FROM tfidf_sql s FULL JOIN tfidf_py p USING (doc_id, term)""")
            return cur.fetchone()
    finally:
        conn.close()


def check_server(workers):
    conn = psycopg2.connect("")
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT current_setting('max_worker_processes')::int")
            mwp = cur.fetchone()[0]
    finally:
        conn.close()
    if mwp < workers:
        sys.exit(f"max_worker_processes is {mwp}, below --workers {workers}: set "
                 f"max_worker_processes = {workers} or more in postgresql.conf and restart "
                 f"PostgreSQL (or pass --workers {mwp}).")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--settings", nargs="+", default=list(GEN))
    ap.add_argument("--sizes", nargs="+", type=int, help="override the sizes of every setting")
    ap.add_argument("--workers", type=int, default=max(physical_cores() - 1, 0),
                    help="parallel workers for PostgreSQL (default: physical cores - 1)")
    ap.add_argument("--work-mem", type=int, metavar="MB",
                    help="fixed work_mem in MB (default: Python's peak memory at each size)")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--rep-max", type=float, default=60)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--prefix", default="results_tfidf_")
    a = ap.parse_args()
    check_server(a.workers)
    print(f"workers={a.workers} work_mem={'Python peak' if a.work_mem is None else a.work_mem}",
          flush=True)

    for setting in a.settings:
        out = HERE / f"{a.prefix}{setting}.csv"
        done = set()
        if out.exists():
            with out.open() as f:
                rows = list(csv.DictReader(f))
            if rows and list(rows[0].keys()) != HDR:
                sys.exit(f"{out} has other columns; move it away first")
            done = {int(r["n"]) for r in rows}
            stopped = {m for r in rows for m in ("sql", "py") if r[f"{m}_s"] == "TIMEOUT"}
        else:
            out.write_text(",".join(HDR) + "\n")
            stopped = set()
        for n in a.sizes or SIZES[setting]:
            if n in done:
                continue
            load_start = loadavg()
            generate(setting, n, a.workers)
            py = ("NA" if "py" in stopped else
                  measure(lambda: run_python(a.timeout), "total_s", a.reps, a.rep_max))
            peak = py["peak_mb"] if isinstance(py, dict) else None
            work_mem = a.work_mem or (math.ceil(peak) if peak else 1024)
            launched = workers_launched(a.workers, work_mem)
            sql = ("NA" if "sql" in stopped else
                   measure(lambda: run_sql(a.timeout, a.workers, work_mem), None, a.reps, a.rep_max))
            for m, r in (("sql", sql), ("py", py)):
                if r == "TIMEOUT":
                    stopped.add(m)
            if sql not in ("NA", "TIMEOUT") and py not in ("NA", "TIMEOUT"):
                rows_sql, rows_py, missing = compare()
            else:
                rows_sql, rows_py, missing = ("NA",) * 3
            fmt = lambda x: f"{x:.3f}" if isinstance(x, float) else str(x)  # noqa: E731
            py_cols = ([fmt(py["total_s"])] + [fmt(py[s]) for s in PY_STEPS]
                       if isinstance(py, dict) else [py] * (1 + len(PY_STEPS)))
            line = ([setting, str(n), str(rows_sql), fmt(sql)] + py_cols
                    + [f"{peak:.0f}" if peak else "NA", str(work_mem), str(a.workers), str(launched),
                       str(rows_py), str(missing), load_start, loadavg()])
            with out.open("a") as f:
                f.write(",".join(line) + "\n")
            print(",".join(line), flush=True)


if __name__ == "__main__":
    main()
