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
SELECT COUNT(DISTINCT cid) FROM sp WHERE i = (SELECT MAX(i) FROM sp) AND kind = 'M';
