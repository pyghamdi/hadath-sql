# Single-pass clustering, evaluation 1: ablation of the HadathSQL driver

This file covers the ablation: the HadathSQL driver against variants of it that each
lack one optimization, to be run on the remote server. The comparison of HadathSQL
with other solutions (the Standard SQL CTE, an external pipeline) is a separate
evaluation, in `COMPARISON.md`; both use the datasets and the server setup described
here. The runs made on the laptop while the drivers were developed are recorded
under *Preliminary runs*.

## Design

Questions: how much does each optimization of the HadathSQL driver contribute, and how
much do the three contribute together? Three variants each remove exactly one
optimization, and a fourth removes all three; otherwise every variant is the HadathSQL
driver's code:
the variants are generated from `single_pass_clustering/sp_clustering.sql` by
`make_ablation_variants.py` (run by `setup_db.sh`; rerun it whenever
`sp_clustering.sql` changes).

| Driver | Key | What is removed | File (function) |
|---|---|---|---|
| HadathSQL | `driver` | nothing | `single_pass_clustering/sp_clustering.sql` (`hsql_single_pass_clustering_tfidf`) |
| without indexes | `noidx` | the index on the TF-IDF table's `doc_id` (the driver reads an unindexed copy) and the term index of the centroid table, so every document scans both tables; the primary keys stay, since the upsert needs the one on (cid, term) | `driver_variant_hadathsql_no_index.sql` (`hsql_spc_hadathsql_noidx`) |
| without summed centroids | `mean` | centroids stored as running means instead of sums, so adding a document rewrites the whole centroid and recomputes its norm from it | `driver_variant_hadathsql_mean.sql` (`hsql_spc_hadathsql_mean`) |
| without prepared statements | `noprep` | the per-document statements are parsed and planned at every execution | `driver_variant_hadathsql_no_prepared.sql` (`hsql_spc_hadathsql_noprep`) |
| without all three | `noopt` | all three of the above (unindexed TF-IDF copy, no term index, running means, no prepared statements) | `driver_variant_hadathsql_no_optimizations.sql` (`hsql_spc_hadathsql_noopt`) |

Comparisons: each single-removal variant against HadathSQL gives the contribution of
that optimization with the other two present; the variant without all three against
HadathSQL gives their combined effect; comparing the combined effect with the single
contributions shows whether the optimizations interact (e.g. summed centroids save
little while every document scans the whole centroid table anyway). The basic driver
(`d1`) is not used here: it also lacks stored norms, the statistics refresh, the
planner setting, and the fill factor, so its gap to HadathSQL could not be attributed
to the three optimizations.

Kept in every variant: merged per-document statements (2 per document, 3 for a new
cluster), stored norms, the statistics refresh during the pass,
`random_page_cost = 1.1`, and fill factor 80 on the centroid table.

**What is measured.**
- Clustering time only: the TF-IDF table is built once per dataset and size by
  `hsql_create_tf_idf_tbl`, indexed on `doc_id`, and timed separately (column TF-IDF).
- Driver time: the whole clustering call (output tables, ordering of the documents,
  the loop, and the final division of the sums).
- Wall-clock time measured by the client; the median of up to 3 runs per point, and a
  single run when a run takes 60 s or more.
- Time limit: 30 minutes per run (`statement_timeout`). Within a (dataset, threshold)
  series, a driver that hits the limit is not run at larger sizes. The variant without
  all three is expected to hit it early at threshold 0 (one growing cluster).
- Correctness: after each point, the number of documents whose cluster differs from
  the HadathSQL driver's, summed over the variants (column mismatches; expected 0).
- Load: the machine's 1-minute load average at the start and end of each point
  (columns `load_start`, `load_end`), to detect interference from other users' jobs on
  the shared server. The benchmark itself keeps one core busy, so a load of about 1 is
  normal during a run; a load clearly above 1 means other jobs were running.

**Parameters** (`ablation.conf`):
- Datasets: Synthetic-Tweets and Synthetic-News (see *Datasets* below).
- Thresholds: 0, 0.2, 0.4, 0.6, 0.8, 1.
- Documents, doubling from one size to the next, so that the time ratio between
  neighboring sizes shows the growth rate (about 2: linear; about 4: quadratic):
  Synthetic-Tweets 125 to 64,000 (10 sizes); Synthetic-News 125 to 16,000 (8 sizes). The
  sizes start at 125 because the pilot (`pilot.csv`, 2026-10-23) showed that the
  variants without summed centroids exceed 15 minutes at 1,000 documents at threshold 0.

Results: `results_ablation_synthetic_tweets.csv`, `results_ablation_synthetic_news.csv`.

## Observations (run completed 2026-10-25)

Run on the server from 2026-10-23 06:34 to 2026-10-25 02:26 (about 44 hours), 108
points (Synthetic-Tweets 10 sizes, Synthetic-News 8 sizes, 6 thresholds each); raw log in
`sweep_ablation.log`, pilot in `pilot.csv`, server configuration in `machine_server.txt`.

1. **Correctness.** 0 mismatches at every point where at least two drivers completed.
2. **No interference.** Nobody else logged in during the run. The load stayed at about
   1 (the benchmark itself), with brief peaks up to 1.5 at the transitions after large
   points (PostgreSQL's own background writes).
3. **Indexes matter at every threshold.** Without indexes, the driver is 9–41 times
   slower on Synthetic-Tweets at 16,000 documents and 5–17 times slower on
   Synthetic-News at 2,000 documents, and it reaches the time limit at those sizes.
4. **Summed centroids matter when clusters are large and few.** At threshold 0 (one
   cluster) the variant with means is 665 times slower at 1,000 tweets and 135 times
   slower at 250 news documents, and it reaches the limit at 2,000 tweets and 500 news
   documents; at 0.2 (50–70 clusters) and 0.4 (a few hundred clusters on tweets, up to
   about 2,600 on news) it is up to 20 times (tweets) and 11 times (news) slower. From
   0.6 up, most documents start their own cluster (at 0.6 on tweets, about half at
   64,000 documents; at 0.8 and 1, nearly all), the clusters that grow stay small, and
   the variant with means is at most 1.4 times slower.
5. **Prepared statements matter mainly for short documents.** On Synthetic-Tweets the
   variant without them is 1.8–2.2 times slower at 125 documents, up to 3.4–3.7 times at
   1,000–2,000 documents, and only 1.1–1.5 times at the largest sizes; on Synthetic-News
   it is at most 1.1 times slower. The saved parse and plan cost is fixed per
   statement, while the work of each statement grows with the size of the documents
   and of the tables.
6. **Without all three,** the driver is slower than with either single removal, but far
   from the product of their slowdowns (tweets at 0.2 and 8,000 documents: 39 times,
   against 24 times without indexes and 20 times without summed centroids); at
   threshold 0 it takes about as long as the variant without summed centroids, and from
   0.6 up about as long as the variant without indexes.
7. **The HadathSQL driver grows faster than linearly at large sizes.** Per doubling, its
   time grows about 2 times up to 1,000–4,000 documents (earliest at threshold 0), then
   3–5 times at the largest sizes (e.g. tweets at 0.2: 214 s at 32,000, 878 s at 64,000). It reached the limit at
   64,000 tweets and 16,000 news documents at threshold 0, and at 16,000 news documents
   at 0.4; at 0.6–1 it finished 16,000 news documents in about 1,645 s, close to the
   limit. `diag_growth.sh` (results in `diag_growth.csv`, 2026-10-26) traced this to two
   causes:
   - **The candidate search grows with the data.** The term index returns every
     centroid entry that shares a term with the document. With one cluster per document
     (high thresholds), the entries per document grow in step with the number of
     documents (tweets at 1: 286 at 4,000 → 1,103 at 16,000; news at 1: 3,903 at 1,000
     → 28,979 at 8,000); with few clusters whose centroids keep collecting new words,
     they also grow (news at 0.2: 2,084 → 8,088). The work per document then grows with
     the data, so the total grows about quadratically. This is inherent to exact
     single-pass clustering: every cluster that shares a term must be scored; the index
     only skips those that share none.
   - **Row versions within the pass's single transaction (Synthetic-Tweets, low
     thresholds).** Each update of a centroid entry leaves its previous version, which
     cannot be removed before the transaction ends; with few clusters, the same entries
     are updated over and over (160,000 dead versions for 2,600 live entries at 16,000
     tweets, threshold 0), and every lookup walks them: the last 200 lookups took 115 ms
     with the versions and 22 ms after VACUUM (threshold 0.2 at 32,000: 277 vs 77 ms).
     On Synthetic-News the candidate volume dominates and the versions make no
     measurable difference (8,000 documents at 0.2: 1,988 vs 2,102 ms).
   Consequence for the paper: Section 3 says the design keeps the work of each statement
   proportional to the size of the current document; it is proportional to the centroid
   entries that share a term with the document, which can grow with the data. A
   possible improvement for the version effect: run the pass as a procedure that
   commits every few thousand documents, so that old versions can be pruned.
8. **Points near the limit are fragile.** At 16,000 news documents at 0.4, the variant
   without prepared statements finished in 1,648 s while the HadathSQL driver reached
   the limit; both are within a few percent of 1,800 s, so this reflects run-to-run
   variation, not a slower driver.

## How to run (remote server)

Requirements: PostgreSQL with `psql` and `pg_isready`, bash, python3, perl, and bc.

1. Copy the repository to the server, including `evaluation/single_pass_clustering/`.
2. Create an empty database and set `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` (the
   defaults are those of the laptop's test instance: localhost, 54329, test, hadath),
   and `PSQL`/`PG_ISREADY` if the client tools are not on the `PATH`.
3. `bash setup_db.sh`: generates the ablation variants, installs HadathSQL, the CTE
   helpers, and all driver variants, and writes the machine and server configuration
   to `machine.txt` (for the setup section of the paper).
4. `nohup bash sweep.sh > sweep_ablation.log 2>&1 &` runs the ablation (`ablation.conf`,
   the default config). Do not run another sweep (e.g. the comparison of
   `COMPARISON.md`) at the same time: sweeps use the same tables and would also distort
   each other's times.
5. A sweep resumes where it stopped when rerun with the same command (points already in
   the CSV files are skipped). It checks the server before every point; if the server
   is down, or went down during a point (whose result is then discarded), it stops with
   exit code 2. Any setting of a config can be overridden from the environment
   (`METHODS`, `PREFIX`, `TIMEOUT`, ...).
6. Copy back `results_ablation_*.csv`, `machine.txt`, and the log, and run
   `python3 render_results.py` to update the results tables here.

### The server (set up 2026-10-22)

`ssh hadath-eval` (alias in `~/.ssh/config` on the laptop) logs in to
the evaluation server: Ubuntu 22.04, Intel Xeon Silver 4114 (10 cores /
20 threads), 92 GB of memory, SSD. Everything lives in `~/hadath-eval/`, built and
installed without sudo:

- `pg18/`: PostgreSQL 18.6, built from source (`--without-icu`); `tools/`: m4, bison,
  and flex, built because PostgreSQL's build requires them.
- `pgdata/`: the instance, on `localhost:54329` (user `test`, database `hadath`, locale
  C, UTF-8, `english` text search), with PostgreSQL's default settings.
- `hadath-sql/`: the repository, copied with rsync from the laptop (no pgdata or logs).
- `env.sh`: source it first (`. ~/hadath-eval/env.sh`): it puts `pg18/bin` on the
  `PATH` and sets the `PG*` variables.

The instance does not start by itself after a reboot. Start it with
`. ~/hadath-eval/env.sh && pg_ctl -D $PGDATA -o "-p 54329 -c listen_addresses=localhost -c unix_socket_directories=" -l ~/hadath-eval/pgdata.log start`.
Run sweeps inside `tmux` so they survive a disconnect.

## Datasets: Synthetic-Tweets and Synthetic-News

Both datasets are synthetic, generated by `gen_synthetic_data.sql` with a fixed seed
(0.42) for every size; the setting names in the scripts are `synthetic_tweets` and
`synthetic_news` (`tweets` and `news` in the preliminary runs).

- 50 topics; each document gets a topic uniformly at random.
- A document is a bag of words: some words drawn with replacement from its topic's own
  vocabulary, the rest drawn with replacement from a background vocabulary shared by
  all topics. Topic vocabularies are disjoint.
- Words are letter strings (`x...` for topic words, `y...` for background words),
  chosen so PostgreSQL's English text search keeps every one of them as a term.
- Timestamps are one minute apart in document order; topics are interleaved uniformly
  over time.

| Setting | Words per document | Topic vocabulary | Background vocabulary | Distinct terms per document |
|---|---|---|---|---|
| Synthetic-Tweets | 8 topic + 4 background = 12 | 12 per topic | 2,000 | about 10 (7–12; 6 topic + 4 background) |
| Synthetic-News | 200 topic + 200 background = 400 | 200 per topic | 20,000 | about 326 (311–341; 127 topic + 199 background) |

What this produces:
- Topic words are common (each in about 1/50 of the documents), so their IDF is
  moderate; background words are rare, so they get the higher TF-IDF weights. Two
  documents of the same topic are therefore only partly similar.
- Clusters can only share background words, since topic vocabularies are disjoint.
- Each document that joins a cluster brings new background words, so centroids keep
  growing toward the whole background vocabulary.
- The threshold controls the number of clusters. At 0 every document joins the most
  similar cluster even with no shared term, giving one cluster; at 1 a document joins
  only if it points in exactly the same direction as a centroid, giving about one
  cluster per document. Calibration at 1,000 documents: Synthetic-Tweets give about 63 clusters
  at 0.2 and 794 at 0.5; Synthetic-News give 50 clusters (one per topic) up to 0.2 and 62 at 0.3.

### How real data would differ

- **Word frequencies.** Real vocabularies follow a Zipf-like distribution: a few words
  are very common and most are rare. Common words that survive stop-word removal
  ("said", "new", "people") appear in almost every centroid, so a document's terms
  match many more clusters than here. That makes the similarity search (the
  dot-product join of the HadathSQL driver) more expensive than in this data.
- **Shared vocabulary between events.** Different events share words (two earthquakes
  both mention "earthquake"; two matches share team names), whereas topics here share
  none.
- **Event sizes.** Real events are heavy-tailed: a few large events and many small
  ones. Here every topic has about the same size.
- **Time.** Real events are bursty: they start, peak, and fade within a time window.
  Here every topic is active over the whole timeline.
- **Noise.** Much of a social media stream reports no event at all (chatter, ads), and
  forms many small or singleton clusters.
- **Duplicates.** Retweets and syndicated news stories produce exact or near
  duplicates, i.e. similarities of 1, which matter at threshold 1.
- **Length.** Real documents vary in length (tweets about 5–30 terms; news stories a
  few hundred to over a thousand words); here every document has the same length.
- **Text.** Real text has punctuation, numbers, misspellings, hashtags, URLs, and
  multiple languages, which change the terms that text search produces.

## Preliminary runs (laptop, 2026-10-18 to 2026-10-22)

The sections below record the runs made on the laptop while the drivers were
developed: the light run, the changes after it, and three comparisons along a sequence
of optimizations. They used the setting names `tweets` and `news` for the same
synthetic datasets, and, except where stated, unmerged drivers.

Run on: MacBook Pro 11,3 (Intel Core i7-4870HQ, 4 cores / 8 threads, 16 GB), macOS
15.7, PostgreSQL 18.6 with its default configuration, in a separate test instance
(`localhost:54329`).

**Naming (2026-10-20).** D4 is now the *HadathSQL driver*, the earlier *Indexed*
driver (D2) is now *Mean + indexed*, and D3 and D5 were dropped from the scripts and
their implementations removed. The CTEs are now the *Array CTE (non-standard)*
(formerly A) and the *Standard SQL CTE* (formerly C), the standard-SQL baseline.

**Merged statements (2026-10-20).** Every driver, including the basic one, now merges
its per-document updates into one add-document statement, as the HadathSQL driver
does: a new cluster is created empty, and every document, including the one that
seeds a cluster, is added with that statement. All results recorded before this date (the light run
and the three driver comparisons) were measured with the unmerged drivers, and the
sections recording them keep the names used at the time.

## Implementations (all drivers and CTEs)

All of them run the same algorithm and must assign every document to the same cluster:
documents in timestamp order; cosine similarity between the document's TF-IDF vector
and each centroid; join the most similar cluster if the similarity is at least the
threshold (ties go to the newest cluster), otherwise start a new cluster; a centroid
is the mean of its documents' vectors.

| ID | Implementation | File | Per-document work |
|---|---|---|---|
| Basic | Basic driver, no optimization (formerly D1) | `driver_variant_basic.sql` (`hsql_spc_basic`) | No optimization: scans the TF-IDF table for the document's vector (no index); recomputes every centroid norm over the whole centroid table; stores running-mean centroids, so it rewrites the whole chosen centroid; 5 dynamic statements per document, parsed and planned every time; no statistics refresh, default planner settings. Per-document updates merged into one add-document statement since 2026-10-20 (formerly 5 statements per document) |
| Summed | Summed driver: the basic driver with summed centroids | `driver_variant_summed.sql` (`hsql_spc_summed`) | Differs from the basic driver only in the centroid representation: stores each centroid as the sum of its documents' vectors, so adding a document adds its positive weights to the sums of its own terms (one upsert) instead of rewriting the whole centroid, and the cluster size is no longer read for the update; sums divided by cluster size once at the end; per-document updates merged into one add-document statement (2 statements per document, 3 for a new cluster). Still no indexes, all norms recomputed over the whole centroid table per document, statements re-planned every time, no planner fixes |
| Summed + indexed | Summed driver with the indexing optimization | `driver_variant_summed_indexed.sql` (`hsql_spc_sumidx`) | Differs from the summed driver only in indexing: reads the document's vector through the index on `doc_id`; an index on the centroid table's (term, cid) lets the best-cluster query score only clusters sharing a term (D4's query); the squared norm of each sum is stored and updated from the document's terms (Equation 3) instead of recomputing all norms over the whole centroid table; statistics refresh and `random_page_cost = 1.1`. Same merged statements as the summed driver (the add-document statement also adds the norm change), re-planned every time; default fill factor |
| Summed + indexed + prepared | Summed + indexed driver with prepared statements | `driver_variant_summed_indexed_prepared.sql` (`hsql_spc_sumidxp`) | Differs from the summed + indexed driver only in preparing its per-document statements once per call (`PREPARE`) and executing them by name; same merged statements; prepared statements named `hsql_spcp_*`. Differs from the HadathSQL driver only in the default fill factor of the centroid table |
| Mean + indexed | Mean + indexed driver (formerly "Indexed", D2): the basic driver without full-table scans, still with mean centroids | `driver_variant_mean_indexed.sql` (`hsql_spc_mean_indexed`) | Differs from the basic driver only in avoiding full-table scans: an index on `doc_id` of the TF-IDF table for the document's vector; an index on the centroid table's terms, so only clusters sharing a term are scored; centroid norms stored in the cluster table and recomputed for one cluster per update instead of for all clusters per document; statistics refresh and `random_page_cost = 1.1` so the planner uses the indexes. Per-document updates merged into one add-document statement, which reads the cluster size, rewrites the whole centroid as the new running mean, and stores its norm. Still running-mean centroids (whole centroid rewritten) and statements re-planned every time |
| HadathSQL | HadathSQL driver (formerly D4): the driver in HadathSQL | `single_pass_clustering/sp_clustering.sql` (`hsql_single_pass_clustering_tfidf`) | Summed centroids and index lookups as summed + indexed; prepared statements; adds the document to a summed centroid, touching only the document's own terms; squared norm updated from those terms; per-document updates merged into one add-document statement: 2 statements (3 for a new cluster); sums divided by cluster size once at the end; fill factor 80 on the centroid table |
| HadathSQL without indexes | HadathSQL driver without the index on the TF-IDF table's `doc_id` and the centroid table's term index (primary keys kept) | `driver_variant_hadathsql_no_index.sql` (`hsql_spc_hadathsql_noidx`) | As the HadathSQL driver, but reads the unindexed TF-IDF copy and scores clusters without the term index, so each document scans both tables |
| HadathSQL without summed centroids | HadathSQL driver with running-mean centroids | `driver_variant_hadathsql_mean.sql` (`hsql_spc_hadathsql_mean`) | As the HadathSQL driver, but adding a document rewrites the whole centroid as the new mean and recomputes its norm from it; no final division |
| HadathSQL without prepared statements | HadathSQL driver with dynamic statements | `driver_variant_hadathsql_no_prepared.sql` (`hsql_spc_hadathsql_noprep`) | As the HadathSQL driver, but every per-document statement is parsed and planned at each execution |
| Array CTE | Array CTE (non-standard; formerly A): recursive CTE, cluster set in one array | `prep_cte_array.sql`, `run_cte_array.sql`, helpers in `setup_cte.sql` | Computes the similarity to every cluster and rebuilds the whole array, in memory; keeps every iteration's state |
| Standard SQL CTE | Standard SQL CTE (formerly C), the standard-SQL baseline: recursive CTE, clusters as rows, standard SQL only | `prep_cte_standard.sql`, `run_cte_standard.sql` | Passes the whole state through six layers of window functions (several sorts) and re-emits it; keeps every iteration's state |

## What was measured in the preliminary runs

- **Clustering time only.** The TF-IDF table is built once per dataset by
  `hsql_create_tf_idf_tbl`, indexed on `doc_id`, and timed separately (column
  TF-IDF); it is not added to any method.
- The basic driver reads an unindexed copy of the TF-IDF table, since it uses no
  index on `doc_id`; all other drivers read the indexed table.
- Driver time: the whole clustering call (output tables, ordering of the documents,
  the loop, and for drivers with summed centroids the final division by cluster size).
- CTE time: the CTE's input preparation (document numbering; arrays for A, term rows
  for C) plus the query.
- Wall-clock time measured by the client; the number of runs per point and the time
  limit are set per experiment (`REPS`, `REP_MAX`, `TIMEOUT`). The limit is a
  `statement_timeout`, so it applies to each statement: a driver call is one statement,
  while a CTE's input preparation and query are limited separately. Within a (setting, threshold) series, a method that hits
  the limit is not run at larger sizes.
- Correctness: after each point, the number of documents whose cluster differs from
  the reference driver's (the HadathSQL driver if it ran, otherwise the first baseline in
  the run), summed over the methods that completed (column mismatches; expected 0).

## Changes after the light run (2026-10-18)

The light-run results below were measured **before** these changes; the times of the indexed driver, D3, and D4
there are therefore pessimistic at the larger sizes, and the two outliers are invalid.

1. **Time-limit outliers were caused by the Mac sleeping.** PostgreSQL's
   `statement_timeout` does stop the drivers (checked with a 5 s limit), but during a
   sleep both the server and its timer pause while the wall clock keeps running. The
   sweep overlapped several sleeps (including 11:00–15:41 with the lid closed), which
   explains D3 = 583 s and the indexed driver = 1,115 s. `sweep.sh` now runs under `caffeinate`, and
   `run_point.sh` checks `pmset -g log` for a sleep during each run, reports `SLEPT`,
   and the sweep measures such a point again.
2. **Jumps between 800 and 1,000 news documents were a planner problem.** With
   `auto_explain`, q2 (the best-cluster query) of D4 scanned the whole centroid table
   (about 300,000 rows) for every document instead of using the term index:
   - the statistics of the output tables described them as they were early in the
     run (1,440 rows estimated, 307,679 actual), and the prepared statement kept that
     plan;
   - even with current statistics, the default `random_page_cost` (4.0) made the
     planner prefer the full scan: on the final tables q2 took 64–67 ms with the scan
     and 9–11 ms with index lookups.
   D4 (and, for a fair ablation, the indexed driver and D3) now refreshes the statistics of its output
   tables with `ANALYZE` after 16, 32, 64, ... documents and runs with
   `random_page_cost = 1.1` (a function-level setting). The basic driver is unchanged.
   Effect on D4, news, threshold 0.5: 800 documents 13.0 → 7.0 s; 1,000 documents
   26.8 → 9.9 s; still 0 mismatches.
3. **D4's final division skips single-document clusters** (`doc_count > 1`); dividing
   a sum over one document by 1 changes nothing. At high thresholds almost every
   cluster is a singleton, and this step took 7.7 s of D4's 38.6 s at 1,000 news
   documents before the change.

### Check after the changes (`verify_fixes.csv`)

Same points as the light run, the indexed driver, D3, and D4 only, Mac kept awake; seconds of clustering
(light-run value in parentheses). All runs: 0 mismatches.

| setting, threshold, docs | clusters | Indexed | D3 | D4 |
|---|---:|---:|---:|---:|
| tweets, 0, 600 | 1 | 237.4 (183.2) | 190.5 (583.4, slept) | 0.65 (0.81) |
| tweets, 0.5, 1,000 | 818 | 1.52 (1.27) | 0.67 (0.65) | 0.67 (0.78) |
| news, 0.2, 1,000 | 50 | 88.3 (106.9) | 92.1 (108.3) | 15.4 (23.1) |
| news, 0.5, 1,000 | 1,000 | 8.8 (25.4) | 8.7 (20.4) | 10.0 (31.1) |

## Summed + indexed vs summed + indexed + prepared driver

Third step of the optimization sequence: summed + indexed is the baseline, and the
new driver adds only prepared statements.

| | Summed + indexed (baseline) | Summed + indexed + prepared |
|---|---|---|
| Per-document statements | executed as dynamic SQL (`EXECUTE ... USING`): parsed and planned at every execution | prepared once per call (`PREPARE`) and executed by name: parsed once; after a few executions a cached generic plan can be reused |
| Unchanged | the same statements and the same number per document (joining: best cluster, increment size and norm, add weights, record assignment; new cluster: best cluster, create cluster with norm, seed centroid, record assignment); summed centroids; indexes; stored squared norms; statistics refresh (which also makes prepared statements re-plan); `random_page_cost = 1.1`; default fill factor | |

The remaining differences to the HadathSQL driver are statement merging (one
add-document statement) and its fill factor of 80. Same data, thresholds, sizes, time limit, and
repetitions as before; the correctness reference is summed + indexed.
Command: `METHODS=sumidx,sumidxp PREFIX=results_sumidx_prepared_ bash sweep.sh small_evaluation.conf`
(originally `sweep_drivers.sh`, since replaced).

### Observations: summed + indexed vs + prepared (run completed 2026-10-19)

1. **Correctness.** Same clusters as the summed + indexed driver at all 50 points
   (0 mismatches).
2. **Tweets: prepared statements roughly halve the time.** 1.4–1.5× at 200 documents
   and 1.8–2.35× from 400 documents on, at every threshold (e.g. 1,000 documents at
   threshold 1: 1.33 → 0.57 s; at 0.2: 2.01 → 0.89 s).
3. **News: a small gain.** 1.00–1.15×, mostly 1.03–1.12× (e.g. 1,000 documents at
   0.5: 8.1 → 7.4 s; at 0: 18.6 → 18.1 s).
4. **Why the difference.** The saving is roughly a fixed amount per document, the cost
   of parsing and planning four statements: about 0.6–1.1 ms per document on tweets,
   and 0.1–0.7 ms on news (noisier there, as a small difference between large times). With 12-term tweets this overhead is about half of
   the work per document; with about 326-term news documents the data work dominates,
   so the same saving is a small fraction.

## Summed vs summed + indexed driver

Second step of the optimization sequence: the summed driver is now the baseline, and
the summed + indexed driver adds only the indexing optimization.

| | Summed (baseline) | Summed + indexed |
|---|---|---|
| Reading the document's vector | scans the TF-IDF table (unindexed copy) | index lookup on `doc_id` |
| Candidate clusters in the best-cluster query | joins the document with the whole centroid table | term index on (term, cid): only clusters sharing a term, plus the newest cluster (for ties at similarity 0) |
| Centroid norms | recomputed for all clusters over the whole centroid table, for every document | squared norm of each sum stored in the cluster table, updated from the document's terms when it joins (Equation 3), and set from the seed document for a new cluster |
| Planner | default settings, no statistics refresh | statistics refresh at 16, 32, 64, ... documents; `random_page_cost = 1.1` |
| Unchanged | summed centroids; statements per document (best cluster; increment size; add weights; record assignment); dynamic statements planned at every execution; default fill factor | |

Same data, thresholds, sizes, time limit, and repetitions as before; the correctness
reference is the summed driver.
Command: `METHODS=sum,sumidx PREFIX=results_summed_indexed_ bash sweep.sh small_evaluation.conf`
(originally `sweep_drivers.sh`, since replaced).

### Observations: summed vs summed + indexed (run completed 2026-10-19)

1. **Correctness.** The summed + indexed driver assigned every document to the same
   cluster as the summed driver at all 50 points (0 mismatches).
2. **News: indexing is a large win, and the gain grows with the data.** At 1,000
   documents: 9.9× with one cluster per document (threshold 0.5: 77.3 → 7.8 s; 0.7 and
   1 alike), 4.8× with 50 clusters (0.2: 80.6 → 16.6 s), and 3.8× with one cluster
   (0: 72.7 → 19.4 s). At 200 documents the gains are 1.5–2.6×.
3. **Tweets: smaller gains, and a small loss on the smallest tables.** At 1,000
   documents: 2.4–2.6× at thresholds 0.5–1, 1.5× at 0.2, and 1.8× at 0. At 200
   documents the indexed driver is up to about 20% slower at thresholds 0 and 0.2
   (e.g. 0.44 → 0.54 s): with 12 terms per document and small tables, the scans it
   replaces are cheap, and maintaining the index and refreshing statistics cost more.
4. **Scaling.** The summed driver grows roughly quadratically (news, thresholds 0.5–1:
   4.2 → 77 s for 5× the documents, about 18×), because it scans the TF-IDF table and
   recomputes every centroid norm for each document. The summed + indexed driver grows
   close to linearly with many clusters (1.6 → 7.8 s, about 4.8×) and moderately
   faster than linearly with one large cluster (news at 0: 3.1 → 19.4 s, about 6.3×).
5. **Where the index helps most.** The gain is largest with many clusters and long
   documents: the summed driver's cost per document grows with the whole centroid
   table, whereas the indexed driver touches only the centroid entries of the
   document's terms, which belong to few clusters.

## Basic vs summed driver

The basic driver is the baseline; every optimized driver is compared with it, one
optimization at a time. This experiment covers the first one, summed centroids.

The two drivers differ only in how a centroid is stored and updated:

| | Basic | Summed |
|---|---|---|
| Centroid during the pass | running mean of the documents' vectors | sum of the documents' vectors |
| Adding a document to a cluster | reads the cluster size; recomputes every entry of the centroid with a full outer join of the centroid and the document; upserts all entries; deletes zero entries | upserts only the document's positive weights, adding each to the sum of its term |
| Statements when a document joins a cluster | 5: best cluster, read size, update centroid, increment size, record assignment | 4: best cluster, update centroid, increment size, record assignment |
| Seeding a new cluster | copies all of the document's weights | copies the positive weights |
| After the pass | nothing | divides each sum by its cluster size (clusters with more than one document) |
| Everything else | identical: no indexes (unindexed copy of the TF-IDF table); every document recomputes all centroid norms over the whole centroid table; statements parsed and planned at every execution; no statistics refresh; default planner settings | |

Cosine similarity does not depend on the length of a vector, so both find the same
clusters. Same data, thresholds, sizes, time limit, and repetitions as the driver
experiment; the correctness reference is the basic driver.
Command: `METHODS=d1,sum PREFIX=results_basic_summed_ bash sweep.sh small_evaluation.conf`
(originally `sweep_drivers.sh`, since replaced).

### Observations: basic vs summed (run completed 2026-10-18)

1. **Correctness.** Wherever both drivers completed, the summed driver assigned every
   document to the same cluster as the basic driver (0 mismatches). Where the basic
   driver hit the limit there is no reference; the summed driver was checked against
   D4 at threshold 0 separately.
2. **Large clusters: summed centroids are much faster, and the gap grows with the
   data.** Threshold 0 (one cluster), tweets: 24× at 200 documents (10.1 vs 0.42 s),
   65× at 400, 108× at 600 (164.8 vs 1.53 s); the basic driver hits the limit from 800
   documents, while the summed driver needs 2.9 s for 1,000. News at threshold 0: the
   basic driver hits the limit already at 200 documents, the summed driver takes 4.7 s.
   With about 50–68 clusters (threshold 0.2): 1.4× for 1,000 tweets (4.42 vs 3.06 s)
   and 1.9× for 1,000 news documents (123.8 vs 66.8 s).
3. **Many small clusters (threshold 0.5 and above): no meaningful difference.** With
   about one document per cluster there is no large centroid to rewrite; the two
   drivers stay within a few percent of each other in either direction (e.g. news,
   1,000 documents: 67.5 vs 71.0 s at 0.5, 74.0 vs 70.1 s at 1), within run-to-run
   variation.
4. **Both still grow roughly quadratically.** Even with singleton clusters, 5× the
   documents costs about 8× the time (tweets at 1: 0.41 → 3.4 s; news: 3.9 → 74 s),
   because both drivers scan the TF-IDF table and recompute all centroid norms over
   the whole centroid table for every document. Summed centroids do not address this;
   the indexed driver does, which makes it the next comparison against the basic
   driver.

## Parameters of the preliminary runs

Light run and driver comparisons (`small_evaluation.conf`):

- Settings: tweets, news.
- Thresholds: 0, 0.2, 0.5, 0.7, 1.
- Documents: 200 to 1,000 in steps of 200.
- Time limit: 5 minutes per run.

If the number of clusters matters later, a threshold could be chosen per setting to
reach a target number of clusters relative to the number of documents (for example
about the number of topics, 10% of the documents, and 50% of the documents), since the
same threshold gives very different cluster counts in the two settings.

## Results

Generated from the CSV files by `render_results.py` after every point. "> limit": the
run hit the time limit; "–": not run (the method had already hit the limit at a
smaller size). Times are seconds of clustering.

<!-- RESULTS:BEGIN -->
### Ablation of the HadathSQL driver

Settings in ablation.conf. The HadathSQL driver and its ablation variants (each without one optimization). Median of up to 3 runs per point (single run when a run takes 60 s or more).

#### Synthetic-Tweets

**Threshold 0**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 1 | 0.10 | 0.17 | 0.26 | 5.10 | 0.33 | 4.87 | 0 | 0.16 / 0.53 |
| 250 | 1 | 0.15 | 0.31 | 0.65 | 27.05 | 0.63 | 25.94 | 0 | 0.53 / 0.99 |
| 500 | 1 | 0.27 | 0.61 | 2.00 | 180.31 | 1.26 | 144.83 | 0 | 0.99 / 1.01 |
| 1000 | 1 | 0.50 | 1.56 | 6.33 | 1035.77 | 2.89 | 1025.36 | 0 | 1.01 / 1.00 |
| 2000 | 1 | 0.98 | 4.34 | 23.29 | > limit | 6.95 | > limit | 0 | 1.00 / 1.00 |
| 4000 | 1 | 1.91 | 12.95 | 89.23 | – | 18.56 | – | 0 | 1.00 / 1.00 |
| 8000 | 1 | 3.71 | 44.37 | 349.36 | – | 56.18 | – | 0 | 1.00 / 1.00 |
| 16000 | 1 | 7.43 | 162.41 | 1383.91 | – | 188.73 | – | 0 | 1.00 / 1.00 |
| 32000 | 1 | 14.70 | 620.08 | > limit | – | 684.25 | – | 0 | 1.00 / 1.00 |
| 64000 | NA | 29.32 | > limit | – | – | > limit | – | NA | 1.00 / 1.02 |

**Threshold 0.2**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 55 | 0.10 | 0.19 | 0.28 | 0.20 | 0.36 | 0.44 | 0 | 1.02 / 1.01 |
| 250 | 63 | 0.15 | 0.30 | 0.69 | 0.46 | 0.78 | 1.27 | 0 | 1.01 / 1.01 |
| 500 | 67 | 0.27 | 0.54 | 2.12 | 1.01 | 1.72 | 3.64 | 0 | 1.01 / 1.07 |
| 1000 | 68 | 0.50 | 1.06 | 8.61 | 2.86 | 3.59 | 12.21 | 0 | 1.07 / 1.01 |
| 2000 | 66 | 0.97 | 2.27 | 30.61 | 10.71 | 7.52 | 37.18 | 0 | 1.01 / 1.00 |
| 4000 | 69 | 1.91 | 5.29 | 93.59 | 47.98 | 15.96 | 131.72 | 0 | 1.00 / 1.00 |
| 8000 | 70 | 3.71 | 14.19 | 345.14 | 276.82 | 35.73 | 548.78 | 0 | 1.00 / 1.00 |
| 16000 | 70 | 7.42 | 42.13 | 1306.41 | > limit | 91.88 | > limit | 0 | 1.00 / 1.01 |
| 32000 | 70 | 14.70 | 214.12 | > limit | – | 306.48 | – | 0 | 1.01 / 1.00 |
| 64000 | 70 | 29.29 | 878.13 | – | – | 1094.03 | – | 0 | 1.00 / 1.00 |

**Threshold 0.4**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 108 | 0.11 | 0.18 | 0.28 | 0.18 | 0.39 | 0.45 | 0 | 1.00 / 1.00 |
| 250 | 172 | 0.15 | 0.28 | 0.69 | 0.29 | 0.82 | 1.16 | 0 | 1.00 / 1.00 |
| 500 | 255 | 0.27 | 0.54 | 2.19 | 0.57 | 1.74 | 3.23 | 0 | 1.00 / 1.00 |
| 1000 | 309 | 0.51 | 1.05 | 9.51 | 1.29 | 3.72 | 12.35 | 0 | 1.00 / 1.00 |
| 2000 | 343 | 0.98 | 2.20 | 34.79 | 3.67 | 7.83 | 44.07 | 0 | 1.00 / 1.00 |
| 4000 | 361 | 1.91 | 5.19 | 96.14 | 12.68 | 16.45 | 118.20 | 0 | 1.00 / 1.00 |
| 8000 | 364 | 3.71 | 12.75 | 370.87 | 49.17 | 34.74 | 439.71 | 0 | 1.00 / 1.05 |
| 16000 | 363 | 7.43 | 35.20 | 1452.23 | 219.28 | 79.93 | 1568.77 | 0 | 1.05 / 1.00 |
| 32000 | 375 | 14.93 | 107.93 | > limit | 1303.67 | 193.96 | > limit | 0 | 1.00 / 1.25 |
| 64000 | 375 | 29.29 | 356.58 | – | > limit | 530.15 | – | 0 | 1.25 / 1.01 |

**Threshold 0.6**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 125 | 0.10 | 0.17 | 0.27 | 0.18 | 0.38 | 0.45 | 0 | 1.01 / 1.01 |
| 250 | 249 | 0.15 | 0.26 | 0.67 | 0.27 | 0.81 | 1.15 | 0 | 1.01 / 1.01 |
| 500 | 497 | 0.27 | 0.45 | 2.15 | 0.45 | 1.61 | 3.11 | 0 | 1.01 / 1.00 |
| 1000 | 993 | 0.51 | 0.88 | 10.28 | 0.96 | 3.27 | 11.78 | 0 | 1.00 / 1.00 |
| 2000 | 1962 | 0.98 | 1.92 | 39.14 | 1.90 | 6.86 | 41.85 | 0 | 1.00 / 1.00 |
| 4000 | 3857 | 1.91 | 6.28 | 109.96 | 6.31 | 15.67 | 106.25 | 0 | 1.00 / 1.00 |
| 8000 | 7448 | 3.71 | 19.48 | 412.96 | 19.51 | 35.41 | 401.37 | 0 | 1.00 / 1.00 |
| 16000 | 13753 | 7.43 | 46.76 | 1606.49 | 47.52 | 84.40 | 1558.91 | 0 | 1.00 / 1.00 |
| 32000 | 22550 | 14.70 | 131.51 | > limit | 147.44 | 221.47 | > limit | 0 | 1.00 / 1.51 |
| 64000 | 30896 | 29.28 | 465.92 | – | 637.85 | 643.74 | – | 0 | 1.51 / 1.02 |

**Threshold 0.8**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 125 | 0.11 | 0.17 | 0.26 | 0.17 | 0.38 | 0.45 | 0 | 1.02 / 1.02 |
| 250 | 250 | 0.15 | 0.27 | 0.68 | 0.27 | 0.81 | 1.15 | 0 | 1.02 / 1.01 |
| 500 | 500 | 0.27 | 0.45 | 2.10 | 0.45 | 1.61 | 2.92 | 0 | 1.01 / 1.01 |
| 1000 | 1000 | 0.51 | 0.88 | 11.05 | 0.97 | 3.26 | 11.77 | 0 | 1.01 / 1.05 |
| 2000 | 2000 | 0.98 | 1.90 | 39.54 | 1.88 | 6.87 | 42.09 | 0 | 1.05 / 1.00 |
| 4000 | 4000 | 1.91 | 6.28 | 107.16 | 6.29 | 15.55 | 106.01 | 0 | 1.00 / 1.00 |
| 8000 | 8000 | 3.71 | 19.70 | 413.17 | 19.72 | 36.10 | 400.48 | 0 | 1.00 / 1.00 |
| 16000 | 16000 | 7.43 | 45.15 | 1619.68 | 45.19 | 85.59 | 1555.95 | 0 | 1.00 / 1.00 |
| 32000 | 32000 | 14.70 | 146.01 | > limit | 145.22 | 224.07 | > limit | 0 | 1.00 / 1.14 |
| 64000 | 63999 | 29.27 | 532.83 | – | 530.02 | 695.42 | – | 0 | 1.14 / 1.09 |

**Threshold 1**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 125 | 0.11 | 0.17 | 0.27 | 0.18 | 0.38 | 0.45 | 0 | 1.09 / 1.09 |
| 250 | 250 | 0.15 | 0.27 | 0.68 | 0.27 | 0.80 | 1.15 | 0 | 1.09 / 1.07 |
| 500 | 500 | 0.27 | 0.45 | 2.15 | 0.46 | 1.62 | 3.10 | 0 | 1.07 / 1.05 |
| 1000 | 1000 | 0.51 | 0.88 | 10.35 | 0.97 | 3.26 | 11.79 | 0 | 1.05 / 1.01 |
| 2000 | 2000 | 0.98 | 1.90 | 39.34 | 1.87 | 6.84 | 41.97 | 0 | 1.01 / 1.00 |
| 4000 | 4000 | 1.91 | 6.27 | 105.01 | 6.32 | 15.65 | 105.94 | 0 | 1.00 / 1.00 |
| 8000 | 8000 | 3.72 | 19.70 | 413.06 | 19.73 | 35.82 | 402.46 | 0 | 1.00 / 1.00 |
| 16000 | 16000 | 7.43 | 44.99 | 1613.23 | 45.06 | 85.65 | 1552.72 | 0 | 1.00 / 1.00 |
| 32000 | 32000 | 14.70 | 139.75 | > limit | 144.99 | 226.39 | > limit | 0 | 1.00 / 1.25 |
| 64000 | 64000 | 29.28 | 531.36 | – | 531.40 | 693.91 | – | 0 | 1.23 / 1.07 |

#### Synthetic-News

**Threshold 0**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 1 | 1.95 | 2.92 | 5.52 | 168.51 | 3.02 | 152.14 | 0 | 1.07 / 1.00 |
| 250 | 1 | 3.76 | 6.01 | 15.40 | 808.37 | 6.27 | 747.31 | 0 | 1.00 / 1.12 |
| 500 | 1 | 7.52 | 13.37 | 52.37 | > limit | 13.76 | > limit | 0 | 1.12 / 1.00 |
| 1000 | 1 | 14.67 | 36.39 | 159.31 | – | 36.73 | – | 0 | 1.00 / 1.09 |
| 2000 | 1 | 29.34 | 108.11 | 565.61 | – | 108.82 | – | 0 | 1.09 / 1.16 |
| 4000 | 1 | 58.44 | 352.66 | > limit | – | 353.81 | – | 0 | 1.16 / 1.00 |
| 8000 | 1 | 117.31 | 1254.07 | – | – | 1258.71 | – | 0 | 1.00 / 1.01 |
| 16000 | NA | 236.79 | > limit | – | – | > limit | – | NA | 1.01 / 1.06 |

**Threshold 0.2**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 46 | 1.99 | 3.60 | 6.44 | 4.01 | 3.73 | 6.58 | 0 | 1.06 / 1.02 |
| 250 | 50 | 3.75 | 6.23 | 16.71 | 13.10 | 6.48 | 24.59 | 0 | 1.02 / 1.01 |
| 500 | 50 | 7.40 | 12.57 | 68.66 | 35.68 | 13.05 | 90.80 | 0 | 1.01 / 1.06 |
| 1000 | 50 | 14.68 | 26.76 | 172.66 | 129.48 | 27.12 | 274.67 | 0 | 1.06 / 1.25 |
| 2000 | 50 | 29.62 | 60.40 | 605.84 | 691.46 | 60.80 | 1150.47 | 0 | 1.25 / 1.14 |
| 4000 | 50 | 58.48 | 146.98 | > limit | > limit | 147.06 | > limit | 0 | 1.14 / 1.31 |
| 8000 | 50 | 117.25 | 411.03 | – | – | 412.69 | – | 0 | 1.31 / 1.04 |
| 16000 | 50 | 235.27 | 1610.56 | – | – | 1620.53 | – | 0 | 1.04 / 1.04 |

**Threshold 0.4**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 125 | 2.00 | 2.49 | 5.58 | 2.51 | 2.65 | 5.27 | 0 | 1.04 / 1.01 |
| 250 | 250 | 3.76 | 4.25 | 16.98 | 4.28 | 4.48 | 15.51 | 0 | 1.01 / 1.00 |
| 500 | 494 | 7.39 | 8.56 | 134.50 | 8.34 | 9.01 | 123.83 | 0 | 1.00 / 1.01 |
| 1000 | 973 | 14.67 | 17.35 | 181.98 | 18.90 | 17.72 | 178.30 | 0 | 1.01 / 1.12 |
| 2000 | 1720 | 29.34 | 43.41 | 662.22 | 75.59 | 44.15 | 680.91 | 0 | 1.12 / 1.16 |
| 4000 | 2498 | 58.60 | 127.39 | > limit | 811.18 | 126.68 | > limit | 0 | 1.16 / 1.47 |
| 8000 | 2655 | 117.19 | 437.34 | – | > limit | 403.75 | – | 0 | 1.47 / 1.01 |
| 16000 | 2556 | 235.95 | > limit | – | – | 1648.36 | – | 0 | 1.01 / 1.00 |

**Threshold 0.6**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 125 | 1.99 | 2.48 | 5.58 | 2.52 | 2.66 | 5.26 | 0 | 1.00 / 1.00 |
| 250 | 250 | 3.76 | 4.26 | 15.73 | 4.28 | 4.50 | 15.47 | 0 | 1.00 / 1.00 |
| 500 | 500 | 7.40 | 8.50 | 133.66 | 8.22 | 8.96 | 124.86 | 0 | 1.00 / 1.00 |
| 1000 | 1000 | 14.68 | 17.02 | 182.06 | 17.24 | 17.41 | 176.84 | 0 | 1.00 / 1.35 |
| 2000 | 2000 | 29.34 | 40.12 | 665.11 | 40.45 | 40.97 | 643.12 | 0 | 1.35 / 1.11 |
| 4000 | 4000 | 58.47 | 107.98 | > limit | 107.31 | 108.94 | > limit | 0 | 1.11 / 1.20 |
| 8000 | 8000 | 117.20 | 345.39 | – | 346.12 | 349.82 | – | 0 | 1.20 / 1.09 |
| 16000 | 16000 | 235.89 | 1648.89 | – | 1643.18 | 1651.01 | – | 0 | 1.09 / 1.02 |

**Threshold 0.8**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 125 | 1.99 | 2.48 | 5.59 | 2.52 | 2.65 | 5.26 | 0 | 1.02 / 1.15 |
| 250 | 250 | 3.76 | 4.28 | 15.62 | 4.29 | 4.53 | 15.46 | 0 | 1.15 / 1.01 |
| 500 | 500 | 7.40 | 8.47 | 127.18 | 8.22 | 8.93 | 124.70 | 0 | 1.01 / 1.00 |
| 1000 | 1000 | 14.68 | 17.01 | 182.15 | 17.25 | 17.40 | 176.92 | 0 | 1.00 / 1.24 |
| 2000 | 2000 | 29.34 | 40.12 | 665.53 | 40.43 | 40.98 | 641.25 | 0 | 1.24 / 1.09 |
| 4000 | 4000 | 58.48 | 106.20 | > limit | 107.06 | 108.53 | > limit | 0 | 1.09 / 1.23 |
| 8000 | 8000 | 117.25 | 346.10 | – | 345.35 | 348.78 | – | 0 | 1.23 / 1.11 |
| 16000 | 16000 | 236.27 | 1641.77 | – | 1639.76 | 1655.00 | – | 0 | 1.11 / 1.03 |

**Threshold 1**

| docs | clusters | TF-IDF | HadathSQL | without indexes | without summed centroids | without prepared statements | without all three | mismatches | load (start / end) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 125 | 125 | 1.99 | 2.48 | 5.58 | 2.51 | 2.66 | 5.26 | 0 | 1.03 / 1.01 |
| 250 | 250 | 3.76 | 4.26 | 15.85 | 4.27 | 4.49 | 15.51 | 0 | 1.01 / 1.03 |
| 500 | 500 | 7.40 | 8.48 | 134.28 | 8.21 | 8.94 | 123.62 | 0 | 1.03 / 1.00 |
| 1000 | 1000 | 14.67 | 17.04 | 181.99 | 17.23 | 17.41 | 176.53 | 0 | 1.00 / 1.17 |
| 2000 | 2000 | 29.32 | 40.00 | 665.24 | 40.48 | 40.98 | 640.70 | 0 | 1.17 / 1.04 |
| 4000 | 4000 | 58.58 | 106.09 | > limit | 107.12 | 108.76 | > limit | 0 | 1.04 / 1.13 |
| 8000 | 8000 | 117.22 | 343.81 | – | 344.65 | 348.61 | – | 0 | 1.13 / 1.00 |
| 16000 | 16000 | 236.19 | 1646.39 | – | 1642.36 | 1655.42 | – | 0 | 1.00 / 1.00 |

### Preliminary: summed + indexed vs summed + indexed + prepared

Median of up to 3 runs per point (single run when a run takes 60 s or more).

#### Tweets (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 1 | 0.20 | 0.45 | 0.31 | 0 |
| 400 | 1 | 0.24 | 0.79 | 0.44 | 0 |
| 600 | 1 | 0.30 | 1.09 | 0.59 | 0 |
| 800 | 1 | 0.33 | 1.39 | 0.77 | 0 |
| 1000 | 1 | 0.36 | 1.69 | 0.92 | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 61 | 0.21 | 0.47 | 0.31 | 0 |
| 400 | 66 | 0.33 | 0.84 | 0.42 | 0 |
| 600 | 67 | 0.37 | 1.21 | 0.61 | 0 |
| 800 | 67 | 0.32 | 1.57 | 0.67 | 0 |
| 1000 | 68 | 0.38 | 2.01 | 0.89 | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 191 | 0.21 | 0.39 | 0.28 | 0 |
| 400 | 365 | 0.24 | 0.72 | 0.36 | 0 |
| 600 | 521 | 0.28 | 0.98 | 0.46 | 0 |
| 800 | 677 | 0.33 | 1.25 | 0.55 | 0 |
| 1000 | 818 | 0.36 | 1.47 | 0.71 | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.20 | 0.41 | 0.27 | 0 |
| 400 | 400 | 0.24 | 0.60 | 0.34 | 0 |
| 600 | 600 | 0.29 | 0.84 | 0.42 | 0 |
| 800 | 800 | 0.33 | 1.06 | 0.51 | 0 |
| 1000 | 1000 | 0.39 | 1.37 | 0.73 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.22 | 0.39 | 0.26 | 0 |
| 400 | 400 | 0.26 | 0.61 | 0.35 | 0 |
| 600 | 600 | 0.28 | 0.88 | 0.41 | 0 |
| 800 | 800 | 0.44 | 1.13 | 0.52 | 0 |
| 1000 | 1000 | 0.37 | 1.33 | 0.57 | 0 |

#### News (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 1 | 1.45 | 3.17 | 2.85 | 0 |
| 400 | 1 | 2.78 | 5.81 | 5.59 | 0 |
| 600 | 1 | 4.02 | 9.57 | 9.03 | 0 |
| 800 | 1 | 5.34 | 13.75 | 13.14 | 0 |
| 1000 | 1 | 6.55 | 18.58 | 18.14 | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 49 | 1.53 | 3.37 | 3.36 | 0 |
| 400 | 50 | 2.75 | 6.18 | 5.97 | 0 |
| 600 | 50 | 3.90 | 9.43 | 9.08 | 0 |
| 800 | 50 | 5.41 | 12.69 | 12.13 | 0 |
| 1000 | 50 | 6.69 | 16.19 | 15.79 | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.62 | 1.63 | 1.50 | 0 |
| 400 | 400 | 2.74 | 3.10 | 2.80 | 0 |
| 600 | 600 | 3.90 | 4.61 | 4.16 | 0 |
| 800 | 800 | 5.28 | 6.48 | 5.80 | 0 |
| 1000 | 1000 | 6.47 | 8.12 | 7.43 | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.53 | 1.57 | 1.43 | 0 |
| 400 | 400 | 2.71 | 2.95 | 3.02 | 0 |
| 600 | 600 | 5.00 | 4.81 | 4.26 | 0 |
| 800 | 800 | 5.29 | 6.54 | 5.68 | 0 |
| 1000 | 1000 | 6.32 | 7.76 | 7.63 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Summed + indexed | Summed + indexed + prepared | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.44 | 1.61 | 1.48 | 0 |
| 400 | 400 | 2.69 | 3.08 | 2.69 | 0 |
| 600 | 600 | 3.90 | 4.52 | 4.20 | 0 |
| 800 | 800 | 5.14 | 6.19 | 5.65 | 0 |
| 1000 | 1000 | 6.47 | 7.44 | 7.32 | 0 |

### Preliminary: summed vs summed + indexed driver

Median of up to 3 runs per point (single run when a run takes 60 s or more).

#### Tweets (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 1 | 0.21 | 0.44 | 0.54 | 0 |
| 400 | 1 | 0.41 | 0.94 | 0.70 | 0 |
| 600 | 1 | 0.43 | 1.41 | 1.06 | 0 |
| 800 | 1 | 0.34 | 2.19 | 1.29 | 0 |
| 1000 | 1 | 0.35 | 2.94 | 1.63 | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 61 | 0.19 | 0.42 | 0.49 | 0 |
| 400 | 66 | 0.26 | 0.85 | 0.82 | 0 |
| 600 | 67 | 0.28 | 1.40 | 1.19 | 0 |
| 800 | 67 | 0.31 | 2.09 | 1.61 | 0 |
| 1000 | 68 | 0.35 | 3.01 | 2.02 | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 191 | 0.21 | 0.39 | 0.39 | 0 |
| 400 | 365 | 0.23 | 0.83 | 0.69 | 0 |
| 600 | 521 | 0.30 | 1.48 | 1.04 | 0 |
| 800 | 677 | 0.33 | 2.81 | 1.41 | 0 |
| 1000 | 818 | 0.39 | 3.69 | 1.48 | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.25 | 0.42 | 0.48 | 0 |
| 400 | 400 | 0.24 | 0.87 | 0.63 | 0 |
| 600 | 600 | 0.28 | 1.62 | 0.86 | 0 |
| 800 | 800 | 0.41 | 2.55 | 1.29 | 0 |
| 1000 | 1000 | 0.40 | 3.72 | 1.43 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.21 | 0.44 | 0.39 | 0 |
| 400 | 400 | 0.28 | 0.88 | 0.62 | 0 |
| 600 | 600 | 0.28 | 1.57 | 0.86 | 0 |
| 800 | 800 | 0.32 | 2.49 | 1.09 | 0 |
| 1000 | 1000 | 0.36 | 3.61 | 1.38 | 0 |

#### News (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 1 | 1.43 | 4.87 | 3.06 | 0 |
| 400 | 1 | 2.72 | 13.91 | 5.90 | 0 |
| 600 | 1 | 4.11 | 26.62 | 9.82 | 0 |
| 800 | 1 | 5.45 | 49.04 | 14.72 | 0 |
| 1000 | 1 | 6.95 | 72.74 | 19.39 | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 49 | 1.66 | 5.55 | 3.60 | 0 |
| 400 | 50 | 3.17 | 17.24 | 6.62 | 0 |
| 600 | 50 | 4.24 | 32.77 | 10.12 | 0 |
| 800 | 50 | 5.44 | 50.38 | 13.10 | 0 |
| 1000 | 50 | 6.71 | 80.62 | 16.63 | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.59 | 4.24 | 1.66 | 0 |
| 400 | 400 | 2.73 | 15.36 | 3.17 | 0 |
| 600 | 600 | 5.17 | 31.26 | 4.78 | 0 |
| 800 | 800 | 5.26 | 49.65 | 6.38 | 0 |
| 1000 | 1000 | 6.72 | 77.33 | 7.82 | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.47 | 4.21 | 1.61 | 0 |
| 400 | 400 | 2.83 | 14.83 | 3.12 | 0 |
| 600 | 600 | 4.12 | 31.54 | 4.73 | 0 |
| 800 | 800 | 5.32 | 50.57 | 7.20 | 0 |
| 1000 | 1000 | 7.11 | 76.03 | 7.94 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Summed | Summed + indexed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.57 | 4.25 | 1.61 | 0 |
| 400 | 400 | 2.76 | 15.28 | 2.98 | 0 |
| 600 | 600 | 4.06 | 33.03 | 4.83 | 0 |
| 800 | 800 | 5.32 | 49.65 | 6.47 | 0 |
| 1000 | 1000 | 6.50 | 74.75 | 8.15 | 0 |

### Preliminary: basic vs summed driver

Median of up to 3 runs per point (single run when a run takes 60 s or more).

#### Tweets (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 1 | 0.41 | 10.06 | 0.42 | 0 |
| 400 | 1 | 0.34 | 60.16 | 0.92 | 0 |
| 600 | 1 | 0.28 | 164.83 | 1.53 | 0 |
| 800 | NA | 0.33 | > limit | 2.01 | NA |
| 1000 | NA | 0.36 | – | 2.93 | NA |

**Threshold 0.2**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 61 | 0.19 | 0.46 | 0.41 | 0 |
| 400 | 66 | 0.31 | 1.05 | 0.85 | 0 |
| 600 | 67 | 0.28 | 1.98 | 1.42 | 0 |
| 800 | 67 | 0.32 | 3.04 | 2.05 | 0 |
| 1000 | 68 | 0.36 | 4.42 | 3.06 | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 191 | 0.24 | 0.39 | 0.39 | 0 |
| 400 | 365 | 0.23 | 0.83 | 0.85 | 0 |
| 600 | 521 | 0.28 | 1.56 | 1.77 | 0 |
| 800 | 677 | 0.33 | 2.50 | 2.36 | 0 |
| 1000 | 818 | 0.36 | 3.50 | 3.38 | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.24 | 0.40 | 0.40 | 0 |
| 400 | 400 | 0.32 | 0.83 | 0.84 | 0 |
| 600 | 600 | 0.28 | 1.54 | 1.50 | 0 |
| 800 | 800 | 0.31 | 2.32 | 2.35 | 0 |
| 1000 | 1000 | 0.37 | 3.46 | 3.58 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.19 | 0.41 | 0.40 | 0 |
| 400 | 400 | 0.32 | 0.84 | 0.84 | 0 |
| 600 | 600 | 0.30 | 1.46 | 1.51 | 0 |
| 800 | 800 | 0.31 | 2.27 | 2.38 | 0 |
| 1000 | 1000 | 0.35 | 3.41 | 3.43 | 0 |

#### News (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | NA | 1.51 | > limit | 4.69 | NA |
| 400 | NA | 2.77 | – | 14.40 | NA |
| 600 | NA | 4.10 | – | 26.38 | NA |
| 800 | NA | 5.03 | – | 46.86 | NA |
| 1000 | NA | 6.62 | – | 71.70 | NA |

**Threshold 0.2**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 49 | 1.45 | 6.32 | 4.64 | 0 |
| 400 | 50 | 2.65 | 19.78 | 14.28 | 0 |
| 600 | 50 | 3.92 | 44.79 | 29.67 | 0 |
| 800 | 50 | 5.35 | 77.40 | 45.55 | 0 |
| 1000 | 50 | 6.34 | 123.76 | 66.75 | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.51 | 3.94 | 4.02 | 0 |
| 400 | 400 | 2.73 | 13.73 | 13.64 | 0 |
| 600 | 600 | 3.92 | 27.76 | 29.55 | 0 |
| 800 | 800 | 5.19 | 45.71 | 48.57 | 0 |
| 1000 | 1000 | 6.43 | 67.52 | 70.97 | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.42 | 3.95 | 4.09 | 0 |
| 400 | 400 | 2.64 | 13.14 | 13.92 | 0 |
| 600 | 600 | 3.99 | 28.77 | 29.54 | 0 |
| 800 | 800 | 5.13 | 44.94 | 46.95 | 0 |
| 1000 | 1000 | 6.23 | 67.51 | 69.89 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Basic | Summed | mismatches |
|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.40 | 3.85 | 3.79 | 0 |
| 400 | 400 | 2.62 | 13.62 | 13.45 | 0 |
| 600 | 600 | 3.85 | 27.86 | 29.00 | 0 |
| 800 | 800 | 5.04 | 45.59 | 49.66 | 0 |
| 1000 | 1000 | 9.65 | 74.00 | 70.11 | 0 |

### Preliminary: light run (before the changes of 2026-10-18; D3 column omitted)

Single run per point; measured before the changes of 2026-10-18.

#### Tweets (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 1 | 0.23 | 10.30 | 11.91 | 0.33 | 0.55 | 4.09 | 0 |
| 400 | 1 | 0.25 | 58.93 | 65.03 | 0.76 | 1.02 | 6.15 | 0 |
| 600 | 1 | 0.28 | 165.16 | 183.22 | 0.81 | 2.84 | 11.83 | 0 |
| 800 | 1 | 0.35 | > limit | > limit | 0.99 | 2.58 | 18.07 | 0 |
| 1000 | 1 | 0.38 | – | – | 0.86 | 3.58 | 25.49 | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 61 | 0.20 | 0.48 | 0.46 | 0.29 | 0.49 | 4.41 | 0 |
| 400 | 66 | 0.24 | 1.20 | 0.87 | 0.40 | 1.11 | 7.25 | 0 |
| 600 | 67 | 0.28 | 1.90 | 1.35 | 0.49 | 1.78 | 14.89 | 0 |
| 800 | 67 | 0.31 | 3.04 | 1.92 | 0.61 | 2.57 | 24.24 | 0 |
| 1000 | 68 | 0.36 | 4.51 | 2.58 | 0.70 | 3.38 | 36.01 | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 191 | 0.19 | 0.39 | 0.37 | 0.29 | 0.79 | 5.62 | 0 |
| 400 | 365 | 0.25 | 0.85 | 0.59 | 0.40 | 2.62 | 10.85 | 0 |
| 600 | 521 | 0.28 | 1.54 | 0.89 | 0.55 | 5.60 | 23.97 | 0 |
| 800 | 677 | 0.32 | 2.35 | 1.02 | 0.64 | 9.66 | 41.80 | 0 |
| 1000 | 818 | 0.41 | 3.41 | 1.27 | 0.78 | 14.58 | 65.19 | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.21 | 0.39 | 0.37 | 0.30 | 0.82 | 5.64 | 0 |
| 400 | 400 | 0.24 | 0.83 | 0.62 | 0.40 | 2.76 | 10.98 | 0 |
| 600 | 600 | 0.28 | 1.56 | 0.78 | 0.54 | 6.53 | 24.67 | 0 |
| 800 | 800 | 0.35 | 2.40 | 1.01 | 0.69 | 10.31 | 44.67 | 0 |
| 1000 | 1000 | 0.37 | 3.70 | 1.24 | 0.83 | 17.21 | 75.18 | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 0.22 | 0.40 | 0.37 | 0.42 | 0.85 | 5.82 | 0 |
| 400 | 400 | 0.24 | 1.06 | 0.58 | 0.40 | 3.22 | 11.21 | 0 |
| 600 | 600 | 0.28 | 1.51 | 0.75 | 0.54 | 6.18 | 24.51 | 0 |
| 800 | 800 | 0.31 | 2.31 | 0.94 | 0.62 | 10.76 | 44.35 | 0 |
| 1000 | 1000 | 0.43 | 3.39 | 1.19 | 0.81 | 16.38 | 68.62 | 0 |

#### News (synthetic)

**Threshold 0**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 1 | 1.43 | 299.32 | > limit | 3.71 | 7.68 | 299.86 | 0 |
| 400 | 1 | 2.90 | > limit | – | 9.57 | 18.68 | > limit | 0 |
| 600 | 1 | 4.14 | – | – | 15.80 | 30.39 | – | 0 |
| 800 | 1 | 5.03 | – | – | 23.51 | 40.64 | – | 0 |
| 1000 | 1 | 6.28 | – | – | 38.23 | 51.48 | – | 0 |

**Threshold 0.2**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 49 | 1.75 | 5.58 | 3.90 | 2.63 | 4.31 | > limit | 0 |
| 400 | 50 | 3.03 | 21.74 | 13.88 | 6.19 | 16.79 | – | 0 |
| 600 | 50 | 4.33 | > limit | 1114.83 | 8.33 | 31.34 | – | 0 |
| 800 | 50 | 5.36 | – | 56.82 | 10.64 | 51.45 | – | 0 |
| 1000 | 50 | 6.68 | – | 106.85 | 23.07 | 75.89 | – | 0 |

**Threshold 0.5**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.47 | 4.36 | 1.89 | 3.17 | 6.84 | > limit | 0 |
| 400 | 400 | 2.94 | 14.23 | 2.77 | 7.02 | 26.46 | – | 0 |
| 600 | 600 | 3.83 | 29.71 | 4.24 | 8.13 | 59.49 | – | 0 |
| 800 | 800 | 5.25 | 46.96 | 6.22 | 11.10 | 121.45 | – | 0 |
| 1000 | 1000 | 6.46 | 88.44 | 25.44 | 31.11 | 255.64 | – | 0 |

**Threshold 0.7**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.69 | 4.06 | 1.83 | 3.17 | 7.12 | > limit | 0 |
| 400 | 400 | 3.01 | 15.98 | 3.66 | 7.32 | 28.92 | – | 0 |
| 600 | 600 | 4.12 | 39.09 | 4.32 | 9.74 | 64.74 | – | 0 |
| 800 | 800 | 5.28 | 52.05 | 6.04 | 11.34 | 119.79 | – | 0 |
| 1000 | 1000 | 6.34 | 67.82 | 20.12 | 26.53 | 201.32 | – | 0 |

**Threshold 1**

| docs | clusters | TF-IDF | Basic | Mean + indexed | HadathSQL | Array CTE (non-standard) | Standard SQL CTE | mismatches |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 | 200 | 1.43 | 4.92 | 1.73 | 2.90 | 7.92 | > limit | 0 |
| 400 | 400 | 3.42 | 15.57 | 3.20 | 8.29 | 31.12 | – | 0 |
| 600 | 600 | 4.33 | 34.71 | 4.96 | 9.29 | 65.17 | – | 0 |
| 800 | 800 | 5.68 | 48.24 | 6.18 | 11.39 | 117.59 | – | 0 |
| 1000 | 1000 | 7.03 | 69.75 | 21.59 | 31.45 | 188.04 | – | 0 |

<!-- RESULTS:END -->

## Observations from the light run (preliminary)

Light run completed on 2026-10-17 (tweets and news, all five thresholds, 200–1,000
documents, 5-minute limit, one run per point).

1. **Correctness.** Every completed run assigned every document to the same cluster
   as D4 (0 mismatches), in both settings and at all thresholds, including 0 and 1.
2. **Large clusters (threshold 0; news at 0.2): D4 is clearly fastest.** At threshold
   0 (one cluster), the basic driver, the indexed driver, and D3 hit the limit at 800 tweets and at 200–400 news documents,
   because they rewrite the whole, growing centroid for every document; D4 takes 0.9 s
   (tweets) and 38 s (news) at 1,000 documents. On news at 0.2 (50 clusters), D4 takes
   23 s at 1,000 documents against 76 s for A and 107–108 s for the indexed driver and D3.
3. **Many small clusters (threshold 0.5 and above): the indexed driver and D3 are slightly faster
   than D4.** With about one cluster per document there is no centroid rewrite to
   save, and D4's add-document statement (upsert plus norm delta) costs more than
   the indexed driver's and D3's plain insert: tweets 0.6–0.7 s (D3) vs 0.8 s (D4); news 19–25 s (Indexed, D3)
   vs 27–31 s (D4) at 1,000 documents.
4. **CTEs.** A is competitive only when there are few, large clusters; with many
   clusters it grows quickly (news, 1,000 documents: 188–256 s). C is the slowest
   everywhere: 25–75 s for 1,000 tweets, and it hits the limit at 200 news documents
   at every threshold except 0, where it took 300 s.
5. **TF-IDF build** (not included in any method): 0.2–0.4 s for tweets and 1.4–7 s for
   news, comparable to D4's clustering time on tweets.
6. **Measurement problems, to fix before the full evaluation.**
   - The time limit was not always enforced: D3 (tweets, threshold 0, 600 documents)
     ran 583 s and the indexed driver (news, 0.2, 600 documents) ran 1,115 s before finishing.
   - Some times jump without a change in the data's character: the indexed driver on news at 0.2 took
     1,115 s at 600 documents but 57 s at 800; on news at 0.5–1, all three indexed
     drivers jump 3–4× between 800 and 1,000 documents. Both point to plan changes
     driven by outdated statistics on tables that grow from empty during the run.

