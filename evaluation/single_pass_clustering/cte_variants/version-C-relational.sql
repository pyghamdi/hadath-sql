\pset pager off
-- Relational version: no arrays, no custom types, no UDFs.
-- Input: docs(rn, did) and doc_terms(rn, term), one term per row.
DROP TABLE IF EXISTS docs2, doc_terms CASCADE;
CREATE TABLE docs2 (rn int PRIMARY KEY, did int);
CREATE TABLE doc_terms (rn int, term varchar(50));
INSERT INTO docs2 VALUES (1,101),(2,102),(3,103),(4,104),(5,105),(6,106);
INSERT INTO doc_terms VALUES
 (1,'earthquake'),(1,'tokyo'),(1,'shaking'),
 (2,'soccer'),(2,'final'),(2,'goal'),
 (3,'earthquake'),(3,'tokyo'),(3,'damage'),
 (4,'goal'),(4,'soccer'),(4,'match'),
 (5,'rain'),(5,'downtown'),
 (6,'earthquake'),(6,'shaking'),(6,'damage');

-- State after i documents = a set of rows (i, kind, cid, val):
--   kind 'T': cluster cid contains term val
--   kind 'M': cluster cid contains document val
--   kind 'S': one sentinel row, so the state is never empty
WITH RECURSIVE sp(i, kind, cid, val) AS (
  SELECT 0, CAST('S' AS varchar(1)), 0, CAST(NULL AS varchar(50))
  UNION ALL
  SELECT g.i + 1, CAST(o.kind AS varchar(1)), o.cid, CAST(o.val AS varchar(50))
  FROM (
    SELECT f.*,
           ROW_NUMBER() OVER (PARTITION BY f.kind ORDER BY f.val) AS rn_k,
           (SELECT CAST(did AS varchar(50)) FROM docs2 WHERE rn = f.i + 1) AS did
    FROM (
      SELECT e.*,
             -- for each term of the new document: is it already in c_best?
             MAX(CASE WHEN e.kind = 'T' AND e.cid = e.bestcid THEN 1 ELSE 0 END)
               OVER (PARTITION BY e.val) AS in_best
      FROM (
        SELECT c.*,
               FIRST_VALUE(c.cid) OVER (ORDER BY c.jac DESC NULLS LAST, c.cid) AS bestcid,
               MAX(c.jac) OVER () AS bestjac
        FROM (
          SELECT b.*,
                 CASE WHEN b.kind = 'T'
                      THEN CAST(b.inter AS float) / (b.csize + b.dsize - b.inter) END AS jac
          FROM (
            SELECT a.*,
                   SUM(a.hit) OVER (PARTITION BY a.cid) AS inter,
                   COUNT(CASE WHEN a.kind = 'T' THEN 1 END) OVER (PARTITION BY a.cid) AS csize,
                   COUNT(CASE WHEN a.kind = 'D' THEN 1 END) OVER () AS dsize,
                   MAX(a.cid) OVER () AS maxcid
            FROM (
              -- the sentinel row is joined with the terms of the next document (kind 'D')
              SELECT sp.i,
                     CASE WHEN t.term IS NOT NULL THEN 'D' ELSE sp.kind END AS kind,
                     sp.cid,
                     COALESCE(t.term, sp.val) AS val,
                     CASE WHEN sp.kind = 'T'
                           AND sp.val IN (SELECT x.term FROM doc_terms x WHERE x.rn = sp.i + 1)
                          THEN 1 ELSE 0 END AS hit
              FROM sp LEFT JOIN doc_terms t ON sp.kind = 'S' AND t.rn = sp.i + 1
              WHERE sp.i < (SELECT COUNT(*) FROM docs2)
            ) a
          ) b
        ) c
      ) e
    ) f
  ) g
  CROSS JOIN LATERAL (VALUES
    -- carry over existing state
    (CASE WHEN g.kind IN ('T','M') THEN g.kind END, g.cid, g.val),
    -- add the document's new terms to c_best, or to a new cluster
    (CASE WHEN g.kind = 'D' AND NOT (COALESCE(g.bestjac, 0) >= 0.3 AND g.in_best = 1) THEN 'T' END,
     CASE WHEN COALESCE(g.bestjac, 0) >= 0.3 THEN g.bestcid ELSE g.maxcid + 1 END, g.val),
    -- record membership (once per document)
    (CASE WHEN g.kind = 'D' AND g.rn_k = 1 THEN 'M' END,
     CASE WHEN COALESCE(g.bestjac, 0) >= 0.3 THEN g.bestcid ELSE g.maxcid + 1 END, g.did),
    -- keep the sentinel
    (CASE WHEN g.kind = 'D' AND g.rn_k = 1 THEN 'S' END, 0, CAST(NULL AS varchar(50)))
  ) AS o(kind, cid, val)
  WHERE o.kind IS NOT NULL
)
SELECT cid,
       string_agg(val, ',' ORDER BY val) FILTER (WHERE kind = 'M') AS members,
       string_agg(val, ',' ORDER BY val) FILTER (WHERE kind = 'T') AS terms
FROM sp
WHERE i = (SELECT MAX(i) FROM sp) AND kind <> 'S'
GROUP BY cid ORDER BY cid;
