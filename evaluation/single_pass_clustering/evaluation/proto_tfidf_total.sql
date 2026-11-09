-- Prototype (2026-11-09): per-document term total without the aggregation and join on doc_id.
-- Load into a database with HadathSQL and sp_docs, then run proto_tfidf_total.py <reps> <workers,...>.
SET client_min_messages = warning;
DROP FUNCTION IF EXISTS tmp_tsv_total(tsvector);
-- B: one non-inlined call per document returns the tsvector and its total
DROP TYPE IF EXISTS tmp_tsv_stats CASCADE;
CREATE TYPE tmp_tsv_stats AS (tsv tsvector, total integer);
CREATE OR REPLACE FUNCTION tmp_tsv_stats(txt text) RETURNS tmp_tsv_stats
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE v tsvector := to_tsvector('english', coalesce(txt, ''));
BEGIN
  RETURN (v, (SELECT coalesce(SUM(array_length(positions, 1)), 0) FROM unnest(v)))::tmp_tsv_stats;
END $$;
-- C: term counts with the document's total (window over the document's terms)
CREATE OR REPLACE FUNCTION tmp_term_counts_total(tsv tsvector)
RETURNS TABLE(term text, count integer, total bigint) LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS $$
  SELECT lexeme, array_length(positions, 1), SUM(array_length(positions, 1)) OVER ()
  FROM unnest(tsv)
$$;
