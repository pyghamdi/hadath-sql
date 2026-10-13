/*
################################################################################
entropy aggregate (entropy.sql)
################################################################################
Defines:
  hsql_entropy(txt text)      RETURNS double precision
  hsql_entropy(tsv tsvector)  RETURNS double precision

For a group of rows, returns the entropy of the terms in their text, in bits.
The terms of all rows of the group are pooled into one bag, and the entropy is

  H = -sum_i P(t_i) * log2(P(t_i)),
  where P(t_i) = (occurrences of term t_i) / (total number of terms in the group).

Low entropy means that the group repeats a few terms, which is typical of spam
and duplicated posts; it is used to move such candidate events down a ranking.

Parameters:
  txt  - Text of one row (NULL is treated as empty text).
  tsv  - Terms of one row, as returned by to_tsvector (NULL is treated as a
         row with no terms).

hsql_entropy(text) extracts the terms with PostgreSQL full-text search,
to_tsvector('english', txt), which lowercases the text, removes English stop
words, and stems the remaining words. `Fire`, `fire`, and `fires` are therefore
the same term, and words such as `the` and `a` are not counted. A group with no
terms returns 0.

hsql_entropy(tsvector) takes terms that were already extracted, so that
hsql_entropy(to_tsvector('english', txt)) returns the same value as
hsql_entropy(txt). Use it

  - on large tables: to_tsvector is then evaluated while the rows are scanned,
    so a parallel plan divides the term extraction among its workers;
  - when the table already stores a tsvector column, which avoids extracting
    the terms again;
  - to use another text search configuration than English.

A tsvector without positions, such as the result of strip(), does not record
how often a term occurs in a row; each of its terms is counted once per row.

Examples:
  -- Returns 1.5 (cat = 2, hat = 1, bat = 1 out of 4 terms)
  SELECT hsql_entropy(txt) FROM (VALUES ('cat hat cat bat')) AS v(txt);

  -- Rank events: those with entropy of at least 3.5 first, then by number of users
  SELECT event_id,
         hsql_entropy(txt) AS term_entropy,
         COUNT(DISTINCT username) AS user_count
  FROM candidate_events
  GROUP BY event_id
  ORDER BY CASE WHEN hsql_entropy(txt) >= 3.5 THEN 1 ELSE 0 END DESC,
           COUNT(DISTINCT username) DESC;

  -- Same entropy; the terms are extracted during the scan
  SELECT event_id, hsql_entropy(to_tsvector('english', txt)) AS term_entropy
  FROM candidate_events
  GROUP BY event_id;

  -- With a stored tsvector column txt_tsv
  SELECT event_id, hsql_entropy(txt_tsv) AS term_entropy
  FROM candidate_events
  GROUP BY event_id;

  More examples are in demo_entropy.sql in this directory.

Implementation:
  - The aggregate state is the array of the values of the group: the text
    values for hsql_entropy(text) and the tsvector values for
    hsql_entropy(tsvector). The transition function is the built-in
    array_append, which PostgreSQL applies to the state in place, so adding a
    row does not copy the state. The final function counts the terms of all
    values of the group and computes the entropy in one query.
  - Both aggregates are declared PARALLEL = SAFE and have a combine function
    (the built-in array_cat), so they can be used in parallel plans: the
    workers scan the rows and collect the values, and the leader merges the
    arrays and runs the final function. hsql_entropy(text) extracts the terms
    in the final function, so that work is not divided among the workers;
    with hsql_entropy(to_tsvector(...)) the workers extract the terms.
  - The state holds the value of every row of the group until the group is
    finished, so the memory used by a group grows with the size of its text.

Limits (from to_tsvector):
  - At most 256 occurrences of a term are counted per row.
  - A row whose text produces a tsvector larger than 1 MB raises an error.

C implementation:
  cfunc/ contains an optional extension with hsql_entropy_c, which is called in
  the same way. Its state holds only the term counts, and in a parallel plan
  the workers count the terms, so it is faster and uses less memory on large
  groups. It has to be compiled and installed on the database server; this
  file needs no compilation. See cfunc/README.md.
################################################################################
*/


-- Final function of hsql_entropy(tsvector): counts the occurrences of each term
-- in the tsvector values of the group and computes the entropy of the resulting
-- distribution. unnest(tsvector) returns one row per term with the array of its
-- positions in the text, so the length of that array is the number of
-- occurrences of the term in the row. A term without positions counts once.
CREATE OR REPLACE FUNCTION hsql_entropy_final(state tsvector[])
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    -- p * log2(1 / p) is used instead of -p * log2(p) so that a group with a
    -- single term returns 0 and not -0.
    SELECT COALESCE(SUM((n / total) * ln(total / n)) / ln(2::double precision), 0)
    FROM (
        SELECT SUM(GREATEST(COALESCE(cardinality(t.positions), 0), 1))::double precision AS n,
               SUM(SUM(GREATEST(COALESCE(cardinality(t.positions), 0), 1))) OVER ()::double precision AS total
        FROM unnest(state) AS s(tsv)
        CROSS JOIN LATERAL unnest(s.tsv) AS t
        GROUP BY t.lexeme
    ) AS term_counts;
$$;


-- Final function of hsql_entropy(text): extracts the terms of the text values
-- of the group and computes the entropy in the same way.
CREATE OR REPLACE FUNCTION hsql_entropy_final(state text[])
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT COALESCE(SUM((n / total) * ln(total / n)) / ln(2::double precision), 0)
    FROM (
        SELECT SUM(cardinality(t.positions))::double precision AS n,
               SUM(SUM(cardinality(t.positions))) OVER ()::double precision AS total
        FROM unnest(state) AS s(txt)
        CROSS JOIN LATERAL unnest(to_tsvector('english', s.txt)) AS t
        GROUP BY t.lexeme
    ) AS term_counts;
$$;


CREATE AGGREGATE hsql_entropy(text) (
    SFUNC = array_append,
    STYPE = text[],
    FINALFUNC = hsql_entropy_final,
    COMBINEFUNC = array_cat,
    INITCOND = '{}',
    PARALLEL = SAFE
);


CREATE AGGREGATE hsql_entropy(tsvector) (
    SFUNC = array_append,
    STYPE = tsvector[],
    FINALFUNC = hsql_entropy_final,
    COMBINEFUNC = array_cat,
    INITCOND = '{}',
    PARALLEL = SAFE
);
