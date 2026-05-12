-- Iterative TF-IDF helper UDFs.

-- Idempotent drops: new names, then legacy identifiers from older installs.
DROP FUNCTION IF EXISTS hsql_update_term_doc_freq_itr(text, text) CASCADE;
DROP FUNCTION IF EXISTS hsql_vectorize_itr(text, text) CASCADE;
DROP FUNCTION IF EXISTS hsql_get_tf_idf_vector(text, text) CASCADE;
DROP FUNCTION IF EXISTS hsql_compute_term_weight_itr(text[], text, text, integer) CASCADE;
DROP FUNCTION IF EXISTS hsql_get_term_frequency_itr(text[], text) CASCADE;
DROP FUNCTION IF EXISTS hsql_compute_idf_itr(text, text, integer) CASCADE;
DROP FUNCTION IF EXISTS hsql_text_to_tsvector_itr(text) CASCADE;
DROP FUNCTION IF EXISTS hsql_text_to_term_counts_itr(text) CASCADE;

DROP FUNCTION IF EXISTS tfidf_update_term_doc_freq_itr(text, text) CASCADE;
DROP FUNCTION IF EXISTS tfidf_vectorize_itr(text, text) CASCADE;
DROP FUNCTION IF EXISTS tfidf_get_tf_idf_vector(text, text) CASCADE;
DROP FUNCTION IF EXISTS tfidf_compute_term_weight_itr(text[], text, text, integer) CASCADE;
DROP FUNCTION IF EXISTS tfidf_get_term_frequency_itr(text[], text) CASCADE;
DROP FUNCTION IF EXISTS tfidf_compute_idf_itr(text, text, integer) CASCADE;
DROP FUNCTION IF EXISTS tfidf_text_to_tsvector_itr(text) CASCADE;
DROP FUNCTION IF EXISTS tfidf_text_to_term_counts_itr(text) CASCADE;
DROP FUNCTION IF EXISTS OLD_tfidf_text_to_term_counts(text) CASCADE;

-- Function to update term document frequency statistics when adding a document
CREATE OR REPLACE FUNCTION hsql_update_term_doc_freq_itr(doc_txt text, term_doc_freq_tbl text)
    RETURNS VOID
    AS $$
DECLARE
    unique_terms text[]; -- array of unique terms in the document
    term text;
BEGIN
    -- Document frequency must count each term once per document (not per occurrence).
    SELECT array_agg(t)
    INTO unique_terms
    FROM (
        SELECT DISTINCT unnest(tsvector_to_array(to_tsvector('english', COALESCE(doc_txt, '')))) AS t
    ) AS dedup_terms;

    IF unique_terms IS NULL THEN
        RETURN;
    END IF;

    FOREACH term IN ARRAY unique_terms LOOP
        -- RAISE NOTICE 'Term: %', term;
        EXECUTE format('INSERT INTO %I (term, document_count) 
            VALUES (%L, 1)
            ON CONFLICT (term) 
            DO UPDATE SET document_count = %I.document_count + 1;', term_doc_freq_tbl, term, term_doc_freq_tbl);
    END LOOP;
END;
$$
LANGUAGE plpgsql;

-- Composite type to represent a term with its TF-IDF weight
DROP TYPE IF EXISTS tfidf_term_weight_itr CASCADE;

CREATE TYPE tfidf_term_weight_itr AS (
    term text,
    weight float
);


/* #########################################################
Function to represent a document as a TF-IDF weight vector
Input: content - the text of the document
Input: model_table - the table storing model metadata (term_document_frequency_table name and total_documents)
Output: a vector (array) of term weights for the document
######################################################### */
CREATE OR REPLACE FUNCTION hsql_vectorize_itr(content text, model_table text)
    RETURNS tfidf_term_weight_itr[]
    AS $$
DECLARE
    result tfidf_term_weight_itr[];
    term text;
    unique_terms text[];
    all_terms text[];
    weight_val float;
    vector_item tfidf_term_weight_itr;
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
    result := ARRAY[]::tfidf_term_weight_itr[];
    -- Tokenize once and reuse in TF calculations.
    all_terms := tsvector_to_array(to_tsvector('english', COALESCE(content, '')));

    SELECT array_agg(t)
    INTO unique_terms
    FROM (
        SELECT DISTINCT unnest(all_terms) AS t
    ) AS dedup_terms;

    IF unique_terms IS NULL THEN
        RETURN result;
    END IF;

    -- Build the vector by computing TF-IDF weight for each term in the document
    FOREACH term IN ARRAY unique_terms LOOP
        -- Compute TF-IDF using full term array so TF still reflects repeated terms.
        weight_val := hsql_compute_term_weight_itr(all_terms, term, term_document_frequency_table, total_documents);
        -- Create the term-weight pair
        vector_item := ROW (term,
            weight_val)::tfidf_term_weight_itr;
        -- Append to result array
        result := array_append(result, vector_item);
    END LOOP;
    RETURN result;
END;
$$
LANGUAGE plpgsql;

-- Function to compute the weight of a term in a document (TF-IDF score)
-- Accepts an array of terms (pre-computed from to_tsvector) to avoid re-computing for each term
CREATE OR REPLACE FUNCTION hsql_compute_term_weight_itr(terms text[], term text, term_document_frequency_table text, total_documents integer)
    RETURNS float
    AS $$
DECLARE
    term_frequency integer;
    idf float;
BEGIN
    term_frequency := hsql_get_term_frequency_itr(terms, term);
    idf := hsql_compute_idf_itr(term, term_document_frequency_table, total_documents);
    -- Return TF-IDF weight = term frequency * IDF
    RETURN term_frequency * idf;
END;
$$
LANGUAGE plpgsql;

-- Function to compute term frequency for a term in an array of terms
-- Accepts a pre-computed array of terms to avoid re-computing to_tsvector
CREATE OR REPLACE FUNCTION hsql_get_term_frequency_itr(terms text[], term text)
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
CREATE OR REPLACE FUNCTION hsql_compute_idf_itr(term text, term_document_frequency_table text, total_documents integer)
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





-- UDF: Convert text to tsvector
-- Input: input_text - the text to tokenize
-- Returns: tsvector - the tokenized text as a tsvector
CREATE OR REPLACE FUNCTION hsql_text_to_tsvector_itr(input_text text)
    RETURNS tsvector
    AS $$
    SELECT to_tsvector('english', COALESCE(input_text, ''));
$$
LANGUAGE sql STABLE;

-- UDF: Tokenize text with to_tsvector and return (term, count) for each unique term.
-- Input: input_text - the text to tokenize
-- Returns: SETOF (term text, count integer) - one row per unique term with its occurrence count
CREATE OR REPLACE FUNCTION hsql_text_to_term_counts_itr(input_text text)
    RETURNS TABLE(
        term text,
        count integer
    )
    AS $$
    SELECT
        word::text AS term,
        count(*)::integer AS count
    FROM
        unnest(tsvector_to_array(to_tsvector('english', COALESCE(input_text, '')))) AS word
GROUP BY
    word;
$$ LANGUAGE SQL STABLE;
