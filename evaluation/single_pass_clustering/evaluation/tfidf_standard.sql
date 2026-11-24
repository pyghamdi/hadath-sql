-- TF-IDF stage in standard SQL: the weights of hsql_create_tf_idf_tbl (Equation 1 of
-- the paper: (term count / terms in document) * log10(N / df)), computed from
-- sp_docs(doc_id, txt) into tfidf_std(doc_id, term, weight) with constructs of the
-- SQL standard only: a recursive CTE, window functions, GROUP BY, joins, NOT EXISTS,
-- LOWER, SUBSTRING, POSITION, CHAR_LENGTH, CAST, and LOG10. No to_tsvector, no
-- arrays, no UDFs.
--
-- Preprocessing, in place of to_tsvector('english', txt):
--   1. lowercase the text (LOWER);
--   2. split it into words at every character that is not an ASCII letter or digit;
--   3. remove the stop words listed in std_stopwords(word) (PostgreSQL's English
--      stop-word list, loaded by run_tfidf_standard.py);
--   4. no stemming: the Snowball stemmer has no practical formulation in SQL.
-- On the synthetic datasets (gen_synthetic_data.sql) this yields the same terms and
-- counts as to_tsvector, since no generated word is a stop word or changed by the
-- stemmer; run_tfidf_standard.py checks that both weights tables are equal.
--
-- Splitting without string functions that return sets: a recursive CTE generates
-- the positions 1 .. (longest text); joining it with the documents gives one row
-- per character; a running count of the separators numbers the words (gaps and
-- islands); and each word is cut out of the text with SUBSTRING from its first
-- position and its length.
--
-- Usage: psql -f tfidf_standard.sql   (needs sp_docs and std_stopwords)
DROP TABLE IF EXISTS tfidf_std;
CREATE TABLE tfidf_std AS (
  WITH RECURSIVE
  lower_docs (doc_id, txt) AS (
    SELECT doc_id, LOWER(COALESCE(txt, ''))
    FROM sp_docs
  ),
  positions (p) AS (
    VALUES (1)
    UNION ALL
    SELECT p + 1
    FROM positions
    WHERE p < (SELECT MAX(CHAR_LENGTH(txt)) FROM lower_docs)
  ),
  chars (doc_id, p, is_word) AS (
    SELECT d.doc_id, ps.p,
           CASE WHEN POSITION(SUBSTRING(d.txt FROM ps.p FOR 1)
                              IN 'abcdefghijklmnopqrstuvwxyz0123456789') > 0
                THEN 1 ELSE 0 END
    FROM lower_docs AS d
    JOIN positions AS ps ON ps.p <= CHAR_LENGTH(d.txt)
  ),
  numbered (doc_id, p, is_word, wid) AS (
    SELECT doc_id, p, is_word,
           SUM(1 - is_word) OVER (PARTITION BY doc_id ORDER BY p
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    FROM chars
  ),
  words (doc_id, start_pos, len) AS (
    SELECT doc_id, MIN(p), CAST(COUNT(*) AS INTEGER)
    FROM numbered
    WHERE is_word = 1
    GROUP BY doc_id, wid
  ),
  tokens (doc_id, term) AS (
    SELECT w.doc_id, SUBSTRING(d.txt FROM w.start_pos FOR w.len)
    FROM words AS w
    JOIN lower_docs AS d ON d.doc_id = w.doc_id
  ),
  term_count_per_doc (doc_id, term, term_count) AS (
    SELECT doc_id, term, COUNT(*)
    FROM tokens AS t
    WHERE NOT EXISTS (SELECT 1 FROM std_stopwords AS s WHERE s.word = t.term)
    GROUP BY doc_id, term
  ),
  total_terms_per_doc (doc_id, total_terms) AS (
    SELECT doc_id, SUM(term_count)
    FROM term_count_per_doc
    GROUP BY doc_id
  ),
  document_frequency (term, df) AS (
    SELECT term, COUNT(*)
    FROM term_count_per_doc
    GROUP BY term
  ),
  document_count (total_docs) AS (
    SELECT COUNT(*) FROM sp_docs
  )
  SELECT tc.doc_id, tc.term,
         (CAST(tc.term_count AS DOUBLE PRECISION) / tt.total_terms)
         * LOG10(CAST(dc.total_docs AS DOUBLE PRECISION) / df.df) AS weight
  FROM term_count_per_doc AS tc
  JOIN total_terms_per_doc AS tt ON tt.doc_id = tc.doc_id
  JOIN document_frequency AS df ON df.term = tc.term
  CROSS JOIN document_count AS dc
) WITH DATA;
