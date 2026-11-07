/*
################################################################################
Single-pass clustering with built-in TF-IDF (sp_clustering.sql)
################################################################################
Implements the classic single-pass / leader clustering algorithm. TF-IDF
weights are materialized automatically via `hsql_create_tf_idf_tbl` (from
`tf_idf/tf_idf.sql`) into `<output_tbl>_tfidf` before clustering runs.

Algorithm (one pass over documents, ordered by `ts_col`):
  1. The first document becomes cluster 1; its TF-IDF vector is the centroid.
  2. For each subsequent document d:
       a. Compute cosine similarity between d and every existing centroid.
       b. Let (c*, sim*) be the best (centroid, similarity) pair.
       c. If sim* >= threshold: assign d to c* and update c*'s centroid, the
          mean of the TF-IDF vectors of all documents in c*.
       d. Otherwise: open a new cluster seeded with d's TF-IDF vector.

During the pass, each centroid is stored as the SUM of its documents' vectors
rather than their mean. The cosine similarity does not depend on the length of
a vector, so the sum gives the same similarities as the mean, but adding a
document changes only the entries of the document's own terms, instead of
every entry of the centroid. At the end, every sum is divided by the size of
its cluster, so the output holds the mean centroids.

This module avoids PostgreSQL composite types entirely; all vectors are stored
as normal rows so they can be indexed and queried with plain SQL.

Output tables (all created by `hsql_create_tbls_for_single_pass_clustering`):
  <output_tbl>                          (cid SERIAL PK, doc_count INT, norm FLOAT)
  <output_tbl>_centroid                 (cid FK, term, weight, PK(cid, term),
                                         index on (term, cid))
  <output_tbl>_cluster_assignments      (doc_id PK, cid FK)

Public functions:
  hsql_create_tbls_for_single_pass_clustering(output_tbl, centroid_tbl,
                                              assignments_tbl, overwrite_tbl)
  hsql_single_pass_clustering(input_tbl, doc_id_col, text_col, ts_col,
                              output_tbl, threshold, overwrite_output)
      Builds the TF-IDF table, then clusters (calls the function below).
  hsql_single_pass_clustering_tfidf(input_tbl, doc_id_col, ts_col, tfidf_tbl,
                                    output_tbl, threshold, overwrite_output)
      Clusters using an existing TF-IDF table, e.g. to re-cluster with another
      threshold without rebuilding TF-IDF.

Dependencies:
  - `hsql_table_exists_any_schema(text)` from `util/table_utils.sql`
  - `hsql_create_tf_idf_tbl` from `tf_idf/tf_idf.sql`
################################################################################
*/


/* ##############################################################################
hsql_create_tbls_for_single_pass_clustering
--------------------------------------------------------------------------------
Creates (or recreates) the three tables used by single-pass clustering:

  <output_tbl>          Cluster registry.
                        Columns: cid SERIAL PRIMARY KEY, doc_count INTEGER,
                                 norm FLOAT (Euclidean norm of the centroid),
                                 sum_sq_norm FLOAT (squared norm of the summed
                                 centroid; used during clustering and dropped
                                 by hsql_single_pass_clustering at the end).
  <centroid_tbl>        Cluster centroids in long form.
                        Columns: cid -> output_tbl(cid) ON DELETE CASCADE,
                                 term TEXT, weight FLOAT,
                                 PRIMARY KEY (cid, term).
                        Index on (term, cid), so that the clusters that share a
                        term with a document are found without a scan. weight is
                        left out of the index so that updating a weight does not
                        update the index (it can be a HOT update); the table is
                        created with fillfactor 80 to leave room for such updates.
  <assignments_tbl>     Document-to-cluster assignments.
                        Columns: doc_id INTEGER PRIMARY KEY,
                                 cid -> output_tbl(cid) ON DELETE CASCADE.

Parameters:
  output_tbl       - Name of the cluster registry table to create.
  centroid_tbl     - Name of the centroid table to create.
  assignments_tbl  - Name of the assignments table to create.
  overwrite_tbl    - If TRUE and ANY of the three target tables already exists,
                     drop all three (CASCADE) and recreate them. If FALSE and
                     any of them exists, raise an exception.

Returns: void

Notes:
  - Existence is checked for all three tables, not just `output_tbl`, so
    orphan sibling tables left from a previous run cannot survive an
    `overwrite_tbl=TRUE` rebuild.
############################################################################## */
CREATE OR REPLACE FUNCTION hsql_create_tbls_for_single_pass_clustering(
    output_tbl text,
    centroid_tbl text,
    assignments_tbl text,
    overwrite_tbl boolean DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    any_exists boolean := hsql_table_exists_any_schema(output_tbl)
                       OR hsql_table_exists_any_schema(centroid_tbl)
                       OR hsql_table_exists_any_schema(assignments_tbl);
BEGIN
    IF any_exists AND NOT overwrite_tbl THEN
        RAISE EXCEPTION
            'One of %, %, % already exists. Set overwrite_tbl=TRUE to overwrite.',
            output_tbl, centroid_tbl, assignments_tbl;
    ELSIF any_exists AND overwrite_tbl THEN
        EXECUTE format('DROP TABLE IF EXISTS %I, %I, %I CASCADE', output_tbl, centroid_tbl, assignments_tbl);
    END IF;

    -- Cluster registry: one row per cluster, with a running document count, the
    -- squared norm of the summed centroid (kept up to date during clustering), and
    -- the norm of the mean centroid (set at the end).
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid SERIAL PRIMARY KEY,
            doc_count integer NOT NULL DEFAULT 0,
            norm float NOT NULL DEFAULT 0.0,
            sum_sq_norm float NOT NULL DEFAULT 0.0
        )',
        output_tbl
    );

    -- Centroid table: long-format (cid, term, weight); one row per term per cluster.
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid integer NOT NULL REFERENCES %I(cid) ON DELETE CASCADE,
            term text NOT NULL,
            weight float NOT NULL,
            PRIMARY KEY (cid, term)
        ) WITH (fillfactor = 80)',
        centroid_tbl,
        output_tbl
    );

    -- Term index: finds the clusters that share a term with a document.
    EXECUTE format('CREATE INDEX ON %I (term, cid)', centroid_tbl);

    -- Document-to-cluster assignments (each doc belongs to exactly one cluster).
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            doc_id integer PRIMARY KEY,
            cid integer NOT NULL REFERENCES %I(cid) ON DELETE CASCADE
        )',
        assignments_tbl,
        output_tbl
    );
END;
$$ LANGUAGE plpgsql;


/* ##############################################################################
hsql_single_pass_clustering_tfidf
--------------------------------------------------------------------------------
Runs single-pass clustering over the documents in `input_tbl`, using the TF-IDF
weights already stored in `tfidf_tbl` (as built by `hsql_create_tf_idf_tbl`).
Documents are processed in the order given by `ts_col` (typically a timestamp).
Each document is either assigned to the most similar existing cluster (when
cosine similarity >= threshold) or used to seed a new cluster.

Parameters:
  input_tbl         - Source document table (drives iteration order). Must
                      contain `doc_id_col` and `ts_col` columns.
  doc_id_col        - Column in `input_tbl` holding the document id (INTEGER).
  ts_col            - Column in `input_tbl` used to ORDER BY when iterating.
  tfidf_tbl         - Existing TF-IDF table (doc_id, term, weight). If it has no
                      index on doc_id, one is created (and the table analyzed).
  output_tbl        - Base name for the output tables (see below).
  threshold         - Minimum cosine similarity in [0, 1] required to attach a
                      document to an existing cluster instead of opening a new
                      one. Default 0.7.
  overwrite_output  - If TRUE, drop and recreate the output tables when they
                      already exist; otherwise raise. Default FALSE.

Side effects (tables created / populated):
  <output_tbl>                       Cluster registry (cid, doc_count, norm).
  <output_tbl>_centroid              Per-cluster term weights.
  <output_tbl>_cluster_assignments   doc_id -> cid mapping.

Cosine similarity:
                          sum_t  a_t * b_t
        sim(a, b) = ------------------------------
                    sqrt(sum_t a_t^2) * sqrt(sum_t b_t^2)
  where a is the TF-IDF vector of the current document (a row set from
  `tfidf_tbl` filtered by doc_id) and b is the centroid vector of a candidate
  cluster (a row set from `<output_tbl>_centroid` filtered by cid). When either
  norm is 0 the similarity is treated as 0.

Centroid update (centroids are stored as sums during the pass):
        sum(term) += doc_weight(term)          for each term of the document
        ||sum||^2 += sum_t doc_w(t) * (2 * old_sum(t) + doc_w(t))
  Only the document's terms are touched, and the squared norm is updated from
  them alone. Since sim(a, sum) = sim(a, sum / n), clustering with sums gives
  the same clusters as clustering with means (up to floating-point rounding).
  At the end, weight = sum / doc_count and norm = sqrt(||sum||^2) / doc_count.
  Terms with a weight of 0 never enter a centroid. (A TF-IDF weight is 0 only
  for a term that occurs in every document.)

Returns: void

Example:
  -- Cluster docs(doc_id, txt, ts) in timestamp order with threshold 0.5
  SELECT hsql_single_pass_clustering('docs', 'doc_id', 'txt', 'ts',
                                     'doc_clusters', 0.5, TRUE);

  -- Clusters and their sizes
  SELECT cid, doc_count FROM doc_clusters ORDER BY doc_count DESC;

  -- Cluster of each document
  SELECT doc_id, cid FROM doc_clusters_cluster_assignments;

  A runnable example is in demo.sql in this directory.

Notes:
  - All dynamic SQL is formatted and prepared once before the main loop. Each
    document then runs two prepared statements (three if it starts a cluster):
    `best_cluster_query`, which reads the document's vector through the index on
    `tfidf_tbl(doc_id)`, finds the clusters that share a term with it
    through the term index of the centroid table, and reads their norms from
    `<output_tbl>`; and `add_document_query`, which adds the document to a
    cluster. Neither scans a whole table, and both touch only the entries of the
    document's terms.
  - The statistics of the cluster and centroid tables are refreshed (ANALYZE)
    after 16, 32, 64, ... documents, so that the plans of the prepared statements
    follow the growth of these tables, which start empty.
  - Tie-breaks between equally similar clusters go to the largest `cid`,
    i.e. the most recently created cluster
    (`ORDER BY sim DESC, b_norm.cid DESC`), keeping results deterministic.
  - `tfidf_tbl` is only read during clustering; it is not modified (apart from
    the index on doc_id, created if missing).
  - The similarity check tolerates a NULL `max_similarity` (no clusters yet or
    all-zero norms) by treating it as 0, matching the cosine-formula note above.
############################################################################## */
CREATE OR REPLACE FUNCTION hsql_single_pass_clustering_tfidf(
    input_tbl text,
    doc_id_col text,
    ts_col text,
    tfidf_tbl text,
    output_tbl text,
    threshold float DEFAULT 0.7,
    overwrite_output boolean DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    -- Dynamic SQL statements; formatted once, then prepared (PREPARE) once, so
    -- that each document executes them without parsing or planning them again.
    retrieve_documents_query text;  -- Iterates doc ids from input_tbl in ts_col order.
    best_cluster_query text;        -- Returns (cid, similarity) of the closest cluster.
    new_cluster_query text;         -- INSERT an empty cluster row, RETURNING cid.
    add_document_query text;        -- Adds a document to a cluster (sums, norm, count,
                                    -- assignment) in one statement.

    -- Derived table names.
    centroid_tbl text := output_tbl || '_centroid';
    assignments_tbl text := output_tbl || '_cluster_assignments';

    -- Loop state.
    doc_id integer;                 -- Current document id from input_tbl.
    doc_count integer := 0;         -- Number of documents processed so far.
    assigned_cluster_id integer;    -- cid the current document ended up in.
    most_similar_cluster_id integer;-- Best-matching cluster for the current document.
    max_similarity float;           -- Similarity to most_similar_cluster_id.
    final_cluster_count integer;    -- Number of clusters at completion (for the final NOTICE).
    stmt_name text;                 -- Name of a leftover prepared statement to deallocate.
    next_analyze integer := 16;     -- Document count at which statistics are next refreshed.
BEGIN
    -- Prepared statements live for the whole session; drop any left behind by an
    -- earlier call that failed before it could deallocate them.
    FOR stmt_name IN
        SELECT name FROM pg_prepared_statements WHERE name LIKE 'hsql\_spc\_%'
    LOOP
        EXECUTE format('DEALLOCATE %I', stmt_name);
    END LOOP;

    IF to_regclass(format('%I', tfidf_tbl)) IS NULL THEN
        RAISE EXCEPTION 'TF-IDF table % does not exist; build it with hsql_create_tf_idf_tbl.',
            tfidf_tbl;
    END IF;
    -- Each iteration reads one document's vector; make sure an index on doc_id
    -- exists so that the read is not a scan.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        WHERE i.indrelid = to_regclass(format('%I', tfidf_tbl))
          AND a.attname = 'doc_id'
    ) THEN
        RAISE NOTICE 'Indexing %(doc_id)...', tfidf_tbl;
        EXECUTE format('CREATE INDEX ON %I (doc_id)', tfidf_tbl);
        EXECUTE format('ANALYZE %I', tfidf_tbl);
    END IF;

    RAISE NOTICE 'Creating output tables %, %, %...', output_tbl, centroid_tbl, assignments_tbl;
    PERFORM hsql_create_tbls_for_single_pass_clustering(output_tbl, centroid_tbl, assignments_tbl, overwrite_output);

    -- Drive the main loop: stream document ids in the requested chronological order.
    retrieve_documents_query := format(
        'SELECT %I FROM %I ORDER BY %I',
        doc_id_col, input_tbl, ts_col
    );

    -- Pick the best-matching cluster for the document whose id is bound to $1.
    --   a       = tfidf_tbl rows for the current document (doc vector).
    --   dot_val = a . b_c for the clusters c that share a term with the document,
    --             found through the term index of centroid_tbl; every other
    --             cluster has similarity 0.
    --   norms   = ||b_c|| = sqrt(sum_sq_norm) read from output_tbl, where it is
    --             kept up to date, instead of being recomputed from centroid_tbl.
    --   sim     = cosine similarity using the standard dot/norm formula above.
    -- The query returns (cid, sim) of the single best cluster (LIMIT 1), with
    -- ties broken by larger cid (most recently created cluster) for determinism.
    -- The newest cluster that has a centroid is always a candidate (with
    -- similarity 0), so the result is the same as when every cluster is scored.
    best_cluster_query := format(
        'WITH a AS (                       -- document vector
             SELECT term, weight
             FROM %I
             WHERE doc_id = $1
         ),
         a_norm AS (                       -- ||a||
             SELECT SQRT(COALESCE(SUM(weight * weight), 0.0)) AS norm
             FROM a
         ),
         dot_val AS (                      -- a . b_c per cluster c sharing a term
             SELECT b.cid, SUM(a.weight * b.weight) AS prod
             FROM a
             JOIN %I b ON a.term = b.term
             GROUP BY b.cid
         ),
         candidates AS (
             SELECT cid, prod FROM dot_val
             UNION ALL
             SELECT MAX(cid), NULL FROM %I  -- newest cluster, similarity 0
         )
         SELECT c.cid,
                COALESCE(
                    c.prod / NULLIF(a_norm.norm * SQRT(r.sum_sq_norm), 0.0),
                    0.0
                ) AS sim
         FROM candidates c
         JOIN %I r ON r.cid = c.cid
         CROSS JOIN a_norm
         ORDER BY sim DESC, c.cid DESC
         LIMIT 1',
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl,
        output_tbl
    );

    -- Create an empty cluster (doc_count 0, sum_sq_norm 0); the document that seeds
    -- it is then added with add_document_query, like any other document.
    new_cluster_query := format(
        'INSERT INTO %I DEFAULT VALUES RETURNING cid',
        output_tbl
    );

    -- Add the document with id $2 to cluster $1, in one statement:
    --   doc      = the document's positive TF-IDF weights (zero weights never enter
    --              a centroid).
    --   delta    = the change of the squared norm of the summed centroid,
    --              sum_t w_t * (2 * s_t + w_t), where s_t is the current sum of term t
    --              (0 if absent). All parts of the statement see the same snapshot,
    --              so delta reads the sums from before the upsert.
    --   upserted = add each weight to the centroid sum of its term (insert the term
    --              if the centroid lacks it); entries of other terms are untouched.
    --   assigned = record the assignment.
    --   UPDATE   = increment doc_count and add delta to sum_sq_norm.
    add_document_query := format(
        'WITH doc AS (
             SELECT term, weight
             FROM %I
             WHERE doc_id = $2
               AND weight > 0.0
         ),
         delta AS (
             SELECT COALESCE(SUM(d.weight * (2.0 * COALESCE(c.weight, 0.0) + d.weight)), 0.0)
                    AS sq
             FROM doc d
             LEFT JOIN %I c ON c.cid = $1 AND c.term = d.term
         ),
         upserted AS (
             INSERT INTO %I AS ct (cid, term, weight)
             SELECT $1, term, weight FROM doc
             ON CONFLICT (cid, term) DO UPDATE
             SET weight = ct.weight + EXCLUDED.weight
         ),
         assigned AS (
             INSERT INTO %I (doc_id, cid) VALUES ($2, $1)
         )
         UPDATE %I
         SET doc_count = doc_count + 1,
             sum_sq_norm = sum_sq_norm + (SELECT sq FROM delta)
         WHERE cid = $1',
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl,
        assignments_tbl,
        output_tbl
    );

    -- Prepare every per-document statement once. Inside the loop, each one is run
    -- with EXECUTE <name>(<integer arguments>), so the server reuses its parse tree
    -- and, after a few executions, its plan.
    EXECUTE format('PREPARE hsql_spc_best(integer) AS %s', best_cluster_query);
    EXECUTE format('PREPARE hsql_spc_new_cluster AS %s', new_cluster_query);
    EXECUTE format('PREPARE hsql_spc_add_document(integer, integer) AS %s', add_document_query);

    RAISE NOTICE '########################################################';
    RAISE NOTICE 'Starting standard SQL single-pass clustering...';
    RAISE NOTICE '########################################################';

    -- All arguments are integers, so formatting them into the EXECUTE command
    -- with %s cannot inject SQL.
    FOR doc_id IN EXECUTE retrieve_documents_query
    LOOP
        most_similar_cluster_id := NULL;
        max_similarity := NULL;
        IF doc_count > 0 THEN
            -- Find the best cluster for this document.
            EXECUTE format('EXECUTE hsql_spc_best(%s)', doc_id)
            INTO most_similar_cluster_id, max_similarity;
        END IF;

        -- COALESCE guards against NULL (no cluster yet, or all-zero norms).
        IF most_similar_cluster_id IS NOT NULL
           AND COALESCE(max_similarity, 0.0) >= threshold THEN
            -- Attach to the most similar cluster.
            assigned_cluster_id := most_similar_cluster_id;
        ELSE
            -- First document, or below threshold: open a new cluster.
            EXECUTE 'EXECUTE hsql_spc_new_cluster' INTO assigned_cluster_id;
        END IF;

        EXECUTE format('EXECUTE hsql_spc_add_document(%s, %s)', assigned_cluster_id, doc_id);
        doc_count := doc_count + 1;

        -- The cluster and centroid tables grow from empty during the pass, faster
        -- than autovacuum refreshes their statistics. With outdated statistics, the
        -- planner can choose, and the prepared statements can keep, a plan that scans
        -- the whole centroid table for every document instead of using the term index.
        -- Refreshing the statistics each time the number of documents doubles costs
        -- only about log2(N) ANALYZE runs, and each one invalidates the cached plans,
        -- so the prepared statements are planned again with the current sizes.
        IF doc_count >= next_analyze THEN
            EXECUTE format('ANALYZE %I, %I', output_tbl, centroid_tbl);
            next_analyze := next_analyze * 2;
        END IF;
    END LOOP;

    -- Turn the summed centroids into mean centroids, and their norms accordingly.
    EXECUTE format(
        'UPDATE %I c SET weight = c.weight / r.doc_count FROM %I r
         WHERE r.cid = c.cid AND r.doc_count > 1',     -- a sum over one document is its mean
        centroid_tbl, output_tbl
    );
    EXECUTE format(
        'UPDATE %I SET norm = SQRT(sum_sq_norm) / doc_count', output_tbl
    );
    EXECUTE format('ALTER TABLE %I DROP COLUMN sum_sq_norm', output_tbl);

    -- Release the prepared statements.
    FOR stmt_name IN
        SELECT name FROM pg_prepared_statements WHERE name LIKE 'hsql\_spc\_%'
    LOOP
        EXECUTE format('DEALLOCATE %I', stmt_name);
    END LOOP;

    EXECUTE format('SELECT COUNT(*) FROM %I', output_tbl) INTO final_cluster_count;
    RAISE NOTICE 'Completed. Documents processed: %, clusters created: %', doc_count, final_cluster_count;
END;
$$ LANGUAGE plpgsql
-- The centroid table is written during the pass and stays in memory, so random page
-- reads are cheap. With the default random_page_cost (4.0, which models a spinning
-- disk), the planner prefers scanning the whole centroid table in best_cluster_query
-- over one term-index lookup per term of the document, which is several times slower
-- once the table is large. The setting applies only while this function runs.
SET random_page_cost = 1.1;


/* ##############################################################################
hsql_single_pass_clustering
--------------------------------------------------------------------------------
Builds the TF-IDF weights of the documents in `input_tbl` into
`<output_tbl>_tfidf` with `hsql_create_tf_idf_tbl`, indexes them on doc_id, and
then clusters the documents with `hsql_single_pass_clustering_tfidf`.

Parameters:
  input_tbl         - Source document table. Must contain `doc_id_col`,
                      `text_col`, and `ts_col` columns.
  doc_id_col        - Column in `input_tbl` holding the document id (INTEGER).
  text_col          - Column in `input_tbl` holding document text for TF-IDF.
  ts_col            - Column in `input_tbl` used to ORDER BY when iterating.
  output_tbl        - Base name for the output tables.
  threshold         - Similarity threshold (see hsql_single_pass_clustering_tfidf).
                      Default 0.7.
  overwrite_output  - If TRUE, drop and recreate the output tables (including
                      `<output_tbl>_tfidf`) when they already exist; otherwise
                      raise. Default FALSE.

Side effects: `<output_tbl>_tfidf` (doc_id, term, weight), plus the output tables
of hsql_single_pass_clustering_tfidf.

Returns: void

Example:
  -- Cluster docs(doc_id, txt, ts) in timestamp order with threshold 0.5
  SELECT hsql_single_pass_clustering('docs', 'doc_id', 'txt', 'ts',
                                     'doc_clusters', 0.5, TRUE);

  -- Re-cluster with another threshold, reusing the TF-IDF table
  SELECT hsql_single_pass_clustering_tfidf('docs', 'doc_id', 'ts', 'doc_clusters_tfidf',
                                           'doc_clusters_07', 0.7, TRUE);
############################################################################## */
CREATE OR REPLACE FUNCTION hsql_single_pass_clustering(
    input_tbl text,
    doc_id_col text,
    text_col text,
    ts_col text,
    output_tbl text,
    threshold float DEFAULT 0.7,
    overwrite_output boolean DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    tfidf_tbl text := output_tbl || '_tfidf';
BEGIN
    RAISE NOTICE 'Building TF-IDF table %...', tfidf_tbl;
    PERFORM hsql_create_tf_idf_tbl(input_tbl, doc_id_col, text_col, tfidf_tbl, overwrite_output);
    EXECUTE format('CREATE INDEX ON %I (doc_id)', tfidf_tbl);
    EXECUTE format('ANALYZE %I', tfidf_tbl);

    PERFORM hsql_single_pass_clustering_tfidf(
        input_tbl, doc_id_col, ts_col, tfidf_tbl, output_tbl, threshold, overwrite_output
    );
END;
$$ LANGUAGE plpgsql;
