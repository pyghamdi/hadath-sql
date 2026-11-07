-- Input preparation of the Standard SQL CTE (formerly C); timed with the CTE.
-- Reads sp_tfidf(doc_id, term, weight). rn = position in timestamp order, the same
-- order the drivers use.
DROP TABLE IF EXISTS cte_docs, cte_vec;

CREATE TABLE cte_docs AS
SELECT CAST(ROW_NUMBER() OVER (ORDER BY ts, doc_id) AS integer) AS rn, doc_id AS did
FROM sp_docs;
ALTER TABLE cte_docs ADD PRIMARY KEY (rn);

CREATE TABLE cte_vec AS
SELECT d.rn, CAST(t.term AS varchar(200)) AS term, t.weight AS w
FROM sp_tfidf t JOIN cte_docs d ON d.did = t.doc_id;
CREATE INDEX ON cte_vec (rn);
ANALYZE cte_docs, cte_vec;
