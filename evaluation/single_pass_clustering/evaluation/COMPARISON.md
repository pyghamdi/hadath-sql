# Single-pass clustering, evaluation 2: HadathSQL against other solutions

This file covers the comparison of the HadathSQL driver with other ways to run the
same single-pass clustering: the Standard SQL CTE and an external pipeline. It is
separate from the ablation of the HadathSQL driver (`ABLATION.md`), which describes
the datasets and the server setup used here as well.

| Solution | Status |
|---|---|
| HadathSQL driver (`single_pass_clustering/sp_clustering.sql`; key `driver`) | ready |
| Standard SQL CTE (`prep_cte_standard.sql`, `run_cte_standard.sql`; key `cte-standard`) | ready (`comparison_cte.conf`) |
| External pipeline (clustering outside the database) | to be defined |

## Standard SQL CTE

The Standard SQL CTE (`prep_cte_standard.sql`, `run_cte_standard.sql`; Appendix of the
paper) computes the same clusters in standard SQL only. It is far slower than the
drivers (in the preliminary runs, 25–75 s at 1,000 synthetic tweets and about 5 minutes
or more at 200 synthetic news documents), so it runs separately on smaller data
(`comparison_cte.conf`), with the HadathSQL driver at the same points, as the
comparison and the correctness reference.

- Datasets (`ABLATION.md`, *Datasets*) and thresholds as in the ablation.
- Documents: Synthetic-Tweets 100, 200, 400, 800, 1,600, 3,200; Synthetic-News 25, 50,
  100, 200, 400.
- CTE time: its input preparation (numbering of the documents and their term rows)
  plus the query; the time limit applies to each of the two separately.
- Same repetitions (median of up to 3 runs; one run when a run takes 60 s or more),
  time limit (30 minutes per run), and dropout rule as the ablation.

Results: `results_comparison_cte_synthetic_tweets.csv`,
`results_comparison_cte_synthetic_news.csv`. A partial
run on the laptop (2026-10-20, stopped when the laptop shut down) is kept as
`results_cte_laptop_partial_*.csv`; it is preliminary and is to be redone on the server.

## External pipeline

To be defined: the system (e.g. a Python program that reads the documents from the
database, clusters them, and writes the clusters back), what its time includes
(data transfer, TF-IDF), and how its clusters are checked against HadathSQL's.

## How to run (remote server)

1. Set up the server and the database as in `ABLATION.md` (*How to run*, steps 1–3).
2. After the ablation has finished (never at the same time as another sweep),
   `nohup bash sweep.sh comparison_cte.conf > sweep_comparison_cte.log 2>&1 &`.
3. Resuming and the server check work as for the ablation.
4. Copy back `results_comparison_cte_*.csv` and the log, and run
   `python3 render_results.py` to update the results tables here.

The preliminary light run on the laptop (`ABLATION.md`) also timed the Standard SQL
CTE and the Array CTE (non-standard) at 200 to 1,000 documents.

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
