/* #########################################################
Example usage of the TF-IDF functions
######################################################### */

-- Build the TF-IDF model
SELECT tfidf_build_model('sample_documents', 'content', 'my_tfidf_model', TRUE);

-- Vectorize a document
SELECT tfidf_vectorize('The quick brown fox jumps over the lazy dog', 'my_tfidf_model');

-- Test the tokenizer function
SELECT * FROM unnest(to_tsvector('english', 'The quick brown fox jumps over the lazy dog')) AS term;
