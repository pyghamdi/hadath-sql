\set ON_ERROR_STOP 0
\pset pager off
DROP TABLE IF EXISTS docs CASCADE;
DROP TYPE IF EXISTS cluster CASCADE;

-- Toy input: one document per row, in timestamp order (rn), text as a set of terms.
CREATE TABLE docs (rn int PRIMARY KEY, did int, terms text[]);
INSERT INTO docs VALUES
 (1, 101, '{earthquake,tokyo,shaking}'),
 (2, 102, '{soccer,final,goal}'),
 (3, 103, '{earthquake,tokyo,damage}'),
 (4, 104, '{goal,soccer,match}'),
 (5, 105, '{rain,downtown}'),
 (6, 106, '{earthquake,shaking,damage}');

-- A cluster: id, representative terms (union of members' terms), member document ids.
CREATE TYPE cluster AS (cid int, terms text[], members int[]);

-- Jaccard similarity between two term sets.
CREATE FUNCTION sim(a text[], b text[]) RETURNS float LANGUAGE sql IMMUTABLE AS $$
  SELECT (SELECT count(*) FROM (SELECT unnest(a) INTERSECT SELECT unnest(b)) x)::float
       / NULLIF((SELECT count(*) FROM (SELECT unnest(a) UNION SELECT unnest(b)) y), 0)
$$;

\echo '=== Test 1: skeleton with helper functions (cluster set packed into one array) ==='
-- assign: the branch. Add document d to c_best if similar enough, else create a new cluster.
CREATE FUNCTION assign(d docs, cs cluster[], best cluster) RETURNS cluster[] LANGUAGE sql AS $$
  SELECT CASE
    WHEN best IS NOT NULL AND sim(d.terms, best.terms) >= 0.3 THEN
      (SELECT array_agg(CASE WHEN c.cid = best.cid
                             THEN ROW(c.cid,
                                      ARRAY(SELECT DISTINCT unnest(c.terms || d.terms) ORDER BY 1),
                                      c.members || d.did)::cluster
                             ELSE ROW(c.cid, c.terms, c.members)::cluster END ORDER BY o)
       FROM unnest(cs) WITH ORDINALITY AS c(cid, terms, members, o))
    ELSE cs || ROW(coalesce(cardinality(cs), 0) + 1, d.terms, ARRAY[d.did])::cluster
  END
$$;

WITH RECURSIVE sp(i, clusters) AS (
  SELECT 0, '{}'::cluster[]
  UNION ALL
  SELECT sp.i + 1,
         assign(d, sp.clusters,
                (SELECT c FROM unnest(sp.clusters) c
                 ORDER BY sim(d.terms, c.terms) DESC LIMIT 1))
  FROM sp JOIN docs d ON d.rn = sp.i + 1
)
SELECT (c).cid, (c).members, (c).terms
FROM (SELECT unnest(clusters) AS c FROM (SELECT clusters FROM sp ORDER BY i DESC LIMIT 1) l) last;

\echo '=== Test 2: same algorithm in plain SQL only (no helper functions except sim inlined) ==='
WITH RECURSIVE sp(i, clusters) AS (
  SELECT 0, '{}'::cluster[]
  UNION ALL
  SELECT sp.i + 1,
         CASE
           WHEN b.c IS NOT NULL AND b.s >= 0.3 THEN
             (SELECT array_agg(CASE WHEN x.cid = (b.c).cid
                                    THEN ROW(x.cid,
                                             ARRAY(SELECT DISTINCT unnest(x.terms || d.terms) ORDER BY 1),
                                             x.members || d.did)::cluster
                                    ELSE ROW(x.cid, x.terms, x.members)::cluster END ORDER BY x.o)
              FROM unnest(sp.clusters) WITH ORDINALITY AS x(cid, terms, members, o))
           ELSE sp.clusters || ROW(cardinality(sp.clusters) + 1, d.terms, ARRAY[d.did])::cluster
         END
  FROM sp
  JOIN docs d ON d.rn = sp.i + 1
  LEFT JOIN LATERAL (
    SELECT c, (SELECT count(*) FROM (SELECT unnest(d.terms) INTERSECT SELECT unnest(c.terms)) q)::float
            / (SELECT count(*) FROM (SELECT unnest(d.terms) UNION SELECT unnest(c.terms)) r) AS s
    FROM unnest(sp.clusters) c
    ORDER BY s DESC LIMIT 1
  ) b ON true
)
SELECT (c).cid, (c).members, (c).terms
FROM (SELECT unnest(clusters) AS c FROM (SELECT clusters FROM sp ORDER BY i DESC LIMIT 1) l) last;

\echo '=== Test 3: the "natural" relational attempt: clusters kept as ROWS of the working table ==='
\echo '--- 3a: pick c_best with ORDER BY/LIMIT over the working table'
WITH RECURSIVE sp(i, cid, terms) AS (
  SELECT 0, 0, '{}'::text[]
  UNION ALL
  SELECT sp.i + 1, sp.cid, sp.terms
  FROM sp JOIN docs d ON d.rn = sp.i + 1
  ORDER BY sim(d.terms, sp.terms) DESC LIMIT 1
)
SELECT * FROM sp;

\echo '--- 3b: aggregate over the working table (e.g., max similarity)'
WITH RECURSIVE sp(i, best) AS (
  SELECT 0, 0::float
  UNION ALL
  SELECT max(sp.i) + 1, max(sim(d.terms, '{}'))
  FROM sp JOIN docs d ON d.rn = sp.i + 1
)
SELECT * FROM sp;

\echo '--- 3c: reference the working table inside a subquery'
WITH RECURSIVE sp(i, cid) AS (
  SELECT 0, 0
  UNION ALL
  SELECT d.rn, (SELECT max(cid) FROM sp) + 1
  FROM docs d WHERE d.rn = (SELECT max(i) FROM sp) + 1
)
SELECT * FROM sp;
