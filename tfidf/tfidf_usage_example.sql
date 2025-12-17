/* #########################################################
Example usage of the TF-IDF functions
######################################################### */

-- Compute document frequency statistics
SELECT tfidf_build_model('sample_documents', 'content', 'my_tfidf_model', TRUE);

-- Test tfidf_vectorize function
SELECT tfidf_vectorize('The quick brown fox jumps over the lazy dog', 'my_tfidf_model');



SELECT count(*) FROM unnest(tsvector_to_array(to_tsvector('english', 'The quick brown fox jumps over the lazy dog'))) AS term
WHERE term = 'fox';

SELECT * FROM to_tsvector('english', 'The quick brown fox jumps over the lazy dog');