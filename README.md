# HadathSQL

PostgreSQL extensions for event detection analytics: TF-IDF, custom aggregate functions, temporal and spatial partitioning, and single-pass clustering — all callable from SQL.

Functions are prefixed with `hsql_` (including aggregates and partition helpers).

## Prerequisites

- **PostgreSQL** (tested with local instances on port 5432)
- **psql** — required to run the install script (it chains multiple SQL files via `\ir`)
- **Python 3** with `psycopg2` — optional, for benchmarks, dataset loading, and Python reference implementations

Create a database if you do not have one yet:

```bash
createdb hadathdb
```

## Installing UDFs and UDAs

From the **repository root**, run:

```bash
psql -v ON_ERROR_STOP=1 -d hadathdb -f install.sql
```

Replace `hadathdb` with your database name. The script is idempotent: each module drops and recreates its own objects, so re-running is safe when definitions change.

`install.sql` loads everything in dependency order:

| Step | Script | What it installs |
|------|--------|------------------|
| 1 | `util/table_utils.sql` | Shared helpers (`hsql_table_exists_any_schema`, …) |
| 2 | `tf_idf/tf_idf.sql` | Text tokenization and TF-IDF table builders (`hsql_process_text`, `hsql_create_tf_idf_tbl`) |
| 3 | `agg_funcs/count_shared_terms.sql` | `hsql_count_shared_terms` aggregate |
| 4 | `agg_funcs/entropy.sql` | `hsql_entropy` aggregate |
| 5 | `time_partition/time_partitioning.sql` | `time_partition_id` type and `hsql_time_partition()` |
| 6 | `spatial_partition/space_partition.sql` | `spatial_partition_id` type and `hsql_spatial_partition()` |
| 7 | `single_pass_clustering/sp_clustering.sql` | Single-pass clustering with built-in TF-IDF |
| 8 | `single_pass_clustering/lsh_sp_clustering.sql` | LSH-accelerated variant |

> **Note:** The install script must be run with `psql`. Plain `CREATE` statements sent through other clients cannot resolve `\ir` includes.

### Optional modules

These are **not** part of `install.sql` but can be loaded separately when needed:

- `tf_idf/iterative/tf_idf_itr.sql` — iterative TF-IDF builder (`hsql_create_tf_idf_tbl_itr`)
- Individual demo and test scripts under each module directory

## Repository layout

```
hadathdb/
├── install.sql                 # One-shot install for all core functions
├── util/                       # Shared SQL helpers
├── tf_idf/                     # TF-IDF UDFs, Python reference, evals, tests
├── agg_funcs/                  # Custom aggregates (entropy, count_shared_terms)
├── time_partition/             # Temporal grid partitioning
├── spatial_partition/          # Web Mercator spatial grid partitioning
├── single_pass_clustering/     # Leader clustering (+ LSH variant)
├── dataset/                    # Sample corpora and loaders (see dataset/README.md)
└── cfunc/                      # C extension experiments (not used by install.sql)
```

## Quick examples

**Build a TF-IDF table** after loading documents into `docs(doc_id, txt)`:

```sql
SELECT hsql_create_tf_idf_tbl('docs', 'doc_id', 'txt', 'docs_tfidf', true);
```

**Run single-pass clustering** on a timestamp-ordered corpus:

```sql
SELECT hsql_single_pass_clustering(
    'docs', 'doc_id', 'txt', 'ts',
    'sp_clusters', 0.3, true
);
```

**Partition a timestamp** into fixed windows:

```sql
SELECT hsql_time_partition(ts, interval '1 hour');
```

See module-specific `demo.sql`, `test_*.sql`, and `evaluation/eval.sql` files for fuller workflows.

## Tests and benchmarks

Examples (from repo root, with functions already installed):

```bash
# TF-IDF SQL vs Python parity
psql -d hsql_test -f tf_idf/tests/test_sql_vs_python_parity.sql

# Aggregate function tests
psql -d hadathdb -f agg_funcs/tests/test_count_shared_terms.sql

# Runtime benchmarks (may require Python eval data scripts first)
psql -d hadathdb -f tf_idf/eval/eval.sql
psql -d hadathdb -f single_pass_clustering/eval/eval.sql
```

## Dataset

Sample text files and scripts for populating document tables live in [`dataset/`](dataset/README.md).
