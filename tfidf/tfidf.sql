-- Function to build a TF-IDF model from a collection of text documents.
-- Input: input_table - the table of document records
-- Input: text_column - the column containing the text of document records
-- Input: model_table - the table to store model metadata (term_document_frequency_table name and total_documents)
--                      The term_document_frequency_table will be named by appending "_tdf" to model_table name
-- Input: overwrite_model - whether to overwrite the existing model (term_document_frequency_table and model_table)
--                         if it exists (TRUE) or update it with new documents from the input table (FALSE)
CREATE OR REPLACE FUNCTION tfidf_build_model(input_table text, text_column text, model_table text, overwrite_model boolean DEFAULT FALSE)
    RETURNS VOID
    AS $$
DECLARE
    document_txt text;
    -- text of the document to iterate over
    term_document_frequency_table text;
    -- name of the term document frequency table (generated from model_table name)
    total_documents_count integer := 0;
    -- Count of documents processed
    existing_total_docs integer := 0;
BEGIN
    -- Generate the term document frequency table name by appending "_tdf" to model_table name
    term_document_frequency_table := model_table || '_tdf';
    -- Create the term document frequency table if it doesn't exist
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I (
        term TEXT PRIMARY KEY,
        document_count INTEGER DEFAULT 0
    )', term_document_frequency_table);
    -- Create the model table if it doesn't exist
    -- This table stores model metadata: term_document_frequency_table name and total_documents
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I (
        id INTEGER PRIMARY KEY DEFAULT 1,
        term_document_frequency_table TEXT NOT NULL,
        total_documents INTEGER DEFAULT 0,
        CONSTRAINT single_row CHECK (id = 1)
    )', model_table);
    -- If overwrite_model is TRUE, delete all rows from the document frequency table and reset model
    IF overwrite_model THEN
        EXECUTE format('DELETE FROM %I', term_document_frequency_table);
        EXECUTE format('DELETE FROM %I', model_table);
        RAISE NOTICE 'Deleted all rows from % table', term_document_frequency_table;
        RAISE NOTICE 'Reset model table %', model_table;
    ELSE
        -- Get existing total documents count if not overwriting
        EXECUTE format('SELECT COALESCE(total_documents, 0) FROM %I WHERE id = 1', model_table) INTO existing_total_docs;
        IF existing_total_docs IS NULL THEN
            existing_total_docs := 0;
        END IF;
        RAISE NOTICE 'Existing total documents in model % is %', model_table, existing_total_docs;
    END IF;
    -- Iterate over the documents in the input table and update the document frequency table
    FOR document_txt IN EXECUTE format('SELECT %I as text FROM %I', text_column, input_table)
    LOOP
        PERFORM
            tfidf_update_term_document_frequency(document_txt, term_document_frequency_table);
        -- Increment the count of documents processed
        total_documents_count := total_documents_count + 1;
    END LOOP;
    -- Update the model table with term_document_frequency_table name and total documents count
    total_documents_count := existing_total_docs + total_documents_count;
    EXECUTE format('INSERT INTO %I (id, term_document_frequency_table, total_documents) 
        VALUES (1, %L, %s)
        ON CONFLICT (id) 
        DO UPDATE SET term_document_frequency_table = %L, total_documents = %s;', model_table, term_document_frequency_table, total_documents_count, term_document_frequency_table, total_documents_count);
    RAISE NOTICE 'Processed % new rows.', total_documents_count - existing_total_docs;
    RAISE NOTICE 'Total documents in model % is %', model_table, total_documents_count;
END;
$$
LANGUAGE plpgsql;

-- Function to update term document frequency statistics when adding a document
CREATE OR REPLACE FUNCTION tfidf_update_term_document_frequency(document_txt text, term_document_frequency_table text)
    RETURNS VOID
    AS $$
DECLARE
    terms text[];
    term text;
    term_vector tsvector;
BEGIN
    -- Use to_tsvector to get the terms in the text and update their frequency in the document frequency table.
    terms := tsvector_to_array(to_tsvector('english', document_txt));
    FOREACH term IN ARRAY terms LOOP
        -- RAISE NOTICE 'Term: %', term;
        EXECUTE format('INSERT INTO %I (term, document_count) 
            VALUES (%L, 1)
            ON CONFLICT (term) 
            DO UPDATE SET document_count = %I.document_count + 1;', term_document_frequency_table, term, term_document_frequency_table);
    END LOOP;
END;
$$
LANGUAGE plpgsql;

-- Composite type to represent a term with its TF-IDF weight
DROP TYPE IF EXISTS tfidf_term_weight CASCADE;

CREATE TYPE tfidf_term_weight AS (
    term text,
    weight float
);


/* #########################################################
Function to represent a document as a TF-IDF weight vector
Input: document_txt - the text of the document
Input: model_table - the table storing model metadata (term_document_frequency_table name and total_documents)
Output: a vector (array) of term weights for the document
######################################################### */
CREATE OR REPLACE FUNCTION tfidf_vectorize(content text, model_table text)
    RETURNS tfidf_term_weight[]
    AS $$
DECLARE
    result tfidf_term_weight[];
    term text;
    terms text[];
    weight_val float;
    vector_item tfidf_term_weight;
    term_document_frequency_table text;
    total_documents integer;
    query_text text;
BEGIN
    -- Retrieve model metadata from the model_table
    query_text := format('SELECT term_document_frequency_table, total_documents FROM %I WHERE id = 1', model_table);
    EXECUTE query_text INTO term_document_frequency_table,
    total_documents;
    -- Check if model exists
    IF term_document_frequency_table IS NULL OR total_documents IS NULL THEN
        RAISE EXCEPTION 'Model table % does not exist or is not properly initialized', model_table;
    END IF;
    -- Initialize empty array
    result := ARRAY[]::tfidf_term_weight[];
    -- Get all unique terms from the document (compute once)
    terms := tsvector_to_array(to_tsvector('english', content));
    -- Build the vector by computing TF-IDF weight for each term in the document
    FOREACH term IN ARRAY terms LOOP
        -- Compute TF-IDF weight for this term (pass pre-computed terms array and total_documents)
        weight_val := tfidf_compute_term_weight(terms, term, term_document_frequency_table, total_documents);
        -- Create the term-weight pair
        vector_item := ROW (term,
            weight_val)::tfidf_term_weight;
        -- Append to result array
        result := array_append(result, vector_item);
    END LOOP;
    RETURN result;
END;
$$
LANGUAGE plpgsql;

-- Function to compute the weight of a term in a document (TF-IDF score)
-- Accepts an array of terms (pre-computed from to_tsvector) to avoid re-computing for each term
CREATE OR REPLACE FUNCTION tfidf_compute_term_weight(terms text[], term text, term_document_frequency_table text, total_documents integer)
    RETURNS float
    AS $$
DECLARE
    term_frequency integer;
    idf float;
BEGIN
    term_frequency := tfidf_get_term_frequency(terms, term);
    idf := tfidf_compute_idf(term, term_document_frequency_table, total_documents);
    -- Return TF-IDF weight = term frequency * IDF
    RETURN term_frequency * idf;
END;
$$
LANGUAGE plpgsql;

-- Function to compute term frequency for a term in an array of terms
-- Accepts a pre-computed array of terms to avoid re-computing to_tsvector
CREATE OR REPLACE FUNCTION tfidf_get_term_frequency(terms text[], term text)
    RETURNS integer
    AS $$
DECLARE
    count integer;
BEGIN
    -- Count occurrences of a term in the terms array
    count :=(
        SELECT
            COUNT(*)
        FROM
            unnest(terms) AS t
        WHERE
            t = term);
    -- Return TF = count of occurrences of the term in the array
    RETURN count;
END;
$$
LANGUAGE plpgsql;

-- Function to compute IDF (Inverse Document Frequency) for a term
-- Requires the total number of documents to be passed as a parameter for accurate IDF calculation
CREATE OR REPLACE FUNCTION tfidf_compute_idf(term text, term_document_frequency_table text, total_documents integer)
    RETURNS float
    AS $$
DECLARE
    doc_freq integer;
    query_text text;
BEGIN
    -- Build dynamic query to get document frequency for the term
    query_text := format('SELECT document_count FROM %I WHERE term = %L', term_document_frequency_table, term);
    EXECUTE query_text INTO doc_freq;
    -- If term not found or no documents, return 0
    IF doc_freq IS NULL OR doc_freq = 0 OR total_documents = 0 THEN
        RETURN 0.0;
    END IF;
    -- Return IDF = log(total_documents / document_frequency)
    RETURN ln(total_documents::float / doc_freq::float);
END;
$$
LANGUAGE plpgsql;

