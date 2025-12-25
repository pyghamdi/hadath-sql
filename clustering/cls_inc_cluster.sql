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
    row_number integer := 1;
    current_centroid tfidf_term_weight[];
    updated_centroid tfidf_term_weight[];
BEGIN
    -- Create or manage the output cluster table
    PERFORM
        cls_create_cluster_table(output_cluster_table, overwrite_output_cluster_table);
    -- Build dynamic query to retrieve documents one by one in their chronological order
    get_documents_query := format('SELECT %I FROM %I ORDER BY %I', text_column, input_table, timestamp_column);
    -- Start the clustering process
    -- Loop through the documents
    FOR content IN EXECUTE get_documents_query LOOP
        RAISE NOTICE 'Processing document number %', row_number;
        row_number := row_number + 1;
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
                current_centroid := cluster_record.centroid;
            END IF;
        END LOOP;
        -- Raise notice to debug
        RAISE NOTICE 'nearest_cluster_id: %, distance: %', nearest_cluster_id, min_distance;
        -- Check if we should create a new cluster or add to existing one
        IF nearest_cluster_id IS NULL OR (min_distance IS NOT NULL AND min_distance > threshold) THEN
            RAISE NOTICE 'Creating a new cluster';
            -- Create a new cluster with the content vector as centroid
            EXECUTE format('INSERT INTO %I (centroid) VALUES ($1)', output_cluster_table)
            USING content_vector;
        ELSE
            RAISE NOTICE 'Adding to existing cluster % with distance %', nearest_cluster_id, min_distance;
            -- Get the current centroid
            -- EXECUTE format('SELECT centroid FROM %I WHERE id = $1', output_cluster_table)
            -- USING nearest_cluster_id INTO current_centroid;
            -- Update centroid to include this document
            updated_centroid := cls_update_centroid(current_centroid, content_vector);
            -- Update the cluster centroid in the database
            EXECUTE format('UPDATE %I SET centroid = $1 WHERE id = $2', output_cluster_table)
            USING updated_centroid, nearest_cluster_id;
        END IF;
        END LOOP;
            RAISE NOTICE 'Clustering process completed. Total documents processed: %', row_number;
END;
$$
LANGUAGE plpgsql;


/* #########################################################
Function to get all unique terms from two vectors
Input: vector1 - the first vector (tfidf_term_weight[])
Input: vector2 - the second vector (tfidf_term_weight[])
Output: all_terms - array of all unique terms from both vectors (text[])
######################################################### */
CREATE OR REPLACE FUNCTION cls_get_all_terms(vector1 tfidf_term_weight[], vector2 tfidf_term_weight[])
    RETURNS text[]
    AS $$
DECLARE
    all_terms text[];
BEGIN
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
    RETURN all_terms;
END;
$$
LANGUAGE plpgsql;


/* #########################################################
Function to update centroid by merging with a new document vector
Input: current_centroid - the current cluster centroid (tfidf_term_weight[])
Input: new_vector - the new document vector to merge (tfidf_term_weight[])
Output: updated_centroid - the updated centroid with merged terms (tfidf_term_weight[])
 The function computes the average weight for each term across both vectors
######################################################### */
CREATE OR REPLACE FUNCTION cls_update_centroid(current_centroid tfidf_term_weight[], new_vector tfidf_term_weight[])
    RETURNS tfidf_term_weight[]
    AS $$
DECLARE
    updated_centroid tfidf_term_weight[];
    all_terms text[];
    term_item text;
    centroid_weight float;
    new_weight float;
    avg_weight float;
    term_weight tfidf_term_weight;
BEGIN
    -- Check if inputs are valid
    IF current_centroid IS NULL OR array_length(current_centroid, 1) IS NULL THEN
        RETURN new_vector;
    END IF;
    IF new_vector IS NULL OR array_length(new_vector, 1) IS NULL THEN
        RETURN current_centroid;
    END IF;
    -- Build a set of all unique terms from both vectors
    all_terms := cls_get_all_terms(current_centroid, new_vector);
    -- Initialize empty array
    updated_centroid := ARRAY[]::tfidf_term_weight[];
    -- Compute average weight for each term
    FOREACH term_item IN ARRAY all_terms LOOP
        -- Get weight from current centroid (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector_item).weight FROM unnest(current_centroid) AS vector_item
                WHERE (vector_item).term = term_item LIMIT 1), 0.0) INTO centroid_weight;
        -- Get weight from new vector (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector_item).weight FROM unnest(new_vector) AS vector_item
                WHERE (vector_item).term = term_item LIMIT 1), 0.0) INTO new_weight;
        -- Compute average weight
        avg_weight :=(centroid_weight + new_weight) / 2.0;
        -- Only include terms with non-zero weight
        IF avg_weight > 0.0 THEN
            term_weight := ROW (term_item,
                avg_weight)::tfidf_term_weight;
            updated_centroid := array_append(updated_centroid, term_weight);
        END IF;
    END LOOP;
    RETURN updated_centroid;
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
    all_terms := cls_get_all_terms(vector1, vector2);
    -- Compute dot product and norms for cosine similarity
    FOREACH term_item IN ARRAY all_terms LOOP
        -- Get weight for this term in vector1 (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector1_item).weight FROM unnest(vector1) AS vector1_item
                WHERE (vector1_item).term = term_item LIMIT 1), 0.0) INTO vector1_term_weight;
        -- Get weight for this term in vector2 (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector2_item).weight FROM unnest(vector2) AS vector2_item
                WHERE (vector2_item).term = term_item LIMIT 1), 0.0) INTO vector2_term_weight;
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

-- Create document-cluster assignments table
-- CREATE OR REPLACE FUNCTION create_cluster_assignment_table()
--     RETURNS VOID
--     AS $$
-- BEGIN
--     CREATE TABLE IF NOT EXISTS CLUSTER(
--         document_id text,
--         cluster_id integer,
--         PRIMARY KEY(document_id ),
--         FOREIGN KEY(cluster_id ) REFERENCES clusters(cluster_id ) ON DELETE CASCADE
--     );
-- END;
-- $$
-- LANGUAGE plpgsql;

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
