-- PostgreSQL Incremental Clustering Function
-- Implements TF-IDF based incremental clustering with cosine similarity
-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS plpgsql;

/* #########################################################
 Incremental clustering function using TF-IDF and cosine similarity
 Input: input_table - the table of text documents
 Input: text_column - the column containing the text of the documents
 Input: timestamp_column - the column containing the creation time of the documents
 Input: distance_threshold - the threshold for the distance between the document and the cluster centroid
 Input: document_frequency_table - the table where the document frequency statistics are stored for terms in the documents
 Input: cluster_table - the table to store clusters 
 Input: overwrite_cluster_table - whether to overwrite the cluster table if it exists or raise an error if the overwrite is false and the table exists
 Output: void - the function does not return any value
 ######################################################### */
CREATE OR REPLACE FUNCTION cls_incremental_clustering(input_table text, text_column text, timestamp_column text, model_table text, cluster_table text, threshold float DEFAULT 0.7, overwrite_cluster_table boolean DEFAULT FALSE)
    RETURNS VOID
    AS $$
DECLARE
    table_exists boolean;
    get_documents_query text;
    get_closest_cluster_query text;
    document_text text;
    closest_cluster_id integer;
    min_distance float;
BEGIN
    -- Check if cluster_table exists
    SELECT
        EXISTS (
            SELECT
            FROM
                information_schema.tables
            WHERE
                table_schema = current_schema()
                AND table_name = cluster_table) INTO table_exists;
    -- If table exists, handle based on overwrite parameter
    IF table_exists THEN
        IF overwrite_cluster_table THEN
            -- Delete all rows from existing table
            EXECUTE format('DELETE FROM %I', cluster_table);
        ELSE
            -- Raise error if overwrite is false and table exists
            RAISE EXCEPTION 'Table % already exists. Set overwrite_cluster_table=true to delete existing rows.', cluster_table;
        END IF;
    ELSE
        -- Create the output table if it doesn't exist
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I (
        id SERIAL PRIMARY KEY,
        centroid TEXT
    )', cluster_table);
    END IF;
    -- Build dynamic query to retrieve documents one by one in their chronological order
    get_documents_query := format('SELECT %I FROM %I ORDER BY %I', text_column, input_table, timestamp_column);
    -- Start the clustering process
    -- Loop through the documents
    FOR document_text IN EXECUTE get_documents_query LOOP
        -- Build the query to get the closest cluster
        get_closest_cluster_query := format('SELECT 
            id,
            cls_cosine_distance(%s) AS distance
            FROM %I
            ORDER BY distance ASC LIMIT 1', document_text, cluster_table);
        -- Execute the query to get the closest cluster
        EXECUTE get_closest_cluster_query INTO closest_cluster_id;
        -- Raise notice to debug
        RAISE NOTICE 'closest_cluster_id: %', closest_cluster_id;
        IF closest_cluster_id IS NULL THEN
            RAISE NOTICE 'closest_cluster_id is NULL';
            END IF;
        END LOOP;

            -- Create new cluster
            -- EXECUTE format('INSERT INTO %I(centroid)
            -- VALUES (document_text)
            -- RETURNING id INTO new_cluster_id;', cluster_table);
            --     new_cluster_id := cls_
            --     create_new_cluster(output_table);
            --     INSERT INTO clusters(cluster_centroid, document_count, created_at)
            --         VALUES (doc_record.text_content, 1, CURRENT_TIMESTAMP)
            --     RETURNING
            --         cluster_id INTO new_cluster_id;
            -- Insert new cluster into output table
            -- Insert document into new cluster
            -- Update cluster document count and centroid
            -- Update cluster updated_at
            -- Update cluster updated_at
            -- ELSE
            -- Add to existing cluster
            -- Insert document into existing cluster
            -- Update cluster document count and centroid
            -- Update cluster updated_at
            -- Update cluster updated_at
        /* #########################################################
         End of finding the closest cluster
         ######################################################### */
        /* #########################################################
         End of the clustering process
         ######################################################### */
        --         ELSE
        --             -- Add to existing cluster
        --             INSERT INTO document_clusters (document_id, cluster_id, distance, assigned_at)
        --             VALUES (doc_record.document_id, closest_cluster_id, min_distance, CURRENT_TIMESTAMP)
        --             ON CONFLICT (document_id) DO UPDATE SET
        --                 cluster_id = EXCLUDED.cluster_id,
        --                 distance = EXCLUDED.distance,
        --                 assigned_at = EXCLUDED.assigned_at;
        --             -- Update cluster document count and centroid
        --             UPDATE clusters
        --             SET document_count = document_count + 1,
        --                 cluster_centroid = compute_cluster_centroid(closest_cluster_id),
        --                 updated_at = CURRENT_TIMESTAMP
        --             WHERE cluster_id = closest_cluster_id;
        --             added_to_existing_count := added_to_existing_count + 1;
        --         END IF;
        -- Execute the dynamic query
        -- EXECUTE dynamic_query;
        /* #########################################################
         Return results
         ######################################################### */
        -- RETURN QUERY
        -- SELECT
        --     processed_count,
        --     created_count,
        --     added_to_existing_count,
        --     new_cluster_count;
END;
$$
LANGUAGE plpgsql;


/* #########################################################
Input: document_text - the text of the document
 Input: cluster_table - the table where the clusters are stored
 Output: cluster_id - the id of the closest cluster
 Output: distance - the distance (similarity) between the document and the cluster
 ######################################################### */
-- CREATE OR REPLACE FUNCTION cls_get_closest_cluster(document_text text, cluster_table text, OUT cluster_id integer, OUT distance float)
-- AS $$
-- DECLARE
--     get_closest_cluster_query text;
-- BEGIN
--     get_closest_cluster_query := format('SELECT id 
--         FROM %I', cluster_table);
--     EXECUTE get_closest_cluster_query INTO cluster_id,
--     distance;
-- END;
-- $$
-- LANGUAGE plpgsql;


/* #########################################################
-- Function to compute cosine distance between a text and a cluster centroid
 ######################################################### */
CREATE OR REPLACE FUNCTION cls_cosine_distance(txt_content text)
    RETURNS float
    AS $$
DECLARE
    distance float;
BEGIN
    -- build a tf-idf vector for the text
    tfidf_vector := cls_get_tfidf_vector(txt_content);
    -- Get cluster centroid
    SELECT
        centroid INTO cluster_centroid
    FROM
        clusters
    WHERE
        clusters.cluster_id = cluster_id;
    -- If no centroid, return maximum distance
    IF cluster_centroid IS NULL THEN
        RETURN NULL;
    END IF;
    -- Compute cosine distance (1 - similarity)
    distance := compute_cosine_distance(document_text, cluster_centroid);
    -- Return cosine distance (1 - similarity)
    RETURN distance;
END;
$$
LANGUAGE plpgsql;

-- Function to compute cluster centroid from documents in cluster
CREATE OR REPLACE FUNCTION compute_cluster_centroid(cluster_id integer)
    RETURNS text
    AS $$
DECLARE
    centroid_terms text;
BEGIN
    -- Aggregate all terms from documents in cluster (simplified approach)
    SELECT
        string_agg(DISTINCT unnest(string_to_array(lower(d.text_column), ' ')), ' ') INTO centroid_terms
    FROM
        document_clusters dc
        JOIN documents d ON dc.document_id = d.document_id
    WHERE
        dc.cluster_id = cluster_id;
    RETURN centroid_terms;
END;
$$
LANGUAGE plpgsql;

-- Function to compute cosine similarity between two documents
-- CREATE OR REPLACE FUNCTION compute_cosine_similarity(doc1 text, doc2 text)
--     RETURNS float
--     AS $$
-- DECLARE
--     terms1 text[];
--     terms2 text[];
--     all_terms text[];
--     term text;
--     tfidf1 float;
--     tfidf2 float;
--     dot_product float := 0.0;
--     norm1 float := 0.0;
--     norm2 float := 0.0;
-- BEGIN
--     -- Get unique terms from both documents
--     terms1 := ARRAY ( SELECT DISTINCT
--             unnest(string_to_array(lower(doc1), ' ')));
--     terms2 := ARRAY ( SELECT DISTINCT
--             unnest(string_to_array(lower(doc2), ' ')));
--     -- Combine all unique terms
--     all_terms := ARRAY ( SELECT DISTINCT
--             unnest(terms1 || terms2));
--     -- Compute cosine similarity
--     FOREACH term IN ARRAY all_terms LOOP
--         tfidf1 := compute_tfidf(doc1, term);
--         tfidf2 := compute_tfidf(doc2, term);
--         dot_product := dot_product +(tfidf1 * tfidf2);
--         norm1 := norm1 +(tfidf1 * tfidf1);
--         norm2 := norm2 +(tfidf2 * tfidf2);
--     END LOOP;
--     -- Avoid division by zero
--     IF norm1 = 0.0 OR norm2 = 0.0 THEN
--         RETURN 0.0;
--     END IF;
--     -- Return cosine similarity
--     RETURN dot_product /(sqrt(norm1) * sqrt(norm2));
-- END;
-- $$
-- LANGUAGE plpgsql;
-- /* #########################################################
--  Create necessary clustering tables
--  ######################################################### */
-- -- Create necessaryclustering tables
-- CREATE OR REPLACE FUNCTION create_necessary_clustering_tables()
--     RETURNS VOID
--     AS $$
-- BEGIN
--     PERFORM
--         create_clusters_table();
--     PERFORM
--         create_document_clusters_table();
-- END;
-- $$
-- LANGUAGE plpgsql;
-- Create document-cluster assignments table
-- CREATE OR REPLACE FUNCTION create_cluster_assignment_table()
--     RETURNS VOID
--     AS $$
-- BEGIN
--     CREATE TABLE IF NOT EXISTS CLUSTER(
--         document_id text,
--         cluster_id integer,
--         assigned_at timestamp DEFAULT CURRENT_TIMESTAMP,
--         PRIMARY KEY(document_id ),
--         FOREIGN KEY(cluster_id ) REFERENCES clusters(cluster_id ) ON DELETE CASCADE
--     );
-- END;
-- $$
-- LANGUAGE plpgsql;
-- -- Alternative simpler implementation for incremental clustering
-- CREATE OR REPLACE FUNCTION incremental_cluster_simple(input_table_name text, text_column_name text, timestamp_column_name text, distance_threshold float DEFAULT 0.7)
--     RETURNS VOID
--     AS $$
-- DECLARE
--     doc_record RECORD;
--     closest_cluster_id integer;
--     min_distance float;
--     new_cluster_id integer;
--     dynamic_query text;
-- BEGIN
--     -- Build dynamic query to process documents one by one
--     dynamic_query := format( '
--         FOR doc_record IN
--             SELECT document_id, %I as text_content, %I as doc_timestamp
--             FROM %I
--             ORDER BY %I
--         LOOP
--             -- Update TF-IDF statistics for this document
--             PERFORM update_tfidf_stats(doc_record.text_content);
--             -- Find closest cluster
--             SELECT cluster_id, distance
--             INTO closest_cluster_id, min_distance
--             FROM find_closest_cluster(doc_record.text_content);
--             -- Check if document should be added to existing cluster or create new one
--             IF closest_cluster_id IS NULL OR min_distance > distance_threshold THEN
--                 -- Create new cluster
--                 INSERT INTO clusters (cluster_centroid, document_count, created_at)
--                 VALUES (doc_record.text_content, 1, CURRENT_TIMESTAMP)
--                 RETURNING cluster_id INTO new_cluster_id;
--                 -- Assign document to new cluster
--                 INSERT INTO document_clusters (document_id, cluster_id, distance, assigned_at)
--                 VALUES (doc_record.document_id, new_cluster_id, COALESCE(min_distance, 1.0), CURRENT_TIMESTAMP)
--                 ON CONFLICT (document_id) DO UPDATE SET
--                     cluster_id = EXCLUDED.cluster_id,
--                     distance = EXCLUDED.distance,
--                     assigned_at = EXCLUDED.assigned_at;
--             ELSE
--                 -- Add to existing cluster
--                 INSERT INTO document_clusters (document_id, cluster_id, distance, assigned_at)
--                 VALUES (doc_record.document_id, closest_cluster_id, min_distance, CURRENT_TIMESTAMP)
--                 ON CONFLICT (document_id) DO UPDATE SET
--                     cluster_id = EXCLUDED.cluster_id,
--                     distance = EXCLUDED.distance,
--                     assigned_at = EXCLUDED.assigned_at;
--                 -- Update cluster statistics
--                 UPDATE clusters
--                 SET document_count = document_count + 1,
--                     cluster_centroid = compute_cluster_centroid(closest_cluster_id),
--                     updated_at = CURRENT_TIMESTAMP
--                 WHERE cluster_id = closest_cluster_id;
--             END IF;
--         END LOOP;
--     '
-- , text_column_name, timestamp_column_name, input_table_name, timestamp_column_name);
--     -- Execute the dynamic query
--     EXECUTE dynamic_query;
-- END;
-- $$
-- LANGUAGE plpgsql;
-- -- Function to get clustering results
-- CREATE OR REPLACE FUNCTION get_clustering_results()
--     RETURNS TABLE(
--         cluster_id integer,
--         cluster_centroid text,
--         document_count integer,
--         documents text[],
--         created_at timestamp,
--         updated_at timestamp
--     )
--     AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT
--         c.cluster_id,
--         c.cluster_centroid,
--         c.document_count,
--         ARRAY_AGG(dc.document_id ORDER BY dc.assigned_at) AS documents,
--         c.created_at,
--         c.updated_at
--     FROM
--         clusters c
--         LEFT JOIN document_clusters dc ON c.cluster_id = dc.cluster_id
--     GROUP BY
--         c.cluster_id,
--         c.cluster_centroid,
--         c.document_count,
--         c.created_at,
--         c.updated_at
--     ORDER BY
--         c.created_at;
-- END;
-- $$
-- LANGUAGE plpgsql;
-- -- Function to clear clustering data
-- CREATE OR REPLACE FUNCTION clear_clustering_data()
--     RETURNS VOID
--     AS $$
-- BEGIN
--     DELETE FROM document_clusters;
--     DELETE FROM clusters;
--     DELETE FROM tfidf_stats;
--     -- ALTER SEQUENCE clusters_cluster_id_seq RESTART WITH 1;
-- END;
-- $$
-- LANGUAGE plpgsql;
