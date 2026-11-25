"""Clustering stage: the HadathSQL driver (hsql_single_pass_clustering_tfidf) against
the external Python pipeline (external_pipeline_clustering.py). See STANDARD_SQL_COMPARISON.md,
"Python scripts: correctness checks only".

For each dataset and size: generate sp_docs with gen_synthetic_data.sql (same
settings and seed as run_point.sh) and build the TF-IDF table sp_tfidf once with
hsql_create_tf_idf_tbl, indexed on doc_id (not timed: both methods start from it).
Then, for each threshold, time

  driver  SELECT hsql_single_pass_clustering_tfidf('sp_docs', 'doc_id', 'ts',
                                                   'sp_tfidf', 'drv', <th>, TRUE)
  python  python3 external_pipeline_clustering.py --threshold <th> --out dpy
          (a separate process, as an application; its time is the sum of its
          export, clustering, and import steps, each also recorded, with the
          volume of data each transfer moves, py_export_mb and py_import_mb)

and check that both assign every document to the same cluster ("mismatches": the
number of documents whose cluster differs; it must be 0).

Each method is run up to --reps times (median reported) while a run takes less than
--rep-max seconds; slower runs are measured once. A run is stopped after --timeout
seconds, and a method that reaches it is not run at larger sizes of the same dataset
and threshold ("timeout").

  python3 run_comparison_python.py
  python3 run_comparison_python.py --settings synthetic_tweets --sizes 125 250 --thresholds 0.2
  uv run --no-project --with psycopg2-binary python run_comparison_python.py

Appends one line per (size, threshold) to results_comparison_python_<setting>.csv and
skips points already in it, so an interrupted sweep resumes where it stopped.
Run it on the database server with PGHOST=localhost (the default): the pipeline then
transfers its data over the loopback interface, the most favorable placement for it,
so its export and import times are a lower bound for a pipeline on another machine.
Connection: PGHOST, PGPORT, PGUSER, PGDATABASE (defaults as in run_point.sh:
localhost 54329 test hadath). The database must have HadathSQL installed
(setup_db.sh). Requires psycopg2.
"""
import argparse
import csv
import json
import os
import statistics
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
    "synthetic_tweets": [125 * 2 ** i for i in range(10)],  # 125 .. 64,000
    "synthetic_news": [125 * 2 ** i for i in range(8)],     # 125 .. 16,000
}
THRESHOLDS = ["0", "0.2", "0.4", "0.6", "0.8", "1"]
PY_STEPS = ["export_s", "cluster_s", "import_s"]
HDR = (["setting", "n", "threshold", "clusters", "driver_s", "py_s"] + ["py_" + s for s in PY_STEPS]
       + ["py_peak_mb", "py_export_mb", "py_import_mb", "mismatches", "load_start", "load_end"])


def loadavg():
    try:
        return f"{os.getloadavg()[0]:.2f}"
    except OSError:
        return "NA"


def psql(*args):
    subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", *args],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=HERE)


def prepare(setting, n):
    """Documents and the TF-IDF table shared by both methods (not timed)."""
    gen = [x for k, v in GEN[setting].items() for x in ("-v", f"{k}={v}")]
    psql("-v", f"n={n}", "-v", "topics=50", "-v", "seed=0.42", *gen, "-f", "gen_synthetic_data.sql")
    psql("-c", "VACUUM ANALYZE sp_docs", "-c", "SET client_min_messages = warning",
         "-c", "SELECT hsql_create_tf_idf_tbl('sp_docs', 'doc_id', 'txt', 'sp_tfidf', TRUE)",
         "-c", "CREATE INDEX ON sp_tfidf (doc_id)", "-c", "ANALYZE sp_tfidf")


def run_driver(th, timeout):
    """Seconds for one run of the driver, or None if it reaches the timeout."""
    conn = psycopg2.connect("", options=f"-c statement_timeout={timeout}s -c client_min_messages=warning")
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            t = time.perf_counter()
            try:
                cur.execute("SELECT hsql_single_pass_clustering_tfidf('sp_docs', 'doc_id', 'ts', "
                            "'sp_tfidf', 'drv', %s, TRUE)", (float(th),))
            except psycopg2.errors.QueryCanceled:
                return None
            return time.perf_counter() - t
    finally:
        conn.close()


def run_python(th, timeout):
    """The step times of one run of the pipeline (dict), or None at the timeout."""
    p = subprocess.run([sys.executable, str(HERE / "external_pipeline_clustering.py"),
                        "--threshold", th, "--out", "dpy", "--timeout", str(timeout)],
                       capture_output=True, text=True, cwd=HERE)
    if p.returncode == 3:
        return None
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    return json.loads(p.stdout)


def measure(run, reps, rep_max, key=None):
    """Median of up to reps runs (the run with the median time, for dict results)."""
    results = []
    for _ in range(reps):
        r = run()
        if r is None:
            return None
        results.append(r)
        if (r[key] if key else r) >= rep_max:
            break
    results.sort(key=(lambda r: r[key]) if key else None)
    if key:
        return results[(len(results) - 1) // 2]
    return statistics.median(results)


def check():
    with psycopg2.connect("") as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(DISTINCT cid) FROM drv_assignments")
        clusters = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM drv_assignments r "
                    "FULL JOIN dpy_assignments x USING (doc_id) WHERE x.cid IS DISTINCT FROM r.cid")
        return clusters, cur.fetchone()[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--settings", nargs="+", default=list(GEN), choices=list(GEN))
    ap.add_argument("--sizes", nargs="+", type=int)
    ap.add_argument("--thresholds", nargs="+", default=THRESHOLDS)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--rep-max", type=float, default=60)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--prefix", default="results_comparison_python_")
    args = ap.parse_args()

    for setting in args.settings:
        out = HERE / f"{args.prefix}{setting}.csv"
        done = set()
        if out.exists():
            with out.open() as f:
                done = {(int(r["n"]), r["threshold"]) for r in csv.DictReader(f)}
        else:
            with out.open("w", newline="") as f:
                csv.writer(f).writerow(HDR)
        stopped = set()   # (method, threshold) that reached the time limit
        for n in args.sizes or SIZES[setting]:
            todo = [th for th in args.thresholds if (n, th) not in done
                    and not {("driver", th), ("python", th)} <= stopped]
            if not todo:
                continue
            prepare(setting, n)
            for th in todo:
                start = loadavg()
                drv = None if ("driver", th) in stopped else \
                    measure(lambda: run_driver(th, args.timeout), args.reps, args.rep_max)
                py = None if ("python", th) in stopped else \
                    measure(lambda: run_python(th, args.timeout), args.reps, args.rep_max, "total_s")
                if drv is None:
                    stopped.add(("driver", th))
                if py is None:
                    stopped.add(("python", th))
                clusters, mism = check() if drv is not None and py is not None else ("NA", "NA")
                fmt = lambda s: "timeout" if s is None else f"{s:.3f}"
                row = [setting, n, th, clusters, fmt(drv), fmt(py and py["total_s"])]
                row += [fmt(py and py[s]) for s in PY_STEPS]
                row += ["NA" if py is None else f"{py['peak_mb']:.0f}"]
                row += ["NA" if py is None else f"{py[k]:.2f}" for k in ("export_mb", "import_mb")]
                row += [mism, start, loadavg()]
                with out.open("a", newline="") as f:
                    csv.writer(f).writerow(row)
                print(*row, sep=",", flush=True)


if __name__ == "__main__":
    main()
