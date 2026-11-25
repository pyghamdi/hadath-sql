# Single-pass clustering, evaluation 2: HadathSQL against standard SQL

This file covers the comparison of the HadathSQL driver with the same single-pass
clustering written in standard SQL only, as a recursive CTE, and of HadathSQL's TF-IDF
stage with the same computation in standard SQL. HadathSQL is compared only with
standard SQL, not with applications that run outside the database. It is
separate from the ablation of the HadathSQL driver (`ABLATION.md`), which describes
the datasets and the server setup used here as well.

| Solution | Status |
|---|---|
| HadathSQL driver (`single_pass_clustering/sp_clustering.sql`; key `driver`) | ready |
| Standard SQL CTE (`prep_cte_standard.sql`, `run_cte_standard.sql`; key `cte-standard`) | ready (`comparison_cte.conf`) |
| TF-IDF stage in standard SQL (`tfidf_standard.sql`) | ready (`run_tfidf_standard.py`) |

## Standard SQL CTE

The Standard SQL CTE (`prep_cte_standard.sql`, `run_cte_standard.sql`; Appendix of the
paper) computes the same clusters in standard SQL only. It is far slower than the
drivers (in the preliminary runs, 25–75 s at 1,000 synthetic tweets and about 5 minutes
or more at 200 synthetic news documents), so it runs separately on smaller data
(`comparison_cte.conf`), with the HadathSQL driver at the same points, as the
comparison and the correctness reference.

- Datasets (`ABLATION.md`, *Datasets*) and thresholds as in the ablation.
- Documents: Synthetic-Tweets 100, 200, 400, 800, 1,600, 3,200, 6,400; Synthetic-News
  25, 50, 100, 200, 400, 800. The CTE's time and temporary files grow quadratically
  (it stores every intermediate state), so it cannot run at the ablation's sizes.
- CTE time: the wall-clock time of one `psql` session that runs its input preparation
  (`prep_cte_standard.sql`: numbering of the documents in timestamp order with its
  primary key, one row per (document, term) with its index, `ANALYZE`) and then the
  CTE (`run_cte_standard.sql`), whose assignments are written into `cte_rows_out`. Not
  included: building the weights table `sp_tfidf`, which is shared with the driver.
- Time limit: one hour, enforced with `statement_timeout`, so it applies to each SQL
  statement (in practice, the CTE query).
- Same repetitions (median of up to 3 runs; one run when a run takes 60 s or more)
  and dropout rule as the ablation; the time limit is longer than its 30 minutes.

Results: `results_comparison_cte_synthetic_tweets.csv`,
`results_comparison_cte_synthetic_news.csv`. A partial
run on the laptop (2026-10-20, stopped when the laptop shut down) is kept as
`results_cte_laptop_partial_*.csv`; it is preliminary and is to be redone on the server.

### TF-IDF stage in standard SQL (`tfidf_standard.sql`, `run_tfidf_standard.py`)

The CTE above starts from HadathSQL's weights table, whose terms come from
`to_tsvector`, which is not standard SQL. `tfidf_standard.sql` computes the same
weights with standard SQL only (paper, Appendix "TF-IDF Stage in Standard SQL"):
lowercasing with `LOWER`, splitting at every character that is not an ASCII letter
or digit (a recursive CTE generates the character positions, a running count of
separators numbers the words, `SUBSTRING` cuts them out), stop words removed with
`NOT EXISTS` against `std_stopwords` (PostgreSQL's `english.stop`), and no stemming.
On the synthetic datasets this gives the same terms as `to_tsvector`, so the weights
are identical; `run_tfidf_standard.py` checks this at every size (`mismatches`,
`max_abs_diff`).

- Both methods create a regular (logged) table, since standard SQL has no UNLOGGED
  tables; PostgreSQL's default configuration (up to 2 parallel workers).
- Sizes: Synthetic-Tweets 125 to 1,024,000, Synthetic-News 125 to 256,000 (doubling); median of up to 3 runs (one run when a run
  takes 60 s or more); 15-minute limit per run (`--timeout 900`).
- Run: `python3 run_tfidf_standard.py --timeout 900` (or, without a Python
  environment, `uv run --no-project --with psycopg2-binary python run_tfidf_standard.py --timeout 900`).

Results: `results_tfidf_standard_synthetic_*.csv` (server, to be run). A laptop run
(2026-11-23) is kept as `results_tfidf_standard_laptop_synthetic_*.csv`; it is
preliminary and is to be redone on the server.

## Python scripts: correctness checks only

The Python scripts in this folder are kept to check the correctness of the results,
not for performance comparison: their times are not part of the evaluation.

- `external_pipeline_clustering.py`, run by `run_comparison_python.py`: clusters the
  documents of HadathSQL's weights table with the driver's rules in Python and checks
  that every document is assigned to the same cluster as by the driver (`mismatches`).
- `tfidf_python.py`, run by `run_tfidf_comparison.py`: computes TF-IDF with
  scikit-learn and checks that it yields the same (doc_id, term) pairs as HadathSQL.
- `tokenizer_python.py`, checked by `check_tokenizer.py`: preprocesses text as
  `to_tsvector('english', ...)` does, so that the checks above start from the same terms.

## How to run (remote server)

1. Set up the server and the database as in `ABLATION.md` (*How to run*, steps 1–3).
2. After the ablation has finished (never at the same time as another sweep),
   `nohup bash sweep.sh comparison_cte.conf > sweep_comparison_cte.log 2>&1 &`.
3. Resuming and the server check work as for the ablation.
4. Copy back `results_comparison_cte_*.csv` and the log, and run
   `python3 render_results.py` to update the results tables here.

The preliminary light run on the laptop also timed the Standard SQL CTE at 200 to
1,000 documents; its results were removed from the repository with the Array CTE
(`ABLATION.md`).

## Results

Generated from the CSV files by `render_results.py` after every point. "> limit": the
run hit the time limit; "–": not run (the method had already hit the limit at a
smaller size). Times are seconds of clustering.

<!-- RESULTS:BEGIN -->
### Preliminary: Standard SQL CTE, partial laptop run

Run on the laptop, 2026-10-20; stopped when the laptop shut down. To be redone on the remote server.

#### Tweets (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 100 | 1 | 0.24 | 0.58 | 0.25 | 0 |
| 200 | 1 | 0.26 | 4.09 | 0.31 | 0 |
| 400 | 1 | 0.25 | 7.95 | 0.43 | 0 |
| 800 | 1 | 0.41 | 21.09 | 0.91 | 0 |
| 1600 | 1 | 0.49 | 52.83 | 1.44 | 0 |
| 3200 | 1 | 0.80 | 141.59 | 3.60 | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 100 | 50 | 0.18 | 0.58 | 0.23 | 0 |
| 200 | 61 | 0.20 | 4.32 | 0.29 | 0 |
| 400 | 66 | 0.24 | 7.13 | 0.39 | 0 |
| 800 | 67 | 0.32 | 23.99 | 0.60 | 0 |
| 1600 | 66 | 0.47 | 84.74 | 1.08 | 0 |
| 3200 | 67 | 0.86 | 316.87 | 2.18 | 0 |

**Threshold 0.4**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 100 | 88 | 0.20 | 0.64 | 0.22 | 0 |
| 200 | 154 | 0.20 | 5.37 | 0.27 | 0 |
| 400 | 232 | 0.24 | 9.70 | 0.38 | 0 |
| 800 | 296 | 0.32 | 34.65 | 0.64 | 0 |
| 1600 | 338 | 0.49 | 123.85 | 1.11 | 0 |
| 3200 | 361 | 1.22 | 432.02 | 2.43 | 0 |

**Threshold 0.6**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 100 | 100 | 0.20 | 0.67 | 0.23 | 0 |
| 200 | 200 | 0.21 | 5.94 | 0.27 | 0 |
| 400 | 397 | 0.25 | 11.46 | 0.39 | 0 |
| 800 | 799 | 0.33 | 48.59 | 0.54 | 0 |
| 1600 | 1574 | 0.50 | 184.02 | 1.15 | 0 |
| 3200 | 3110 | 0.92 | 708.57 | 2.21 | 0 |

**Threshold 0.8**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 100 | 100 | 0.19 | 0.66 | 0.23 | 0 |
| 200 | 200 | 0.20 | 5.73 | 0.28 | 0 |
| 400 | 400 | 0.24 | 11.57 | 0.36 | 0 |
| 800 | 800 | 0.31 | 45.46 | 0.55 | 0 |
| 1600 | 1600 | 0.50 | 180.76 | 1.00 | 0 |
| 3200 | 3200 | 0.91 | 808.05 | 2.16 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 100 | 100 | 0.24 | 0.82 | 0.29 | 0 |
| 200 | 200 | 0.26 | 6.41 | 0.28 | 0 |
| 400 | 400 | 0.24 | 13.66 | 0.50 | 0 |
| 800 | 800 | 0.37 | 50.71 | 0.60 | 0 |
| 1600 | 1600 | 1.35 | 183.39 | 1.09 | 0 |
| 3200 | 3200 | 0.79 | SLEPT | 2.06 | 0 |

#### News (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 25 | 1 | 0.32 | 6.20 | 0.43 | 0 |
| 50 | 1 | 0.46 | 23.46 | 0.72 | 0 |
| 100 | 1 | 0.77 | 82.05 | 1.28 | 0 |
| 200 | 1 | 1.54 | 279.36 | 2.30 | 0 |
| 400 | 1 | 2.83 | 637.93 | 4.63 | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Standard SQL CTE | HadathSQL (reference) | mismatches |
|---:|---:|---:|---:|---:|---:|
| 25 | 21 | 0.31 | 6.41 | 0.34 | 0 |
| 50 | 32 | 0.48 | 25.17 | 0.63 | 0 |
| 100 | 45 | 0.78 | 98.50 | 1.40 | 0 |

<!-- RESULTS:END -->
