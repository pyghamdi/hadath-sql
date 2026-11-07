"""
Event-type UDFs runtime evaluation: runs eval.sql for several keyword fractions
and saves the results.

For each fraction of documents that contain a keyword, eval.sql builds a table
of synthetic documents from a fixed random seed, trains a prototype classifier,
and times the queries listed at its top. This script runs it in a database of
its own and writes, in the results/ folder next to it:

  runs.csv         every timed run: kw_fraction, query, run, selected_rows, elapsed_ms
  summary.csv      per kw_fraction and query: selected_rows, min_ms, median_ms, and
                   ratio_to_two_udfs, the median over the rounds of the time of
                   the query divided by the time of two_udfs in the same round
  plans.txt        the plan of every query, per kw_fraction
  dataset.csv      per kw_fraction: rows, rows with a keyword, positive rows
  environment.txt  PostgreSQL version, settings, machine, and the arguments of the run
  kw_<f>.log       the psql output of eval.sql

Usage (from repository root; needs psql, createdb, and dropdb on PATH):
  python3 evaluation/event_type/evaluation/run_eval.py
  python3 evaluation/event_type/evaluation/run_eval.py --fractions 0.1 --rows 50000 --keep-db

The script creates its own database (default: hsql_bench_event_type), replacing
a database of that name left by an earlier run, and drops it at the end unless
--keep-db is given.

The queries are run in rounds, each round running every query once. On the
laptop used so far, the speed of the machine changed by a factor of up to two
between rounds, so compare the queries with ratio_to_two_udfs, which pairs the
runs of the same round, and read min_ms as the time at the highest speed.
"""

import argparse
import csv
import datetime
import io
import os
import platform
import statistics
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
UDF_SQL = REPO_ROOT / "event_type" / "event_type.sql"
EVAL_SQL = Path(__file__).resolve().parent / "eval.sql"
RESULTS_DIR = Path(__file__).resolve().parent / "results"

# The settings of eval.sql, applied to the sessions that print the plans too.
SESSION_OPTIONS = "-c max_parallel_workers_per_gather=0 -c jit=off"


def psql(db, *args):
    env = dict(os.environ, PGOPTIONS=SESSION_OPTIONS)
    result = subprocess.run(
        ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", db, *args],
        capture_output=True, text=True, env=env,
    )
    if result.returncode != 0:
        raise SystemExit(f"psql failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


def query_rows(db, sql):
    return list(csv.DictReader(io.StringIO(psql(db, "--csv", "-c", sql))))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--fractions", nargs="+", default=["0.01", "0.1", "0.5"],
                        help="fractions of documents that contain a keyword")
    parser.add_argument("--rows", type=int, default=50000, help="number of documents")
    parser.add_argument("--train-rows", type=int, default=20000,
                        help="number of documents used to train the classifier")
    parser.add_argument("--runs", type=int, default=15, help="timed runs per query")
    parser.add_argument("--db", default="hsql_bench_event_type")
    parser.add_argument("--keep-db", action="store_true")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(exist_ok=True)
    subprocess.run(["dropdb", "--if-exists", args.db], check=True)
    subprocess.run(["createdb", args.db], check=True)
    psql(args.db, "-q", "-f", str(UDF_SQL))

    runs, summary, datasets, plans = [], [], [], []
    for fraction in args.fractions:
        print(f">>> kw_fraction={fraction}", flush=True)
        log = psql(
            args.db,
            "-v", f"n_rows={args.rows}", "-v", f"kw_fraction={fraction}",
            "-v", f"train_rows={args.train_rows}", "-v", f"runs={args.runs}",
            "-f", str(EVAL_SQL),
        )
        (RESULTS_DIR / f"kw_{fraction}.log").write_text(log)

        fraction_runs = query_rows(
            args.db,
            "SELECT query, run, selected_rows, elapsed_ms FROM event_type_eval_results "
            "WHERE run > 0 ORDER BY query, run")
        runs += [{"kw_fraction": fraction, **row} for row in fraction_runs]

        baseline = {row["run"]: float(row["elapsed_ms"])
                    for row in fraction_runs if row["query"] == "two_udfs"}
        for query in sorted({row["query"] for row in fraction_runs}):
            query_runs = [row for row in fraction_runs if row["query"] == query]
            times = [float(row["elapsed_ms"]) for row in query_runs]
            ratio = statistics.median(
                float(row["elapsed_ms"]) / baseline[row["run"]] for row in query_runs)
            selected = {row["selected_rows"] for row in query_runs}
            summary.append({
                "kw_fraction": fraction, "query": query,
                "selected_rows": "/".join(sorted(selected)),
                "min_ms": min(times), "median_ms": round(statistics.median(times), 1),
                "ratio_to_two_udfs": round(ratio, 2),
            })
            print(f"    {query:20s} min {min(times):9.1f} ms   "
                  f"median {statistics.median(times):9.1f} ms   ratio {ratio:5.2f}", flush=True)

        datasets += [{"kw_fraction": fraction, **row} for row in query_rows(
            args.db,
            "SELECT COUNT(*) AS row_count, "
            "COUNT(*) FILTER (WHERE hsql_overlap(tsv, 'earthquake, shaking') > 0) AS with_keyword, "
            "COUNT(*) FILTER (WHERE is_earthquake) AS report_earthquake, "
            "round(avg(length(tsv)), 1) AS avg_terms, "
            "(SELECT COUNT(*) FROM hsql_event_type_model) AS model_rows "
            "FROM event_type_eval_docs")]

        for query in query_rows(
                args.db, "SELECT query, predicate FROM event_type_eval_queries ORDER BY position"):
            plan = psql(
                args.db, "-At", "-c",
                "EXPLAIN (COSTS OFF) SELECT COUNT(*) FROM event_type_eval_docs WHERE "
                + query["predicate"])
            plans.append(f"== kw_fraction={fraction}  {query['query']}\n{plan}\n")

    for name, rows in (("runs.csv", runs), ("summary.csv", summary), ("dataset.csv", datasets)):
        with open(RESULTS_DIR / name, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    (RESULTS_DIR / "plans.txt").write_text("\n".join(plans))

    settings = psql(
        args.db, "-At", "-c",
        "SELECT version(); "
        "SELECT name || ' = ' || setting FROM pg_settings WHERE name IN "
        "('shared_buffers', 'work_mem', 'max_parallel_workers_per_gather', 'jit', "
        "'lc_collate', 'default_text_search_config') ORDER BY name; "
        "SELECT 'database collation = ' || datcollate FROM pg_database "
        "WHERE datname = current_database();")
    (RESULTS_DIR / "environment.txt").write_text(
        f"date: {datetime.datetime.now().isoformat(timespec='seconds')}\n"
        f"arguments: {vars(args)}\n"
        f"machine: {platform.platform()}, {platform.processor()}, {os.cpu_count()} logical CPUs\n"
        f"{settings}")

    if not args.keep_db:
        subprocess.run(["dropdb", args.db], check=True)
    print(f">>> results written to {RESULTS_DIR}")


if __name__ == "__main__":
    main()
