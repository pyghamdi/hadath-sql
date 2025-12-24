-- PostgreSQL Incremental Clustering Function
-- Implements TF-IDF based incremental clustering with cosine similarity
-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS plpgsql;


/* #########################################################
Function to create or manage the output cluster table
Input: output_cluster_table - the name of the table to store clusters
Input: overwrite_output_cluster_table - whether to overwrite the table if it exists (TRUE) or raise an error (FALSE)
Output: void - creates or manages the table
######################################################### */
CREATE OR REPLACE FUNCTION cls_create_cluster_table(output_cluster_table text, overwrite_output_cluster_table boolean DEFAULT FALSE)
    RETURNS VOID
    AS $$
DECLARE
    table_exists boolean;
BEGIN
    -- Check if output_cluster_table exists
    RAISE NOTICE 'Checking if table % exists', output_cluster_table;
    SELECT
        EXISTS (
            SELECT
            FROM
                information_schema.tables
            WHERE
                table_schema = current_schema()
                AND table_name = output_cluster_table) INTO table_exists;
    -- If output_cluster_table exists, handle based on overwrite_output_cluster_table parameter
    IF table_exists THEN
        RAISE NOTICE 'Table % exists.', output_cluster_table;
        IF overwrite_output_cluster_table THEN
            -- Drop the table if it exists
            RAISE NOTICE 'Dropping the table %', output_cluster_table;
            EXECUTE format('DROP TABLE IF EXISTS %I', output_cluster_table);
        ELSE
            -- Raise error if overwrite_output_cluster_table is false and table exists
            RAISE EXCEPTION 'Table % already exists. Set overwrite_output_cluster_table=true to drop the table.', output_cluster_table;
        END IF;
    END IF;
    -- Create the output_cluster_table if it doesn't exist
    RAISE NOTICE 'Creating the table %', output_cluster_table;
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I (
        id SERIAL PRIMARY KEY,
        centroid tfidf_term_weight[]
    )', output_cluster_table);
END;
$$
LANGUAGE plpgsql;


/* #########################################################
 Incremental clustering function using TF-IDF and cosine similarity
 Input: input_table - the table of text documents
 Input: text_column - the column containing the text of the documents
 Input: timestamp_column - the column containing the creation time of the documents
 Input: distance_threshold - the threshold for the distance between the document and the cluster centroid
 Input: model_table - the table storing model metadata
 Input: cluster_table - the table to store clusters 
 Input: overwrite_output_cluster_table - whether to overwrite the output cluster table if it exists or raise an error if the overwrite is false and the table exists
 Output: void - the function does not return any value
 ######################################################### */
CREATE OR REPLACE FUNCTION cls_incremental_clustering(input_table text, text_column text, timestamp_column text, model_table text, output_cluster_table text, threshold float DEFAULT 0.7, overwrite_output_cluster_table boolean DEFAULT FALSE)
    RETURNS VOID
    AS $$
DECLARE
    get_documents_query text;
    content text;
    content_vector tfidf_term_weight[];
    cluster_record RECORD;
    nearest_cluster_id integer;
    min_distance float;
    current_distance float;
BEGIN
    -- Create or manage the output cluster table
    PERFORM
        cls_create_cluster_table(output_cluster_table, overwrite_output_cluster_table);
    -- Build dynamic query to retrieve documents one by one in their chronological order
    get_documents_query := format('SELECT %I FROM %I ORDER BY %I', text_column, input_table, timestamp_column);
    -- Start the clustering process
    -- Loop through the documents
    FOR content IN EXECUTE get_documents_query LOOP
        -- Vectorize the content once
        content_vector := tfidf_vectorize(content, model_table);
        -- Initialize variables for finding nearest cluster
        nearest_cluster_id := NULL;
        min_distance := NULL;
        -- Loop through all clusters to find the nearest one
        FOR cluster_record IN EXECUTE format('SELECT id, centroid FROM %I', output_cluster_table)
        LOOP
            -- Compute cosine distance between content vector and cluster centroid
            current_distance := cls_cosine_distance(content_vector, cluster_record.centroid);
            -- Update nearest cluster if this is closer (or first cluster)
            IF current_distance IS NOT NULL AND (min_distance IS NULL OR current_distance < min_distance) THEN
                min_distance := current_distance;
                nearest_cluster_id := cluster_record.id;
            END IF;
        END LOOP;
        -- Raise notice to debug
        RAISE NOTICE 'content: %, nearest_cluster_id: %, distance: %', content, nearest_cluster_id, min_distance;
        -- Check if we should create a new cluster or add to existing one
        IF nearest_cluster_id IS NULL OR (min_distance IS NOT NULL AND min_distance > threshold) THEN
            RAISE NOTICE 'Creating a new cluster';
            -- Create a new cluster with the content vector as centroid
            EXECUTE format('INSERT INTO %I (centroid) VALUES ($1)', output_cluster_table)
            USING content_vector;
        ELSE
            RAISE NOTICE 'Adding to existing cluster % with distance %', nearest_cluster_id, min_distance;
            -- TODO: Update cluster centroid to include this document
            -- For now, we just note that the document belongs to this cluster
        END IF;
        END LOOP;
END;
$$
LANGUAGE plpgsql;


/* #########################################################
Function to compute cosine distance between two vectors: vector1 and vector2
Input: vector1 - the first vector (tfidf_term_weight[])
Input: vector2 - the second vector (tfidf_term_weight[])
Output: distance - the cosine distance between the two vectors
 Cosine distance = 1 - cosine_similarity
 Returns NULL if vector1 or vector2 is NULL or empty
 ######################################################### */
CREATE OR REPLACE FUNCTION cls_cosine_distance(vector1 tfidf_term_weight[], vector2 tfidf_term_weight[])
    RETURNS float
    AS $$
DECLARE
    distance float;
    cosine_similarity float;
    dot_product float := 0.0;
    norm_vector1 float := 0.0;
    norm_vector2 float := 0.0;
    vector1_term_weight float;
    vector2_term_weight float;
    all_terms text[];
    term_item text;
BEGIN
    -- Check if vector1 is NULL or empty
    IF vector1 IS NULL OR array_length(vector1, 1) IS NULL THEN
        RETURN NULL;
    END IF;
    -- Check if vector2 is NULL or empty
    IF vector2 IS NULL OR array_length(vector2, 1) IS NULL THEN
        RETURN NULL;
    END IF;
    -- Build a set of all unique terms from both vectors
    SELECT
        array_agg(DISTINCT term) INTO all_terms
    FROM (
        SELECT
            (vector1_item).term
        FROM
            unnest(vector1) AS vector1_item
        UNION
        SELECT
            (vector2_item).term
        FROM
            unnest(vector2) AS vector2_item);
    -- Compute dot product and norms for cosine similarity
    FOREACH term_item IN ARRAY all_terms LOOP
        -- Get weight for this term in vector1 (0 if not present)
        SELECT
            COALESCE(
                (SELECT (vector1_item).weight
                 FROM unnest(vector1) AS vector1_item
                 WHERE (vector1_item).term = term_item
                 LIMIT 1),
                0.0
            ) INTO vector1_term_weight;
        -- Get weight for this term in vector2 (0 if not present)
        SELECT
            COALESCE(
                (SELECT (vector2_item).weight
                 FROM unnest(vector2) AS vector2_item
                 WHERE (vector2_item).term = term_item
                 LIMIT 1),
                0.0
            ) INTO vector2_term_weight;
        -- Accumulate dot product and norms
        dot_product := dot_product +(vector1_term_weight * vector2_term_weight);
        norm_vector1 := norm_vector1 +(vector1_term_weight * vector1_term_weight);
        norm_vector2 := norm_vector2 +(vector2_term_weight * vector2_term_weight);
    END LOOP;
    -- Compute cosine similarity
    -- Avoid division by zero
    IF norm_vector1 = 0.0 OR norm_vector2 = 0.0 THEN
        RETURN 1.0;
        -- Maximum distance if one vector has zero norm
    END IF;
    cosine_similarity := dot_product /(sqrt(norm_vector1) * sqrt(norm_vector2));
    -- Compute cosine distance (1 - similarity)
    distance := 1.0 - cosine_similarity;
    -- Return cosine distance
    RETURN distance;
END;
$$
LANGUAGE plpgsql;

-- Function to compute cluster centroid from documents in cluster
-- CREATE OR REPLACE FUNCTION compute_cluster_centroid(cluster_id integer)
--     RETURNS text
--     AS $$
-- DECLARE
--     centroid_terms text;
-- BEGIN
--     -- Aggregate all terms from documents in cluster (simplified approach)
--     SELECT
--         string_agg(DISTINCT unnest(string_to_array(lower(d.text_column), ' ')), ' ') INTO centroid_terms
--     FROM
--         document_clusters dc
--         JOIN documents d ON dc.document_id = d.document_id
--     WHERE
--         dc.cluster_id = cluster_id;
--     RETURN centroid_terms;
-- END;
-- $$
-- LANGUAGE plpgsql;
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
