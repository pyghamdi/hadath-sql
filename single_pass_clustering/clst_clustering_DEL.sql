-- Drop all clst functions and type (ensures clean re-run)
DROP FUNCTION IF EXISTS clst_single_pass_clustering(text, text, text, text, text, text, float) CASCADE;
DROP FUNCTION IF EXISTS clst_create_cluster_table(text, boolean) CASCADE;
DROP FUNCTION IF EXISTS clst_create_doc_cluster_assign(text, text, boolean) CASCADE;
DROP FUNCTION IF EXISTS clst_get_all_terms(tfidf_weight[], tfidf_weight[]) CASCADE;
DROP FUNCTION IF EXISTS clst_cosine_sim(tfidf_weight[], tfidf_weight[]) CASCADE;
DROP FUNCTION IF EXISTS clst_update_centroid(tfidf_weight[], tfidf_weight[]) CASCADE;


/* #########################################################
clst_create_cluster_table
--------------------------------------------------------------------------------
Creates a cluster storage table, or optionally drops and recreates it.

Parameters:
  output_tbl           - Unqualified table name (used with %I); table will have
                         id SERIAL PRIMARY KEY and centroid tfidf_weight[].
  overwrite_output_tbl - If FALSE and the table already exists, raises an exception.
                         If TRUE and the table exists, drops it then creates a new empty table.

Returns: void

Uses hsql_table_exists_any_schema.
######################################################### */
CREATE OR REPLACE FUNCTION clst_create_cluster_table(output_tbl text, overwrite_output_tbl boolean DEFAULT FALSE)
    RETURNS VOID AS $$
BEGIN
    -- Check if the output table exists
    IF hsql_table_exists_any_schema(output_tbl) AND NOT overwrite_output_tbl THEN
        RAISE EXCEPTION 'Table % already exists. Set overwrite_output_tbl=TRUE to overwrite the table.', output_tbl;
    ELSEIF hsql_table_exists_any_schema(output_tbl) AND overwrite_output_tbl THEN
        RAISE NOTICE 'Table % already exists. Dropping the table.', output_tbl;
        -- CASCADE removes dependent doc_cluster_assign tables (FK to this table).
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', output_tbl);
    END IF;
    -- Create the output table if it doesn't exist
    RAISE NOTICE 'Creating the output table %', output_tbl;
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I (
        id SERIAL PRIMARY KEY,
        centroid tfidf_weight[]
    )', output_tbl);
END;
$$
LANGUAGE plpgsql;


/* #########################################################
clst_create_doc_cluster_assign
--------------------------------------------------------------------------------
Creates the document→cluster assignment table, or optionally drops and recreates it.
Must run after clst_create_cluster_table so the referenced cluster table exists.

Schema: doc_id (PK), cls_id (FK → cluster_tbl.id ON DELETE CASCADE).

Parameters:
  doc_cluster_assign_tbl      - Unqualified table name for assignments (use %I).
  cluster_tbl                 - Existing cluster table (must have id SERIAL PK).
  overwrite_doc_cluster_assign - If FALSE and the assignment table already exists,
                                raises an exception. If TRUE, drops it first then creates.

Returns: void

Uses hsql_table_exists_any_schema.
######################################################### */
CREATE OR REPLACE FUNCTION clst_create_doc_cluster_assign(
    doc_cluster_assign_tbl text,
    cluster_tbl text,
    overwrite_doc_cluster_assign_tbl boolean DEFAULT FALSE
)
    RETURNS VOID AS $$
BEGIN
    IF NOT hsql_table_exists_any_schema(cluster_tbl) THEN
        RAISE EXCEPTION 'Cluster table % does not exist. Create it with clst_create_cluster_table first.', cluster_tbl;
    END IF;

    IF hsql_table_exists_any_schema(doc_cluster_assign_tbl) AND NOT overwrite_doc_cluster_assign_tbl THEN
        RAISE EXCEPTION 'Table % already exists. Set overwrite_doc_cluster_assign_tbl=TRUE to overwrite the table.', doc_cluster_assign_tbl;
    ELSIF hsql_table_exists_any_schema(doc_cluster_assign_tbl) AND overwrite_doc_cluster_assign_tbl THEN
        RAISE NOTICE 'Table % already exists. Dropping the table.', doc_cluster_assign_tbl;
        EXECUTE format('DROP TABLE IF EXISTS %I', doc_cluster_assign_tbl);
    END IF;

    RAISE NOTICE 'Creating the document-cluster assignment table %', doc_cluster_assign_tbl;
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            doc_id integer PRIMARY KEY,
            cls_id integer NOT NULL,
            FOREIGN KEY (cls_id) REFERENCES %I (id) ON DELETE CASCADE
        )',
        doc_cluster_assign_tbl,
        cluster_tbl
    );
END;
$$
LANGUAGE plpgsql;


/* #########################################################
clst_single_pass_clustering
--------------------------------------------------------------------------------
Single-pass online clustering over documents ordered by time. Each document is
represented by a sparse TF-IDF vector read from tfidf_tbl (via tfidf_get_vector).

Behavior:
  - Ensures tfidf_tbl exists; creates or overwrites output_tbl (see clst_create_cluster_table)
    and the document–cluster assignment table (see clst_create_doc_cluster_assign).
  - Assignment table name is output_tbl || '_doc_cluster_assign' (doc_id → cls_id → cluster id).
  - Loads doc ids from input_tbl in chronological order (ORDER BY ts_col).
  - First document seeds the first cluster (centroid = that document's vector).
  - For each later document: finds the cluster with highest cosine similarity between
    the document vector and existing centroids. If similarity >= threshold, merges the
    document into that cluster by averaging per-term weights (clst_update_centroid);
    otherwise inserts a new cluster row.

Parameters:
  input_tbl            - Source table containing documents (quoted identifier).
  doc_id_col           - Column name for document id (integer-compatible); used in SELECT.
  ts_col               - Column name used to order documents (e.g. creation time).
  output_tbl           - Table to create/hold clusters: columns id SERIAL, centroid tfidf_weight[].
  tfidf_tbl            - TF-IDF model table (doc_id, term, tf_idf) for tfidf_get_vector.
  threshold            - Minimum cosine similarity (0..1) to assign a document to an
                         existing cluster instead of opening a new one.
  overwrite_output_tbl - If TRUE, drops and recreates output_tbl if it already exists;
                         if FALSE and the table exists, raises an exception.

Returns: void

Requires: hsql_table_exists_any_schema, tfidf_get_vector, clst_cosine_sim, clst_update_centroid,
           clst_create_cluster_table, clst_create_doc_cluster_assign (same file or loaded earlier).
######################################################### */
CREATE OR REPLACE FUNCTION clst_single_pass_clustering(
    input_tbl text,
    doc_id_col text,
    ts_col text, -- creation timestamp column
    output_tbl text, -- output table name (id, centroid)
    tfidf_tbl text, -- TF-IDF model table name (doc_id, term, tf_idf)
    threshold float DEFAULT 0.7, -- similarity threshold between document and cluster centroid
    overwrite_output_tbl boolean DEFAULT FALSE -- whether to overwrite the output table if it exists or raise an error if the overwrite is false and the table exists
)
RETURNS VOID AS $$
DECLARE
    retrieve_documents_query text; -- query to retrieve documents one by one in their chronological order
    doc_id integer; -- document id
    doc_tfidf_vector tfidf_weight[]; -- TF-IDF vector of the document
    -- cluster_centroid tfidf_weight[]; -- centroid of the cluster
    most_similar_cluster_id integer; -- ID of the most similar cluster
    max_similarity float; -- maximum cosine similarity between the document and the cluster centroid
    current_centroid tfidf_weight[]; -- centroid row when updating an existing cluster
    doc_count integer := 0; -- document count
    cluster_count integer := 0; -- cluster count
    cluster_assignments_tbl text; -- output_tbl || '_doc_cluster_assign'
    assigned_cluster_id integer; -- cluster id for current document (for assignment row)
BEGIN
    /*
    Check if the tfidf_tbl exists
    */
    IF NOT hsql_table_exists_any_schema(tfidf_tbl) THEN
        RAISE EXCEPTION 'TF-IDF model table % does not exist. Please create the TF-IDF model table using the tfidf_create_model function first.', tfidf_tbl;
    END IF;

    /*
    Create or overwrite the output cluster table, then the doc↔cluster assignment table
    (parent must exist first; on overwrite the cluster drop uses CASCADE so a prior
    assignment table is removed with the cluster table).
    */
    PERFORM clst_create_cluster_table(output_tbl, overwrite_output_tbl);

    cluster_assignments_tbl := output_tbl || '_doc_cluster_assign';
    PERFORM clst_create_doc_cluster_assign(cluster_assignments_tbl, output_tbl, overwrite_output_tbl);
    
    -- Build dynamic query to retrieve documents one by one in their chronological order using the input table and timestamp column
    retrieve_documents_query := format('
        SELECT %I 
        FROM %I 
        ORDER BY %I
        ', doc_id_col, input_tbl, ts_col);
    
    RAISE NOTICE '########################################################';
    RAISE NOTICE 'Starting the clustering process...';
    RAISE NOTICE '########################################################';
    /*
    Loop document ids from retrieve_documents_query (chronological order). Per document:
    1. Load TF-IDF vector via tfidf_get_vector(doc_id, tfidf_tbl).
    2. If first document: insert a new cluster with that centroid.
       Else: pick the cluster with maximum cosine similarity; if >= threshold, average
       centroid with the document vector and UPDATE; otherwise INSERT a new cluster.
    */
    FOR doc_id IN EXECUTE retrieve_documents_query 
    LOOP -- step 1
        -- Step 1: Get the TF-IDF vector of the document using the document id and the TF-IDF model table.
        -- RAISE NOTICE 'Getting the TF-IDF vector';
        doc_tfidf_vector := tfidf_get_vector(doc_id, tfidf_tbl);
        
        -- Step 2: Find the most similar cluster by computing the cosine similarity between the TF-IDF vector of the document and the cluster centroids.
        
        -- 2.1: If this is the first document, skip the similarity computation and create a new cluster with the document TF-IDF vector as centroid
        IF doc_count = 0 THEN
            -- RAISE NOTICE 'Creating a new cluster with document id %', doc_id;
            EXECUTE format(
                'INSERT INTO %I (centroid) VALUES ($1) RETURNING id',
                output_tbl
            )
            USING doc_tfidf_vector
            INTO assigned_cluster_id;
            cluster_count := cluster_count + 1;
            EXECUTE format(
                'INSERT INTO %I (doc_id, cls_id) VALUES ($1, $2)',
                cluster_assignments_tbl
            )
            USING doc_id, assigned_cluster_id;
        ELSE
            -- 2.2: If this is not the first document, find the most similar cluster.
            -- RAISE NOTICE 'Finding the most similar cluster to document id %', doc_id;
            -- output_tbl is a table *name*; use dynamic SQL. INTO must follow the SELECT list.
            EXECUTE format(
                'SELECT id, clst_cosine_sim($1, centroid)
                 FROM %I
                 ORDER BY 2 DESC
                 LIMIT 1',
                output_tbl
            )
            INTO most_similar_cluster_id, max_similarity
            USING doc_tfidf_vector;
            -- RAISE NOTICE 'Most similar cluster id: %, maximum cosine similarity: %', most_similar_cluster_id, max_similarity;
        
            -- Step 3: test if similarity is greater than threshold and assign document to cluster or create a new one (first doc handled above only)
            IF max_similarity >= threshold THEN
                -- RAISE NOTICE 'Cosine similarity is equal or greater than threshold. Adding document % to cluster %', doc_id, most_similar_cluster_id;
                -- Add the document to the cluster
                -- Get the current centroid of the cluster
                EXECUTE format('SELECT centroid FROM %I WHERE id = $1', output_tbl)
                USING most_similar_cluster_id
                INTO current_centroid;
                -- Update the centroid with the document TF-IDF vector
                current_centroid := clst_update_centroid(current_centroid, doc_tfidf_vector);
                -- Update the cluster centroid in the database
                EXECUTE format('UPDATE %I SET centroid = $1 WHERE id = $2', output_tbl)
                USING current_centroid, most_similar_cluster_id;
                assigned_cluster_id := most_similar_cluster_id;
                EXECUTE format(
                    'INSERT INTO %I (doc_id, cls_id) VALUES ($1, $2)',
                    cluster_assignments_tbl
                )
                USING doc_id, assigned_cluster_id;
            ELSE
                -- RAISE NOTICE 'Cosine similarity is less than threshold. Creating a new cluster with document id %', doc_id;
                EXECUTE format(
                    'INSERT INTO %I (centroid) VALUES ($1) RETURNING id',
                    output_tbl
                )
                USING doc_tfidf_vector
                INTO assigned_cluster_id;
                cluster_count := cluster_count + 1;
                EXECUTE format(
                    'INSERT INTO %I (doc_id, cls_id) VALUES ($1, $2)',
                    cluster_assignments_tbl
                )
                USING doc_id, assigned_cluster_id;
            END IF;
        END IF;
        
        -- Increment the document number
        doc_count := doc_count + 1;
        
    END LOOP;
    RAISE NOTICE 'Clustering process completed. Total documents processed: %, total clusters created: %', doc_count, cluster_count;
END;
$$
LANGUAGE plpgsql;




/* #########################################################
clst_get_all_terms
--------------------------------------------------------------------------------
Returns the distinct set of term strings appearing in either sparse vector (union of
term dimensions). Used when aligning two tfidf_weight[] arrays for cosine similarity
or centroid averaging.

Parameters:
  vector1, vector2 - tfidf_weight[] arrays (may be NULL; callers typically guard).

Returns: text[] — distinct terms; may be NULL if the union subquery yields no rows
         (e.g. both inputs effectively empty of terms).
######################################################### */
CREATE OR REPLACE FUNCTION clst_get_all_terms(vector1 tfidf_weight[], vector2 tfidf_weight[])
    RETURNS text[]
    AS $$
DECLARE
    all_terms text[];
BEGIN
    SELECT array_agg(DISTINCT term) INTO all_terms
    FROM (
        SELECT (vector1_item).term AS term
        FROM unnest(vector1) AS vector1_item
        UNION
        SELECT (vector2_item).term AS term
        FROM unnest(vector2) AS vector2_item
    ) AS u;
    RETURN all_terms;
END;
$$
LANGUAGE plpgsql;


/* #########################################################
clst_cosine_sim
--------------------------------------------------------------------------------
Cosine similarity of two sparse tfidf_weight[] vectors over the union of their terms.
For each term, weights are taken from tf_idf; missing terms are treated as 0.

Parameters:
  vector1, vector2 - Sparse vectors as tfidf_weight[] (term, tf_idf).

Returns:
  float in [-1, 1] for typical non-negative TF-IDF weights (often [0, 1]).
  NULL if either argument is NULL or an empty array.
  0.0 if either vector has zero L2 norm (dot product path avoids division by zero).

Note: Vectors are interpreted in the full union of term dimensions (via clst_get_all_terms).
######################################################### */
CREATE OR REPLACE FUNCTION clst_cosine_sim(
    vector1 tfidf_weight[], 
    vector2 tfidf_weight[]
)
    RETURNS float
    AS $$
DECLARE
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
    all_terms := clst_get_all_terms(vector1, vector2);
    -- Compute dot product and norms for cosine similarity
    FOREACH term_item IN ARRAY all_terms LOOP
        -- Get weight for this term in vector1 (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector1_item).tf_idf 
                FROM unnest(vector1) AS vector1_item
                WHERE (vector1_item).term = term_item LIMIT 1), 0.0) 
        INTO vector1_term_weight;
        
        -- Get weight for this term in vector2 (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector2_item).tf_idf 
                FROM unnest(vector2) AS vector2_item
                WHERE (vector2_item).term = term_item LIMIT 1), 0.0) 
        INTO vector2_term_weight;
        
        -- Accumulate dot product and norms
        dot_product := dot_product + (vector1_term_weight * vector2_term_weight);
        norm_vector1 := norm_vector1 + (vector1_term_weight * vector1_term_weight);
        norm_vector2 := norm_vector2 + (vector2_term_weight * vector2_term_weight);
    END LOOP;
    -- Compute cosine similarity
    -- Avoid division by zero
    IF norm_vector1 = 0.0 OR norm_vector2 = 0.0 THEN
        RETURN 0.0;
        -- Minimum cosine similarity if one vector has zero norm
    END IF;
    cosine_similarity := dot_product / (sqrt(norm_vector1) * sqrt(norm_vector2));
    -- Return cosine similarity
    RETURN cosine_similarity;
END;
$$
LANGUAGE plpgsql;


/* #########################################################
clst_update_centroid
--------------------------------------------------------------------------------
Merges a cluster centroid with a new document vector by averaging tf_idf weights
per term over the union of terms. Terms absent from one side use weight 0 for that
side. Resulting terms with average weight > 0 are kept; zero averages are omitted.

Parameters:
  current_centroid - Existing centroid as tfidf_weight[]; if NULL or empty, returns new_vector.
  new_vector       - Document vector as tfidf_weight[]; if NULL or empty, returns current_centroid.

Returns: tfidf_weight[] — new sparse centroid (simple pairwise average per term, not
         a true incremental centroid count; suitable for small merges as implemented here).
######################################################### */
CREATE OR REPLACE FUNCTION clst_update_centroid(current_centroid tfidf_weight[], new_vector tfidf_weight[])
    RETURNS tfidf_weight[]
    AS $$
DECLARE
    updated_centroid tfidf_weight[];
    all_terms text[];
    term_item text;
    centroid_weight float;
    new_weight float;
    avg_weight float;
    term_weight tfidf_weight;
BEGIN
    -- Check if inputs are valid
    IF current_centroid IS NULL OR array_length(current_centroid, 1) IS NULL THEN
        RETURN new_vector;
    END IF;
    IF new_vector IS NULL OR array_length(new_vector, 1) IS NULL THEN
        RETURN current_centroid;
    END IF;
    -- Build a set of all unique terms from both vectors
    all_terms := clst_get_all_terms(current_centroid, new_vector);
    -- Initialize empty array
    updated_centroid := ARRAY[]::tfidf_weight[];
    -- Compute average weight for each term
    FOREACH term_item IN ARRAY all_terms LOOP
        -- Get weight from current centroid (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector_item).tf_idf FROM unnest(current_centroid) AS vector_item
                WHERE (vector_item).term = term_item LIMIT 1), 0.0) INTO centroid_weight;
        -- Get weight from new vector (0 if not present)
        SELECT
            COALESCE((
                SELECT
                    (vector_item).tf_idf FROM unnest(new_vector) AS vector_item
                WHERE (vector_item).term = term_item LIMIT 1), 0.0) INTO new_weight;
        -- Compute average weight
        avg_weight :=(centroid_weight + new_weight) / 2.0;
        -- Only include terms with non-zero weight
        IF avg_weight > 0.0 THEN
            term_weight := (term_item, avg_weight)::tfidf_weight;
            updated_centroid := array_append(updated_centroid, term_weight);
        END IF;
    END LOOP;
    RETURN updated_centroid;
END;
$$
LANGUAGE plpgsql;