-- Merged statements (2026-10-20): as in the HadathSQL driver, a new cluster is created
-- empty and every document, including the one that seeds a cluster, is added with one
-- add-document statement; each document runs 2 statements (3 if it starts a cluster).
-- Summed + indexed + prepared driver: the summed + indexed driver with prepared
-- statements only. Each per-document statement is prepared once per call (PREPARE)
-- and executed by name inside the loop, so it is parsed once and, after a few
-- executions, can reuse a cached plan. Everything else is identical to the summed +
-- indexed driver: the same merged statements, summed centroids, indexes, stored
-- squared norms, statistics refresh, random_page_cost = 1.1, default fill factor.
-- It differs from the HadathSQL driver only in the fill factor of the centroid table
-- (default 100 here, 80 there) and in leaving the cluster table without the final
-- norm column.
-- Installed as hsql_spc_sumidxp (tables via hsql_spc_sumidxp_tbls); prepared
-- statements are named hsql_spcp_*.
-- Evaluation variant: clusters from an existing TF-IDF table, like
-- hsql_single_pass_clustering_tfidf; signature (input_tbl, doc_id_col, ts_col,
-- tfidf_tbl, output_tbl, threshold, overwrite_output). It reads tfidf_tbl as given (the original driver had no index on doc_id; the experiment passes it an unindexed copy).
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
       c. If sim* >= threshold: assign d to c* and update c*'s centroid as the
          running mean of the TF-IDF vectors of all documents currently in c*
          (incremental average: new_w = (old_w * n + doc_w) / (n + 1)).
       d. Otherwise: open a new cluster seeded with d's TF-IDF vector.

This module avoids PostgreSQL composite types entirely; all vectors are stored
as normal rows so they can be indexed and queried with plain SQL.

Output tables (all created by `hsql_spc_sumidxp_tbls`):
  <output_tbl>                          (cid SERIAL PK, doc_count INT)
  <output_tbl>_centroid                 (cid FK, term, weight, PK(cid, term))
  <output_tbl>_cluster_assignments      (doc_id PK, cid FK)

Public functions:
  hsql_spc_sumidxp_tbls(output_tbl, centroid_tbl,
                                              assignments_tbl, overwrite_tbl)
  hsql_spc_sumidxp(input_tbl, doc_id_col, text_col, ts_col,
                              output_tbl, threshold, overwrite_output)

Dependencies:
  - `hsql_table_exists_any_schema(text)` from `util/table_utils.sql`
  - `hsql_create_tf_idf_tbl` from `tf_idf/tf_idf.sql`
################################################################################
*/


/* ##############################################################################
hsql_spc_sumidxp_tbls
--------------------------------------------------------------------------------
Creates (or recreates) the three tables used by single-pass clustering:

  <output_tbl>          Cluster registry.
                        Columns: cid SERIAL PRIMARY KEY, doc_count INTEGER.
  <centroid_tbl>        Cluster centroids in long form.
                        Columns: cid -> output_tbl(cid) ON DELETE CASCADE,
                                 term TEXT, weight FLOAT,
                                 PRIMARY KEY (cid, term).
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
CREATE OR REPLACE FUNCTION hsql_spc_sumidxp_tbls(
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

    -- Cluster registry: one row per cluster, with a running document count.
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid SERIAL PRIMARY KEY,
            doc_count integer NOT NULL DEFAULT 0,
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
        )',
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
hsql_spc_sumidxp
--------------------------------------------------------------------------------
Runs single-pass clustering over the documents in `input_tbl`. TF-IDF weights
are built first into `<output_tbl>_tfidf` via `hsql_create_tf_idf_tbl`, then
documents are processed in the order given by `ts_col` (typically a timestamp).
Each document is either assigned to the most similar existing cluster (when
cosine similarity >= threshold) or used to seed a new cluster.

Parameters:
  input_tbl         - Source document table (drives iteration order). Must
                      contain `doc_id_col`, `text_col`, and `ts_col` columns.
  doc_id_col        - Column in `input_tbl` holding the document id (INTEGER).
  text_col          - Column in `input_tbl` holding document text for TF-IDF.
  ts_col            - Column in `input_tbl` used to ORDER BY when iterating.
  output_tbl        - Base name for the output tables (see below).
  threshold         - Minimum cosine similarity in [0, 1] required to attach a
                      document to an existing cluster instead of opening a new
                      one. Default 0.7.
  overwrite_output  - If TRUE, drop and recreate output tables (including
                      `<output_tbl>_tfidf`) when they already exist; otherwise
                      raise. Default FALSE.

Side effects (tables created / populated):
  <output_tbl>_tfidf                 TF-IDF weights (doc_id, term, weight).
  <output_tbl>                       Cluster registry (cid, doc_count).
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

Centroid update (running mean over the n documents already in the cluster):
        new_weight(term) = (old_weight * n + doc_weight) / (n + 1)
  with `n = doc_count(c*)` read before the document is added. Terms whose new
  weight is 0 are removed from the centroid.

Returns: void

Example:
  -- Cluster docs(doc_id, txt, ts) in timestamp order with threshold 0.5
  SELECT hsql_spc_sumidxp('docs', 'doc_id', 'txt', 'ts',
                                     'doc_clusters', 0.5, TRUE);

  -- Clusters and their sizes
  SELECT cid, doc_count FROM doc_clusters ORDER BY doc_count DESC;

  -- Cluster of each document
  SELECT doc_id, cid FROM doc_clusters_cluster_assignments;

  A runnable example is in demo.sql in this directory.

Notes:
  - All dynamic SQL is formatted once before the main loop; per-iteration cost
    therefore scales with the body of `best_cluster_query` (O(clusters) work
    inside SQL) plus a handful of bound-parameter EXECUTEs.
  - Tie-breaks between equally similar clusters go to the largest `cid`,
    i.e. the most recently created cluster
    (`ORDER BY sim DESC, b_norm.cid DESC`), keeping results deterministic.
  - `<output_tbl>_tfidf` is built once at the start and read during clustering;
    it is not modified after creation.
  - The similarity check tolerates a NULL `max_similarity` (no clusters yet or
    all-zero norms) by treating it as 0, matching the cosine-formula note above.
############################################################################## */
CREATE OR REPLACE FUNCTION hsql_spc_sumidxp(
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
    -- Prepared (formatted) dynamic SQL statements; built once and reused per doc.
    retrieve_documents_query text;  -- Iterates doc ids from input_tbl in ts_col order.
    best_cluster_query text;        -- Returns (cid, similarity) of the closest cluster.
    new_cluster_query text;         -- INSERT an empty cluster row, RETURNING cid.
    add_document_query text;        -- Adds a document to a cluster (merged statement).

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
    next_analyze integer := 16;     -- Document count at which statistics are next refreshed.
    stmt_name text;                 -- Name of a leftover prepared statement to deallocate.
BEGIN
    -- Prepared statements live for the whole session; drop any left behind by an
    -- earlier call that failed before it could deallocate them.
    FOR stmt_name IN
        SELECT name FROM pg_prepared_statements WHERE name LIKE 'hsql\_spcp\_%'
    LOOP
        EXECUTE format('DEALLOCATE %I', stmt_name);
    END LOOP;

    RAISE NOTICE 'Creating output tables %, %, %...', output_tbl, centroid_tbl, assignments_tbl;
    PERFORM hsql_spc_sumidxp_tbls(output_tbl, centroid_tbl, assignments_tbl, overwrite_output);

    -- Drive the main loop: stream document ids in the requested chronological order.
    retrieve_documents_query := format(
        'SELECT %I FROM %I ORDER BY %I',
        doc_id_col, input_tbl, ts_col
    );

    -- Pick the best-matching cluster for the document whose id is bound to $1.
    --   a       = tfidf_tbl rows for the current document (doc vector).
    --   b       = centroid_tbl rows for each existing cluster (centroid vectors).
    --   sim     = cosine similarity using the standard dot/norm formula above.
    -- The query returns (cid, sim) of the single best cluster (LIMIT 1), with
    -- ties broken by larger cid (most recently created cluster) for determinism.
    best_cluster_query := format(
        'WITH a AS (                       -- document vector (index on doc_id)
             SELECT term, weight
             FROM %I
             WHERE doc_id = $1
         ),
         a_norm AS (                       -- ||a||
             SELECT SQRT(COALESCE(SUM(weight * weight), 0.0)) AS norm
             FROM a
         ),
         dot_val AS (                      -- a . s_c per cluster sharing a term (term index)
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
         JOIN %I r ON r.cid = c.cid       -- stored ||s_c||^2
         CROSS JOIN a_norm
         ORDER BY sim DESC, c.cid DESC
         LIMIT 1',
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl,
        output_tbl
    );

    -- Create an empty cluster; the document that seeds it is then added with
    -- add_document_query, like any other document (merged statements).
    new_cluster_query := format(
        'INSERT INTO %I DEFAULT VALUES RETURNING cid',
        output_tbl
    );

    -- Add the document with id $2 to cluster $1 in one statement (merged, as in the
    -- HadathSQL driver): delta = change of the squared norm of the sum (Equation 3,
    -- read from the sums before the upsert: all parts see the same snapshot); add the
    -- positive weights to the sums; record the assignment; increment the size and add
    -- delta to sum_sq_norm.
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



    -- Prepare every per-document statement once (the only change from the summed +
    -- indexed driver). Inside the loop, each one is run with EXECUTE <name>(<integer
    -- arguments>), so the server reuses its parse tree and, after a few executions,
    -- its plan.
    EXECUTE format('PREPARE hsql_spcp_best(integer) AS %s', best_cluster_query);
    EXECUTE format('PREPARE hsql_spcp_new_cluster AS %s', new_cluster_query);
    EXECUTE format('PREPARE hsql_spcp_add_document(integer, integer) AS %s', add_document_query);

    RAISE NOTICE '########################################################';
    RAISE NOTICE 'Starting standard SQL single-pass clustering...';
    RAISE NOTICE '########################################################';

    FOR doc_id IN EXECUTE retrieve_documents_query
    LOOP
        most_similar_cluster_id := NULL;
        max_similarity := NULL;
        IF doc_count > 0 THEN
            -- Find the best cluster for this document.
            EXECUTE format('EXECUTE hsql_spcp_best(%s)', doc_id)
            INTO most_similar_cluster_id, max_similarity;
        END IF;

        -- COALESCE guards against NULL (no cluster yet, or all-zero norms).
        IF most_similar_cluster_id IS NOT NULL
           AND COALESCE(max_similarity, 0.0) >= threshold THEN
            assigned_cluster_id := most_similar_cluster_id;
        ELSE
            -- First document, or below threshold: open a new, empty cluster.
            EXECUTE 'EXECUTE hsql_spcp_new_cluster' INTO assigned_cluster_id;
        END IF;

        -- Add the document to its cluster with one statement.
        EXECUTE format('EXECUTE hsql_spcp_add_document(%s, %s)', assigned_cluster_id, doc_id);
        doc_count := doc_count + 1;
        IF doc_count >= next_analyze THEN   -- as in D4: keep plans in step with the growing tables
            EXECUTE format('ANALYZE %I, %I', output_tbl, centroid_tbl);
            next_analyze := next_analyze * 2;
        END IF;
    END LOOP;

    -- Release the prepared statements.
    FOR stmt_name IN
        SELECT name FROM pg_prepared_statements WHERE name LIKE 'hsql\_spcp\_%'
    LOOP
        EXECUTE format('DEALLOCATE %I', stmt_name);
    END LOOP;

    -- Turn the summed centroids into means (a sum over one document is its mean).
    EXECUTE format(
        'UPDATE %I c SET weight = c.weight / r.doc_count FROM %I r
         WHERE r.cid = c.cid AND r.doc_count > 1',
        centroid_tbl, output_tbl
    );

    EXECUTE format('SELECT COUNT(*) FROM %I', output_tbl) INTO final_cluster_count;
    RAISE NOTICE 'Completed. Documents processed: %, clusters created: %', doc_count, final_cluster_count;
END;
$$ LANGUAGE plpgsql
SET random_page_cost = 1.1;   -- as in D4
