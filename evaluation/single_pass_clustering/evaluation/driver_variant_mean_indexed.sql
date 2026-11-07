-- Merged statements (2026-10-20): as in the HadathSQL driver, a new cluster is created
-- empty and every document, including the one that seeds a cluster, is added with one
-- add-document statement; each document runs 2 statements (3 if it starts a cluster).
-- Mean + indexed driver (formerly "Indexed", D2): the basic driver plus the changes that avoid scanning
-- whole tables for every document. The TF-IDF table is indexed on doc_id, so a
-- document's vector is read with an index lookup; the centroid table is indexed on
-- (term, cid, weight), so only the clusters that share a term with the document are
-- scored; and the norm of each centroid is stored in the cluster table and recomputed
-- for one cluster per update, instead of recomputing all norms over the whole centroid
-- table. It also refreshes the statistics of its output tables at doubling document
-- counts and runs with random_page_cost = 1.1, so that the planner uses the indexes.
-- Unchanged from the basic driver: running-mean centroids (every update rewrites the
-- whole centroid) and dynamic statements, parsed and planned at every execution.
-- Unlike the basic driver, its per-document updates are merged into one statement.
-- Installed as hsql_spc_mean_indexed (tables via hsql_spc_mean_indexed_tbls, defined in
-- this file).
-- Evaluation variant: clusters from an existing TF-IDF table, like
-- hsql_single_pass_clustering_tfidf; signature (input_tbl, doc_id_col, ts_col,
-- tfidf_tbl, output_tbl, threshold, overwrite_output). Like D4, it refreshes the
-- statistics of its output tables at doubling document counts and runs with
-- random_page_cost = 1.1, so that only its centroid representation differs. It expects tfidf_tbl to be indexed on doc_id.
CREATE OR REPLACE FUNCTION hsql_spc_mean_indexed_tbls(
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

    -- Cluster registry: one row per cluster, with a running document count and
    -- the norm of its centroid (kept up to date by hsql_single_pass_clustering).
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid SERIAL PRIMARY KEY,
            doc_count integer NOT NULL DEFAULT 0,
            norm float NOT NULL DEFAULT 0.0
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
    EXECUTE format('CREATE INDEX ON %I (term, cid, weight)', centroid_tbl);

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


CREATE OR REPLACE FUNCTION hsql_spc_mean_indexed(
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


    RAISE NOTICE 'Creating output tables %, %, %...', output_tbl, centroid_tbl, assignments_tbl;
    PERFORM hsql_spc_mean_indexed_tbls(output_tbl, centroid_tbl, assignments_tbl, overwrite_output);

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
    --   norms   = ||b_c|| read from output_tbl, where it is kept up to date,
    --             instead of being recomputed from centroid_tbl for every document.
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
                    c.prod / NULLIF(a_norm.norm * r.norm, 0.0),
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

    -- Create an empty cluster; the document that seeds it is then added with
    -- add_document_query, like any other document (merged statements).
    new_cluster_query := format(
        'INSERT INTO %I DEFAULT VALUES RETURNING cid',
        output_tbl
    );

    -- Add the document with id $2 to cluster $1 in one statement (merged): read the
    -- cluster size n; compute the running mean (n * old + doc) / (n + 1) of every term
    -- of the centroid or the document; upsert the positive new weights and delete the
    -- entries whose new weight is not positive (the whole centroid is rewritten, as
    -- with any mean); record the assignment; increment the size and store the norm of
    -- the new mean. All parts see the same snapshot, so they read the old centroid.
    add_document_query := format(
        'WITH cl AS (
             SELECT doc_count AS n FROM %I WHERE cid = $1
         ),
         merged AS (
             SELECT
                 COALESCE(cluster.term, doc.term) AS term,
                 (COALESCE(cluster.weight, 0.0) * cl.n + COALESCE(doc.weight, 0.0))
                     / (cl.n + 1.0) AS new_weight
             FROM (
                 SELECT term, weight FROM %I WHERE cid = $1      -- existing centroid
             ) AS cluster
             FULL OUTER JOIN (
                 SELECT term, weight FROM %I WHERE doc_id = $2   -- document vector
             ) AS doc
             ON cluster.term = doc.term
             CROSS JOIN cl
         ),
         upserted AS (
             INSERT INTO %I (cid, term, weight)
             SELECT $1, m.term, m.new_weight
             FROM merged m
             WHERE m.new_weight > 0.0
             ON CONFLICT (cid, term) DO UPDATE
             SET weight = EXCLUDED.weight
         ),
         deleted AS (
             DELETE FROM %I ct
             WHERE ct.cid = $1
               AND NOT EXISTS (
                   SELECT 1 FROM merged m
                   WHERE m.new_weight > 0.0 AND m.term = ct.term
               )
         ),
         assigned AS (
             INSERT INTO %I (doc_id, cid) VALUES ($2, $1)
         )
         UPDATE %I
         SET doc_count = doc_count + 1,
             norm = (SELECT SQRT(COALESCE(SUM(new_weight * new_weight), 0.0))
                     FROM merged WHERE new_weight > 0.0)
         WHERE cid = $1',
        output_tbl,
        centroid_tbl,
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl,
        assignments_tbl,
        output_tbl
    );



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
            EXECUTE best_cluster_query
            INTO most_similar_cluster_id, max_similarity
            USING doc_id;
        END IF;

        -- COALESCE guards against NULL (no cluster yet, or all-zero norms).
        IF most_similar_cluster_id IS NOT NULL
           AND COALESCE(max_similarity, 0.0) >= threshold THEN
            assigned_cluster_id := most_similar_cluster_id;
        ELSE
            -- First document, or below threshold: open a new, empty cluster.
            EXECUTE new_cluster_query INTO assigned_cluster_id;
        END IF;

        -- Add the document to its cluster with one statement.
        EXECUTE add_document_query USING assigned_cluster_id, doc_id;
        doc_count := doc_count + 1;
        IF doc_count >= next_analyze THEN   -- as in D4: keep plans in step with the growing tables
            EXECUTE format('ANALYZE %I, %I', output_tbl, centroid_tbl);
            next_analyze := next_analyze * 2;
        END IF;
    END LOOP;

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
SET random_page_cost = 1.1;   -- as in D4
