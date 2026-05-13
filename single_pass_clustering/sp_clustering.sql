/*
################################################################################
Single-pass clustering over a precomputed TF-IDF table (sp_clustering.sql)
################################################################################
Implements the classic single-pass / leader clustering algorithm on top of a
TF-IDF representation that already lives in a long-format table
`(doc_id, term, weight)` (e.g. built by `hsql_create_tf_idf_tbl` in
`tf_idf/tf_idf.sql`).

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

Output tables (all created by `hsql_create_tbls_for_single_pass_clustering`):
  <output_tbl>                          (cid SERIAL PK, doc_count INT)
  <output_tbl>_centroid                 (cid FK, term, weight, PK(cid, term))
  <output_tbl>_cluster_assignments      (doc_id PK, cid FK)

Public functions:
  hsql_create_tbls_for_single_pass_clustering(output_tbl, centroid_tbl,
                                              assignments_tbl, overwrite_tbl)
  hsql_single_pass_clustering(input_tbl, doc_id_col, ts_col,
                              output_tbl, tfidf_tbl, threshold,
                              overwrite_output)

Dependencies:
  - `hsql_table_exists_any_schema(text)` from `util/table_utils.sql`
  - A TF-IDF table laid out as `(doc_id INTEGER, term TEXT, weight FLOAT)`
################################################################################
*/

DROP FUNCTION IF EXISTS hsql_create_tbls_for_single_pass_clustering(text, text, text, boolean) CASCADE;
DROP FUNCTION IF EXISTS hsql_single_pass_clustering(text, text, text, text, text, float, boolean) CASCADE;


/* ##############################################################################
hsql_create_tbls_for_single_pass_clustering
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

    -- Cluster registry: one row per cluster, with a running document count.
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid SERIAL PRIMARY KEY,
            doc_count integer NOT NULL DEFAULT 0
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
hsql_single_pass_clustering
--------------------------------------------------------------------------------
Runs single-pass clustering over the documents in `input_tbl`, using TF-IDF
weights already materialized in `tfidf_tbl`. Documents are processed in the
order given by `ts_col` (typically a timestamp), and each document is either
assigned to the most similar existing cluster (when cosine similarity
>= threshold) or used to seed a new cluster.

Parameters:
  input_tbl         - Source document table (drives iteration order). Must
                      contain `doc_id_col` and `ts_col` columns.
  doc_id_col        - Column in `input_tbl` holding the document id (INTEGER).
                      Must match the `doc_id` values in `tfidf_tbl`.
  ts_col            - Column in `input_tbl` used to ORDER BY when iterating.
  output_tbl        - Base name for the three output tables (see below).
  tfidf_tbl         - Existing TF-IDF table with schema
                      `(doc_id INTEGER, term TEXT, weight FLOAT)`.
  threshold         - Minimum cosine similarity in [0, 1] required to attach a
                      document to an existing cluster instead of opening a new
                      one. Default 0.7.
  overwrite_output  - If TRUE, drop and recreate the output tables when they
                      already exist; otherwise raise. Default FALSE.

Side effects (tables created / populated):
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

Notes:
  - All dynamic SQL is formatted once before the main loop; per-iteration cost
    therefore scales with the body of `best_cluster_query` (O(clusters) work
    inside SQL) plus a handful of bound-parameter EXECUTEs.
  - Tie-breaks between equally similar clusters go to the largest `cid`,
    i.e. the most recently created cluster
    (`ORDER BY sim DESC, b_norm.cid DESC`), keeping results deterministic.
  - `tfidf_tbl` is read every time a document's vector is needed; it is not
    modified.
  - The similarity check tolerates a NULL `max_similarity` (no clusters yet or
    all-zero norms) by treating it as 0, matching the cosine-formula note above.
############################################################################## */
CREATE OR REPLACE FUNCTION hsql_single_pass_clustering(
    input_tbl text,
    doc_id_col text,
    ts_col text,
    output_tbl text,
    tfidf_tbl text,
    threshold float DEFAULT 0.7,
    overwrite_output boolean DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    -- Prepared (formatted) dynamic SQL statements; built once and reused per doc.
    retrieve_documents_query text;  -- Iterates doc ids from input_tbl in ts_col order.
    best_cluster_query text;        -- Returns (cid, similarity) of the closest cluster.
    update_centroid_query text;     -- Folds a document into an existing centroid.
    seed_cluster_query text;        -- INSERT new cluster row, RETURNING cid.
    seed_centroid_query text;       -- Copy a document's TF-IDF vector as a new centroid.
    insert_assignment_query text;   -- Record (doc_id, cid) in the assignments table.
    get_doc_count_query text;       -- Read doc_count for a given cluster.
    bump_doc_count_query text;      -- Increment doc_count by 1 for a given cluster.

    -- Derived table names.
    centroid_tbl text := output_tbl || '_centroid';
    assignments_tbl text := output_tbl || '_cluster_assignments';

    -- Loop state.
    doc_id integer;                 -- Current document id from input_tbl.
    doc_count integer := 0;         -- Number of documents processed so far.
    assigned_cluster_id integer;    -- cid the current document ended up in.
    most_similar_cluster_id integer;-- Best-matching cluster for the current document.
    max_similarity float;           -- Similarity to most_similar_cluster_id.
    existing_doc_count integer;     -- doc_count of the target cluster BEFORE adding this doc.
    final_cluster_count integer;    -- Number of clusters at completion (for the final NOTICE).
BEGIN
    IF NOT hsql_table_exists_any_schema(tfidf_tbl) THEN
        RAISE EXCEPTION 'TF-IDF table % does not exist. Build it first (e.g. with hsql_create_tf_idf_tbl).', tfidf_tbl;
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
    --   b       = centroid_tbl rows for each existing cluster (centroid vectors).
    --   sim     = cosine similarity using the standard dot/norm formula above.
    -- The query returns (cid, sim) of the single best cluster (LIMIT 1), with
    -- ties broken by larger cid (most recently created cluster) for determinism.
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
         b_norm AS (                       -- ||b_c|| per cluster c
             SELECT cid, SQRT(COALESCE(SUM(weight * weight), 0.0)) AS norm
             FROM %I
             GROUP BY cid
         ),
         dot_val AS (                      -- a . b_c per cluster c
             SELECT cid, SUM(a.weight * b.weight) AS prod
             FROM a
             JOIN %I b ON a.term = b.term
             GROUP BY cid
         )
         SELECT b_norm.cid,
                COALESCE(
                    dot_val.prod / NULLIF(a_norm.norm * b_norm.norm, 0.0),
                    0.0
                ) AS sim
         FROM a_norm
         CROSS JOIN b_norm
         LEFT JOIN dot_val ON dot_val.cid = b_norm.cid
         ORDER BY sim DESC, b_norm.cid DESC
         LIMIT 1',
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl
    );

    -- Update the centroid of cluster $1 by folding in the document with id $2.
    -- $3 is the cluster's doc_count BEFORE this document is added, so the new
    -- centroid weight for each term is the running mean:
    --     new = (old * $3 + doc_weight) / ($3 + 1)
    -- Terms whose new weight is 0 are removed from the centroid table.
    update_centroid_query := format(
        'WITH merged AS (
             SELECT
                 COALESCE(cluster.term, doc.term) AS term,
                 (
                     COALESCE(cluster.weight, 0.0) * COALESCE($3, 0) +
                     COALESCE(doc.weight, 0.0)
                 ) / (COALESCE($3, 0) + 1.0) AS new_weight
             FROM (
                 SELECT term, weight             -- existing centroid (cluster $1)
                 FROM %I
                 WHERE cid = $1
             ) AS cluster
             FULL OUTER JOIN (
                 SELECT term, weight             -- incoming document ($2) vector
                 FROM %I
                 WHERE doc_id = $2
             ) AS doc
             ON cluster.term = doc.term
         ),
         upserted AS (
             INSERT INTO %I (cid, term, weight)
             SELECT $1, m.term, m.new_weight
             FROM merged m
             WHERE m.new_weight > 0.0
             ON CONFLICT (cid, term) DO UPDATE
             SET weight = EXCLUDED.weight
         )
         DELETE FROM %I ct                       -- drop terms that fell to 0
         WHERE ct.cid = $1
           AND NOT EXISTS (
               SELECT 1
               FROM merged m
               WHERE m.new_weight > 0.0
                 AND m.term = ct.term
           )',
        centroid_tbl,
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl
    );

    -- Small per-iteration statements: pre-format once to avoid rebuilding
    -- identifier-quoted SQL inside the hot loop.
    seed_cluster_query := format(
        'INSERT INTO %I (doc_count) VALUES (1) RETURNING cid',
        output_tbl
    );
    seed_centroid_query := format(
        'INSERT INTO %I (cid, term, weight)
         SELECT $1, term, weight
         FROM %I
         WHERE doc_id = $2',
        centroid_tbl,
        tfidf_tbl
    );
    insert_assignment_query := format(
        'INSERT INTO %I (doc_id, cid) VALUES ($1, $2)',
        assignments_tbl
    );
    get_doc_count_query := format(
        'SELECT doc_count FROM %I WHERE cid = $1',
        output_tbl
    );
    bump_doc_count_query := format(
        'UPDATE %I SET doc_count = doc_count + 1 WHERE cid = $1',
        output_tbl
    );

    RAISE NOTICE '########################################################';
    RAISE NOTICE 'Starting standard SQL single-pass clustering...';
    RAISE NOTICE '########################################################';

    FOR doc_id IN EXECUTE retrieve_documents_query
    LOOP
        IF doc_count = 0 THEN
            -- First document: seed cluster 1 unconditionally.
            EXECUTE seed_cluster_query INTO assigned_cluster_id;
            EXECUTE seed_centroid_query USING assigned_cluster_id, doc_id;
            EXECUTE insert_assignment_query USING doc_id, assigned_cluster_id;
        ELSE
            -- Find the best cluster for this document.
            EXECUTE best_cluster_query
            INTO most_similar_cluster_id, max_similarity
            USING doc_id;

            -- COALESCE guards against NULL (e.g. degenerate all-zero norms).
            IF COALESCE(max_similarity, 0.0) >= threshold THEN
                -- Attach to existing cluster: update centroid (running mean),
                -- bump doc_count, and record the assignment.
                assigned_cluster_id := most_similar_cluster_id;

                EXECUTE get_doc_count_query
                INTO existing_doc_count
                USING assigned_cluster_id;

                EXECUTE update_centroid_query
                USING assigned_cluster_id, doc_id, existing_doc_count;

                EXECUTE bump_doc_count_query USING assigned_cluster_id;
                EXECUTE insert_assignment_query USING doc_id, assigned_cluster_id;
            ELSE
                -- Below threshold: open a new cluster seeded with this document.
                EXECUTE seed_cluster_query INTO assigned_cluster_id;
                EXECUTE seed_centroid_query USING assigned_cluster_id, doc_id;
                EXECUTE insert_assignment_query USING doc_id, assigned_cluster_id;
            END IF;
        END IF;

        doc_count := doc_count + 1;
    END LOOP;

    EXECUTE format('SELECT COUNT(*) FROM %I', output_tbl) INTO final_cluster_count;
    RAISE NOTICE 'Completed. Documents processed: %, clusters created: %', doc_count, final_cluster_count;
END;
$$ LANGUAGE plpgsql;
