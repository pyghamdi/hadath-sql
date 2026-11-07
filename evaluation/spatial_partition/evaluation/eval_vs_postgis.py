"""
hsql_spatial_partition vs. PostGIS ST_SquareGrid runtime comparison.

Both methods group points into a regular square grid on the Web Mercator plane
(EPSG:3857) and are timed on the same tables:

  hadath   SELECT hsql_spatial_partition(x, y, L) AS p, COUNT(*) ... GROUP BY p
  postgis  generate the grid with ST_SquareGrid over the extent of the points,
           join the points to the squares with ST_Intersects, GROUP BY (i, j)
  lateral  call ST_SquareGrid once per point (CROSS JOIN LATERAL), which returns
           only the square containing that point, GROUP BY (i, j). For a point
           within float precision of a square's upper edge it also returns the
           neighboring square, so a small share of points is counted twice.
  lateral_exact
           the lateral query plus an ST_Intersects filter that drops the
           squares that do not contain the point

Three point distributions are generated, each at several sizes:

  global   95% of the points in Gaussian clusters around twelve world cities
           and 5% spread uniformly over the populated latitudes of the whole
           Web Mercator plane (the world-wide social-media-like case)
  skewed   95% of the points in Gaussian clusters around five Saudi cities and
           5% spread uniformly over a country-sized bounding box, so most of
           the extent is empty (the country-wide social-media-like case)
  compact  all points in one Gaussian cluster around a single city, so the
           extent is small and almost every grid cell is occupied

Each table stores the same point twice, as (x, y) doubles for the UDF and as a
geometry with a GiST index for PostGIS. Index build time is reported separately
and is not part of the query times.

Usage (from repository root; needs psql on PATH and the PostGIS extension):
  python3 evaluation/spatial_partition/evaluation/eval_vs_postgis.py
  python3 evaluation/spatial_partition/evaluation/eval_vs_postgis.py --sizes 1000 10000 --keep-db

The script creates its own database (default: hsql_bench_postgis) and drops it
at the end unless --keep-db is given.
"""

import argparse
import csv
import math
import re
import statistics
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
UDF_SQL = REPO_ROOT / "spatial_partition" / "space_partition.sql"

EARTH_RADIUS_M = 6378137.0


def web_mercator(lat, lon):
    """Project WGS84 degrees to Web Mercator (EPSG:3857) meters."""
    x = EARTH_RADIUS_M * math.radians(lon)
    y = EARTH_RADIUS_M * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return round(x, 2), round(y, 2)


# City centers in Web Mercator meters (same points as test_spartition.sql).
SAUDI_CITIES = [
    # name, x, y, share of all points
    ("Riyadh", 5195870.63, 2840607.63, 0.30),
    ("Jeddah", 4362889.14, 2449900.22, 0.25),
    ("Makkah", 4433432.30, 2442329.09, 0.15),
    ("Dammam", 5572108.24, 3051889.53, 0.15),
    ("Madinah", 4409832.57, 2810613.91, 0.10),
]
WORLD_CITIES = [
    (name, *web_mercator(lat, lon), share)
    for name, lat, lon, share in [
        ("New York", 40.7128, -74.0060, 0.10),
        ("Los Angeles", 34.0522, -118.2437, 0.08),
        ("Mexico City", 19.4326, -99.1332, 0.08),
        ("Sao Paulo", -23.5505, -46.6333, 0.08),
        ("London", 51.5074, -0.1278, 0.08),
        ("Lagos", 6.5244, 3.3792, 0.08),
        ("Cairo", 30.0444, 31.2357, 0.08),
        ("Riyadh", 24.7136, 46.6753, 0.07),
        ("Mumbai", 19.0760, 72.8777, 0.08),
        ("Jakarta", -6.2088, 106.8456, 0.08),
        ("Tokyo", 35.6762, 139.6503, 0.08),
        ("Sydney", -33.8688, 151.2093, 0.06),
    ]
]
# Each distribution: city clusters, cluster spread, and the bounding box
# (x_min, y_min, x_max, y_max) of the uniform background points (None = no
# background; the cluster shares then have to sum to 1).
DISTRIBUTIONS = {
    "global": {
        "cities": WORLD_CITIES,
        "sigma_m": 15000,
        "bbox": (*web_mercator(-55, -179.9), *web_mercator(70, 179.9)),
    },
    "skewed": {
        "cities": SAUDI_CITIES,
        "sigma_m": 8000,
        "bbox": (3850000, 1850000, 6200000, 3800000),
    },
    "compact": {
        "cities": [("Riyadh", 5195870.63, 2840607.63, 1.0)],
        "sigma_m": 8000,
        "bbox": None,
    },
}


def psql(db, sql, timeout_ms=0, temp_limit_gb=0, check=True):
    """Run SQL through psql and return (returncode, stdout, stderr)."""
    cmd = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-d", db]
    if timeout_ms:
        sql = f"SET statement_timeout = {int(timeout_ms)};\n{sql}"
    if temp_limit_gb:
        sql = f"SET temp_file_limit = '{int(temp_limit_gb)}GB';\n{sql}"
    proc = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if check and proc.returncode != 0:
        sys.exit(f"psql failed:\n{sql}\n{proc.stderr}")
    return proc.returncode, proc.stdout, proc.stderr


def table_name(dist, n):
    return f"docs_{dist}_{n}"


def create_table(db, dist, n, seed):
    """Create and populate one benchmark table; return GiST build time in ms."""
    tbl = table_name(dist, n)
    cfg = DISTRIBUTIONS[dist]
    cities, sigma, bbox = cfg["cities"], cfg["sigma_m"], cfg["bbox"]
    # Pick a city by cumulative share; the remainder is uniform background.
    cases_x, cases_y, acc = [], [], 0.0
    for k, (_, cx, cy, share) in enumerate(cities):
        acc += share
        last = bbox is None and k == len(cities) - 1
        when = "WHEN true THEN" if last else f"WHEN r < {acc} THEN"
        cases_x.append(f"{when} {cx} + random_normal(0, {sigma})")
        cases_y.append(f"{when} {cy} + random_normal(0, {sigma})")
    if bbox is not None:
        x_min, y_min, x_max, y_max = bbox
        cases_x.append(f"ELSE {x_min} + random() * {x_max - x_min}")
        cases_y.append(f"ELSE {y_min} + random() * {y_max - y_min}")
    x_expr = "CASE " + " ".join(cases_x) + " END"
    y_expr = "CASE " + " ".join(cases_y) + " END"

    psql(db, f"""
        DROP TABLE IF EXISTS {tbl};
        CREATE TABLE {tbl} (
            id integer PRIMARY KEY,
            x double precision NOT NULL,
            y double precision NOT NULL,
            geom geometry(Point, 3857)
        );
        SELECT setseed({seed});
        INSERT INTO {tbl} (id, x, y)
        SELECT g, {x_expr}, {y_expr}
        FROM (SELECT g, random() AS r FROM generate_series(1, {n}) AS g) AS s;
        UPDATE {tbl} SET geom = ST_SetSRID(ST_MakePoint(x, y), 3857);
        VACUUM FULL {tbl};
    """)
    _, out, _ = psql(db, f"""
        \\timing on
        CREATE INDEX {tbl}_geom_gist ON {tbl} USING gist (geom);
    """)
    index_ms = parse_time_ms(out)
    psql(db, f"ANALYZE {tbl};")
    return index_ms


def parse_time_ms(psql_output):
    times = re.findall(r"Time: ([\d.]+) ms", psql_output)
    return float(times[-1]) if times else None


def hadath_query(tbl, cell):
    return f"""
        SELECT COUNT(*) AS groups, COALESCE(SUM(n), 0) AS points FROM (
            SELECT hsql_spatial_partition(x, y, {cell}) AS p, COUNT(*) AS n
            FROM {tbl} GROUP BY p
        ) AS s"""


def postgis_query(tbl, cell):
    return f"""
        SELECT COUNT(*) AS groups, COALESCE(SUM(n), 0) AS points FROM (
            SELECT g.i, g.j, COUNT(*) AS n
            FROM {tbl} AS d JOIN ST_SquareGrid({cell},
                ST_SetSRID(ST_EstimatedExtent('{tbl}', 'geom'), 3857)) AS g
              ON ST_Intersects(d.geom, g.geom)
            GROUP BY g.i, g.j
        ) AS s"""


def lateral_query(tbl, cell):
    return f"""
        SELECT COUNT(*) AS groups, COALESCE(SUM(n), 0) AS points FROM (
            SELECT g.i, g.j, COUNT(*) AS n
            FROM {tbl} AS d CROSS JOIN LATERAL ST_SquareGrid({cell}, d.geom) AS g
            GROUP BY g.i, g.j
        ) AS s"""


def lateral_exact_query(tbl, cell):
    return f"""
        SELECT COUNT(*) AS groups, COALESCE(SUM(n), 0) AS points FROM (
            SELECT g.i, g.j, COUNT(*) AS n
            FROM {tbl} AS d CROSS JOIN LATERAL ST_SquareGrid({cell}, d.geom) AS g
            WHERE ST_Intersects(d.geom, g.geom)
            GROUP BY g.i, g.j
        ) AS s"""


QUERIES = {
    "hadath": hadath_query,
    "postgis": postgis_query,
    "lateral": lateral_query,
    "lateral_exact": lateral_exact_query,
}


def grid_cells(db, tbl, cell):
    """Number of squares ST_SquareGrid generates for this table's extent."""
    _, out, _ = psql(db, f"""
        SELECT (floor(ST_XMax(e) / {cell}) - floor(ST_XMin(e) / {cell}) + 1)
             * (floor(ST_YMax(e) / {cell}) - floor(ST_YMin(e) / {cell}) + 1)
        FROM (SELECT ST_EstimatedExtent('{tbl}', 'geom') AS e) AS s;
    """)
    return int(float(out.strip()))


def time_query(db, query, runs, timeout_ms, temp_limit_gb):
    """Return (median_ms, groups, points, all run times, status).

    status is "ok", or "timeout" / "temp_file_limit" when the query was stopped
    by one of the two guards; median_ms is then None.
    """
    times, groups, points = [], None, None
    for run in range(runs + 1):  # first run is a warm-up and is discarded
        rc, out, err = psql(db, f"\\timing on\n{query};", timeout_ms=timeout_ms,
                            temp_limit_gb=temp_limit_gb, check=False)
        if rc != 0:
            if "statement timeout" in err:
                return None, None, None, times, "timeout"
            if "temp_file_limit" in err:
                return None, None, None, times, "temp_file_limit"
            sys.exit(f"query failed:\n{query}\n{err}")
        ms = parse_time_ms(out)
        row = [line for line in out.splitlines() if "|" in line][-1]
        groups, points = (int(float(v)) for v in row.split("|"))
        if run > 0:
            times.append(ms)
        # Skip repeats of very slow queries; one measurement is enough there.
        if ms > 120_000:
            times = times or [ms]
            break
    return statistics.median(times), groups, points, times, "ok"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default="hsql_bench_postgis")
    ap.add_argument("--sizes", type=int, nargs="+", default=[1000, 10000, 100000, 1000000, 10000000])
    ap.add_argument("--dists", nargs="+", default=["skewed", "compact"], choices=list(DISTRIBUTIONS))
    ap.add_argument("--methods", nargs="+", default=list(QUERIES), choices=list(QUERIES))
    ap.add_argument("--cell", type=int, default=1000, help="grid cell side length in meters")
    ap.add_argument("--runs", type=int, default=3, help="timed runs per query (after one warm-up)")
    ap.add_argument("--timeout-s", type=int, default=900, help="per-query timeout in seconds")
    ap.add_argument("--temp-limit-gb", type=int, default=40,
                    help="per-query temp file limit; ST_SquareGrid spills its squares to disk")
    ap.add_argument("--out", default="spatial_partition_vs_postgis.csv")
    ap.add_argument("--keep-db", action="store_true")
    args = ap.parse_args()

    subprocess.run(["dropdb", "--if-exists", args.db], check=True)
    subprocess.run(["createdb", args.db], check=True)
    try:
        psql(args.db, "CREATE EXTENSION postgis;")
        psql(args.db, UDF_SQL.read_text())
        _, out, _ = psql(args.db, "SELECT version(); SELECT postgis_full_version();")
        print(out)

        rows = []
        timeout_ms = args.timeout_s * 1000
        plans_path = Path(args.out).with_suffix(".plans.txt")
        plans_path.write_text("")
        for dist in args.dists:
            failed = {}  # method -> reason; once a method fails, larger sizes are skipped
            for i, n in enumerate(args.sizes):
                tbl = table_name(dist, n)
                index_ms = create_table(args.db, dist, n, seed=round(0.1 + 0.01 * i, 2))
                row = {
                    "dist": dist, "points": n, "cell_m": args.cell,
                    "grid_cells": grid_cells(args.db, tbl, args.cell),
                    "gist_build_ms": index_ms,
                }
                for method in args.methods:
                    if method in failed:
                        ms, groups, points, times = None, None, None, []
                        status = f"skipped ({failed[method]} at a smaller size)"
                    else:
                        ms, groups, points, times, status = time_query(
                            args.db, QUERIES[method](tbl, args.cell), args.runs,
                            timeout_ms, args.temp_limit_gb)
                        if status != "ok":
                            failed[method] = status
                    row.update({
                        f"{method}_ms": ms, f"{method}_status": status,
                        f"{method}_groups": groups, f"{method}_points": points,
                        f"{method}_runs": times,
                    })
                rows.append(row)
                print(row, flush=True)

                # Keep the chosen plans next to the timings.
                with open(plans_path, "a") as f:
                    for method in args.methods:
                        _, plan, _ = psql(args.db, f"EXPLAIN (COSTS OFF) {QUERIES[method](tbl, args.cell)};")
                        f.write(f"-- {tbl} / {method}\n{plan}\n")

        with open(args.out, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        print(f"results written to {args.out}")
    finally:
        if not args.keep_db:
            subprocess.run(["dropdb", "--if-exists", args.db], check=True)


if __name__ == "__main__":
    main()
