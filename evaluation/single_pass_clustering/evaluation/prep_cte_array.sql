-- Input preparation of the Array CTE (non-standard; formerly A); timed with the CTE.
-- One row per document, in timestamp order, with parallel term/weight arrays.
DROP TABLE IF EXISTS cte_docs_arr;

CREATE TABLE cte_docs_arr AS
SELECT CAST(ROW_NUMBER() OVER (ORDER BY d.ts, d.doc_id) AS integer) AS rn,
       d.doc_id AS did,
       COALESCE(array_agg(t.term ORDER BY t.term) FILTER (WHERE t.term IS NOT NULL), '{}') AS terms,
       COALESCE(array_agg(t.weight ORDER BY t.term) FILTER (WHERE t.term IS NOT NULL), '{}') AS ws
FROM sp_docs d LEFT JOIN sp_tfidf t ON t.doc_id = d.doc_id
GROUP BY d.doc_id, d.ts;
ALTER TABLE cte_docs_arr ADD PRIMARY KEY (rn);
ANALYZE cte_docs_arr;
