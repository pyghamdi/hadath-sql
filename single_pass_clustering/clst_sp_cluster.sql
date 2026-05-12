/*
################################################################################
Single-pass clustering (standard SQL-friendly representation)
################################################################################
This variant avoids PostgreSQL composite types and stores vectors in normalized
tables:
  - TF-IDF input table: (doc_id, term, weight)
  - Cluster metadata table: <output_tbl> (cid, doc_count)
  - Cluster centroid terms: <output_tbl>_centroid (cid, term, weight)
  - Doc assignment table: <output_tbl>_cluster_assignments (doc_id, cid)
################################################################################
*/

DROP FUNCTION IF EXISTS clst_create_cluster_tables(text, text, text, boolean) CASCADE;
DROP FUNCTION IF EXISTS clst_single_pass_clustering(text, text, text, text, text, float, boolean) CASCADE;

/* ##############################################################################
clst_create_cluster_tables
############################################################################## */
CREATE OR REPLACE FUNCTION clst_create_cluster_tables(
    output_tbl text,
    centroid_tbl text,
    assignments_tbl text,
    overwrite_tbl boolean DEFAULT FALSE
)
RETURNS VOID AS $$
BEGIN
    IF hsql_table_exists_any_schema(output_tbl) AND NOT overwrite_tbl THEN
        RAISE EXCEPTION 'Table % already exists. Set overwrite_tbl=TRUE to overwrite the table.', output_tbl;
    ELSIF hsql_table_exists_any_schema(output_tbl) AND overwrite_tbl THEN
        EXECUTE format('DROP TABLE IF EXISTS %I, %I, %I CASCADE', output_tbl, centroid_tbl, assignments_tbl);
    END IF;

    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid SERIAL PRIMARY KEY,
            doc_count integer NOT NULL DEFAULT 0
        )',
        output_tbl
    );

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
clst_single_pass_clustering
############################################################################## */
CREATE OR REPLACE FUNCTION clst_single_pass_clustering(
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
    retrieve_documents_query text;
    best_cluster_query text;
    update_centroid_query text;
    centroid_tbl text := output_tbl || '_centroid';
    assignments_tbl text := output_tbl || '_cluster_assignments';
    doc_id integer;
    doc_count integer := 0;
    cluster_count integer := 0;
    assigned_cluster_id integer;
    most_similar_cluster_id integer;
    max_similarity float;
    existing_doc_count integer;
BEGIN
    IF NOT hsql_table_exists_any_schema(tfidf_tbl) THEN
        RAISE EXCEPTION 'TF-IDF model table % does not exist. Please create the TF-IDF model table using the tfidf_create_model function first.', tfidf_tbl;
    END IF;

    RAISE NOTICE 'Creating output tables %, %, %...', output_tbl, centroid_tbl, assignments_tbl;
    PERFORM clst_create_cluster_tables(output_tbl, centroid_tbl, assignments_tbl, overwrite_output);

    retrieve_documents_query := format(
        'SELECT %I FROM %I ORDER BY %I',
        doc_id_col, input_tbl, ts_col
    );

    best_cluster_query := format(
        'WITH a AS (
             SELECT term, weight
             FROM %I -- a table (doc_weights table)
             WHERE doc_id = $1
         ),
         a_norm_sq AS (
             SELECT COALESCE(SUM(weight * weight), 0.0) AS norm_sq
             FROM a
         ),
         b_norm_sq AS (
             SELECT cid, COALESCE(SUM(weight * weight), 0.0) AS norm_sq
             FROM %I -- b table (centroid_tbl)
             GROUP BY cid
         ),
         dot_val AS (
             SELECT cid, SUM(a.weight * b.weight) AS prod
             FROM a  -- a table (doc_weights table)
             JOIN %I b ON a.term = b.term
             GROUP BY cid
         )
         SELECT b_norm_sq.cid,
                COALESCE(
                    dot_val.prod / NULLIF(SQRT(a_norm_sq.norm_sq) * SQRT(b_norm_sq.norm_sq), 0.0),
                    0.0
                ) AS sim
         FROM a_norm_sq
         CROSS JOIN b_norm_sq
         LEFT JOIN dot_val ON dot_val.cid = b_norm_sq.cid
         ORDER BY sim DESC, b_norm_sq.cid
         LIMIT 1',
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl
    );

    update_centroid_query := format(
        'WITH merged AS (
             SELECT
                 COALESCE(cluster.term, doc.term) AS term,
                 (
                     COALESCE(cluster.weight, 0.0) * COALESCE($3, 0) +
                     COALESCE(doc.weight, 0.0)
                 ) / (COALESCE($3, 0) + 1.0) AS new_weight
             FROM (
                 SELECT term, weight
                 FROM %I
                 WHERE cid = $1
             ) AS cluster
             FULL OUTER JOIN (
                 SELECT term, weight 
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
         DELETE FROM %I ct
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

    RAISE NOTICE '########################################################';
    RAISE NOTICE 'Starting standard SQL single-pass clustering...';
    RAISE NOTICE '########################################################';

    FOR doc_id IN EXECUTE retrieve_documents_query 
    LOOP
        IF doc_count = 0 THEN -- First document creating a new cluster
            EXECUTE format(
                'INSERT INTO %I (doc_count) VALUES (1) RETURNING cid',
                output_tbl
            )
            INTO assigned_cluster_id;

            EXECUTE format(
                'INSERT INTO %I (cid, term, weight)
                 SELECT $1, term, weight
                 FROM %I
                 WHERE doc_id = $2',
                centroid_tbl,
                tfidf_tbl
            )
            USING assigned_cluster_id, doc_id;

            EXECUTE format(
                'INSERT INTO %I (doc_id, cid) VALUES ($1, $2)',
                assignments_tbl
            )
            USING doc_id, assigned_cluster_id;

            cluster_count := cluster_count + 1;
        ELSE
            EXECUTE best_cluster_query
            INTO most_similar_cluster_id, max_similarity
            USING doc_id;

            IF max_similarity >= threshold THEN
                assigned_cluster_id := most_similar_cluster_id;

                EXECUTE format('SELECT doc_count FROM %I WHERE cid = $1', output_tbl)
                INTO existing_doc_count
                USING assigned_cluster_id;

                EXECUTE update_centroid_query
                USING assigned_cluster_id, doc_id, existing_doc_count;

                EXECUTE format('UPDATE %I SET doc_count = doc_count + 1 WHERE cid = $1', output_tbl)
                USING assigned_cluster_id;

                EXECUTE format('INSERT INTO %I (doc_id, cid) VALUES ($1, $2)', assignments_tbl)
                USING doc_id, assigned_cluster_id;
            ELSE
                EXECUTE format(
                    'INSERT INTO %I (doc_count) VALUES (1) RETURNING cid',
                    output_tbl
                )
                INTO assigned_cluster_id;

                EXECUTE format(
                    'INSERT INTO %I (cid, term, weight)
                     SELECT $1, term, weight
                     FROM %I
                     WHERE doc_id = $2',
                    centroid_tbl,
                    tfidf_tbl
                )
                USING assigned_cluster_id, doc_id;

                EXECUTE format('INSERT INTO %I (doc_id, cid) VALUES ($1, $2)', assignments_tbl)
                USING doc_id, assigned_cluster_id;

                cluster_count := cluster_count + 1;
            END IF;
        END IF;

        doc_count := doc_count + 1;
    END LOOP;

    RAISE NOTICE 'Completed. Documents processed: %, clusters created: %', doc_count, cluster_count;
END;
$$ LANGUAGE plpgsql;


/* ##############################################################################
clst_single_pass_clustering_v2
############################################################################## */
CREATE OR REPLACE FUNCTION clst_single_pass_clustering_v2(
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
    retrieve_documents_query text;
    best_cluster_query text;
    update_centroid_query text;
    centroid_tbl text := output_tbl || '_centroid';
    assignments_tbl text := output_tbl || '_cluster_assignments';
    doc_id integer;
    doc_count integer := 0;
    cluster_count integer := 0;
    assigned_cluster_id integer;
    most_similar_cluster_id integer;
    max_similarity float;
    existing_doc_count integer;
BEGIN
    IF NOT hsql_table_exists_any_schema(tfidf_tbl) THEN
        RAISE EXCEPTION 'TF-IDF model table % does not exist. Please create the TF-IDF model table using the tfidf_create_model function first.', tfidf_tbl;
    END IF;

    RAISE NOTICE 'Creating output tables %, %, %...', output_tbl, centroid_tbl, assignments_tbl;
    PERFORM clst_create_cluster_tables(output_tbl, centroid_tbl, assignments_tbl, overwrite_output);

    retrieve_documents_query := format(
        'SELECT %I FROM %I ORDER BY %I',
        doc_id_col, input_tbl, ts_col
    );

    best_cluster_query := format(
        'WITH a AS (
             SELECT term, weight
             FROM %I -- a table (doc_weights table)
             WHERE doc_id = $1
         ),
         a_norm AS (
             SELECT COALESCE(SQRT(SUM(weight * weight)), 0.0) AS norm
             FROM a
         ),
         b_norm AS (
             SELECT cid, COALESCE(SQRT(SUM(weight * weight)), 0.0) AS norm
             FROM %I -- b table (centroid_tbl)
             GROUP BY cid
         ),
         dot_val AS (
             SELECT cid, SUM(a.weight * b.weight) AS prod
             FROM a  -- a table (doc_weights table)
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
         ORDER BY sim DESC, b_norm.cid
         LIMIT 1',
        tfidf_tbl,
        centroid_tbl,
        centroid_tbl
    );

    update_centroid_query := format(
        'WITH merged AS (
             SELECT
                 COALESCE(cluster.term, doc.term) AS term,
                 (
                     COALESCE(cluster.weight, 0.0) * COALESCE($3, 0) +
                     COALESCE(doc.weight, 0.0)
                 ) / (COALESCE($3, 0) + 1.0) AS new_weight
             FROM (
                 SELECT term, weight
                 FROM %I
                 WHERE cid = $1
             ) AS cluster
             FULL OUTER JOIN (
                 SELECT term, weight 
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
         DELETE FROM %I ct
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

    RAISE NOTICE '########################################################';
    RAISE NOTICE 'Starting standard SQL single-pass clustering...';
    RAISE NOTICE '########################################################';

    FOR doc_id IN EXECUTE retrieve_documents_query 
    LOOP
        IF doc_count = 0 THEN -- First document creating a new cluster
            EXECUTE format(
                'INSERT INTO %I (doc_count) VALUES (1) RETURNING cid',
                output_tbl
            )
            INTO assigned_cluster_id;

            EXECUTE format(
                'INSERT INTO %I (cid, term, weight)
                 SELECT $1, term, weight
                 FROM %I
                 WHERE doc_id = $2',
                centroid_tbl,
                tfidf_tbl
            )
            USING assigned_cluster_id, doc_id;

            EXECUTE format(
                'INSERT INTO %I (doc_id, cid) VALUES ($1, $2)',
                assignments_tbl
            )
            USING doc_id, assigned_cluster_id;

            cluster_count := cluster_count + 1;
        ELSE
            EXECUTE best_cluster_query
            INTO most_similar_cluster_id, max_similarity
            USING doc_id;

            IF max_similarity >= threshold THEN
                assigned_cluster_id := most_similar_cluster_id;

                EXECUTE format('SELECT doc_count FROM %I WHERE cid = $1', output_tbl)
                INTO existing_doc_count
                USING assigned_cluster_id;

                EXECUTE update_centroid_query
                USING assigned_cluster_id, doc_id, existing_doc_count;

                EXECUTE format('UPDATE %I SET doc_count = doc_count + 1 WHERE cid = $1', output_tbl)
                USING assigned_cluster_id;

                EXECUTE format('INSERT INTO %I (doc_id, cid) VALUES ($1, $2)', assignments_tbl)
                USING doc_id, assigned_cluster_id;
            ELSE
                EXECUTE format(
                    'INSERT INTO %I (doc_count) VALUES (1) RETURNING cid',
                    output_tbl
                )
                INTO assigned_cluster_id;

                EXECUTE format(
                    'INSERT INTO %I (cid, term, weight)
                     SELECT $1, term, weight
                     FROM %I
                     WHERE doc_id = $2',
                    centroid_tbl,
                    tfidf_tbl
                )
                USING assigned_cluster_id, doc_id;

                EXECUTE format('INSERT INTO %I (doc_id, cid) VALUES ($1, $2)', assignments_tbl)
                USING doc_id, assigned_cluster_id;

                cluster_count := cluster_count + 1;
            END IF;
        END IF;

        doc_count := doc_count + 1;
    END LOOP;

    RAISE NOTICE 'Completed. Documents processed: %, clusters created: %', doc_count, cluster_count;
END;
$$ LANGUAGE plpgsql;
