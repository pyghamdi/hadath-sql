/*
################################################################################
count_shared_terms aggregate (count_shared_terms.sql)
################################################################################
Defines:
  hsql_count_shared_terms(txt text, minimum integer)      RETURNS integer
  hsql_count_shared_terms(tsv tsvector, minimum integer)  RETURNS integer

For a group of rows, returns the number of shared terms. A shared term is a
term that appears in at least `minimum` rows of the group; repeating a term
inside one row counts once. It is used to keep candidate events whose
documents mention the same terms.

Parameters:
  txt      - Text of one row (NULL is treated as empty text).
  tsv      - Terms of one row, as returned by to_tsvector (NULL is treated as
             a row with no terms).
  minimum  - Number of rows a term must appear in to be counted. Pass the same
             non-null value for every row of a group, typically a constant.

hsql_count_shared_terms(text, integer) extracts the terms with PostgreSQL
full-text search, to_tsvector('english', txt), which lowercases the text,
removes English stop words, and stems the remaining words. A group with no
rows returns 0.

hsql_count_shared_terms(tsvector, integer) takes terms that were already
extracted, so that hsql_count_shared_terms(to_tsvector('english', txt), m)
returns the same value as hsql_count_shared_terms(txt, m). Use it when the
table already stores a tsvector column, to use another text search
configuration than English, or to let the workers of a parallel plan extract
the terms while they scan the rows.

Examples:
  -- Returns 1: only `fire` appears in at least 2 of the 3 rows
  SELECT hsql_count_shared_terms(txt, 2)
  FROM (VALUES ('fire downtown'), ('big fire'), ('rain')) AS v(txt);

  -- Keep the events reported by more than 2 users that have at least 3 terms
  -- shared by 2 or more documents.
  SELECT event_id,
         COUNT(DISTINCT username) AS user_count,
         hsql_count_shared_terms(txt, 2) AS shared_term_count
  FROM candidate_events
  GROUP BY event_id
  HAVING COUNT(DISTINCT username) > 2
     AND hsql_count_shared_terms(txt, 2) >= 3;

  -- With a stored tsvector column txt_tsv
  SELECT event_id, hsql_count_shared_terms(txt_tsv, 2) AS shared_term_count
  FROM candidate_events
  GROUP BY event_id;

Implementation:
  - The aggregate state is a text array: its first element is `minimum`, and
    the remaining elements are the values of the rows of the group (a tsvector
    is stored in its text form). The transition function only appends the
    value of a row; the final function extracts the terms of all rows and
    counts, in one query, the terms that appear in at least `minimum` rows.
  - Both aggregates are declared PARALLEL = SAFE and have a combine function,
    so they can be used in parallel plans: the workers scan the rows and
    collect the values, and the leader merges the arrays and runs the final
    function.

Limits:
  - A transition function written in PL/pgSQL cannot update the array in
    place, so PostgreSQL copies the state for every row, and the cost of
    adding a row grows with the number of rows already in the group. The
    aggregate is efficient for groups of up to a few thousand rows; for larger
    groups use the C implementation.
  - The state holds the value of every row of the group until the group is
    finished, so the memory used by a group grows with the size of its text.
  - A row whose text produces a tsvector larger than 1 MB raises an error.

C implementation:
  cfunc/ contains an optional extension with hsql_count_shared_terms_c, which
  is called in the same way. Its state holds only the term counts and is
  updated in place, so its cost per row does not depend on the size of the
  group, and in a parallel plan the workers count the terms. It has to be
  compiled and installed on the database server; this file needs no
  compilation. See cfunc/README.md.
################################################################################
*/


-- Transition function of hsql_count_shared_terms(text, integer): appends the
-- text of a row to the state. The first element of the state is the threshold,
-- which is added before the first row.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_sfunc(state text[], txt text, minimum integer)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
    IF cardinality(state) = 0 THEN
        state := array_append(state, minimum::text);
    END IF;
    RETURN array_append(state, txt);
END;
$$;


-- Transition function of hsql_count_shared_terms(tsvector, integer): the same,
-- with the tsvector of a row stored in its text form.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_tsvector_sfunc(state text[], tsv tsvector, minimum integer)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
    IF cardinality(state) = 0 THEN
        state := array_append(state, minimum::text);
    END IF;
    RETURN array_append(state, tsv::text);
END;
$$;


-- Combine function: appends the rows of the second state to the first. The
-- threshold, which is the first element of each non-empty state, is kept once.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_combine(state1 text[], state2 text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN cardinality(state1) = 0 THEN state2
        WHEN cardinality(state2) = 0 THEN state1
        ELSE state1 || state2[2:]
    END;
$$;


-- Final function of hsql_count_shared_terms(text, integer): counts the terms
-- that appear in at least `minimum` rows. unnest(tsvector) returns each term
-- of a row once, so the number of rows of a term after grouping is the number
-- of rows of the group that contain it.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_final(state text[])
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT COUNT(*)::integer
    FROM (
        SELECT t.lexeme
        FROM unnest(state[2:]) AS s(txt)
        CROSS JOIN LATERAL unnest(to_tsvector('english', s.txt)) AS t
        GROUP BY t.lexeme
        HAVING COUNT(*) >= state[1]::integer
    ) AS shared_terms;
$$;


-- Final function of hsql_count_shared_terms(tsvector, integer): the same, for
-- rows that were stored as the text form of a tsvector.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_tsvector_final(state text[])
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT COUNT(*)::integer
    FROM (
        SELECT t.lexeme
        FROM unnest(state[2:]) AS s(tsv)
        CROSS JOIN LATERAL unnest(s.tsv::tsvector) AS t
        GROUP BY t.lexeme
        HAVING COUNT(*) >= state[1]::integer
    ) AS shared_terms;
$$;


CREATE AGGREGATE hsql_count_shared_terms(text, integer) (
    SFUNC = hsql_count_shared_terms_sfunc,
    STYPE = text[],
    FINALFUNC = hsql_count_shared_terms_final,
    COMBINEFUNC = hsql_count_shared_terms_combine,
    INITCOND = '{}',
    PARALLEL = SAFE
);


CREATE AGGREGATE hsql_count_shared_terms(tsvector, integer) (
    SFUNC = hsql_count_shared_terms_tsvector_sfunc,
    STYPE = text[],
    FINALFUNC = hsql_count_shared_terms_tsvector_final,
    COMBINEFUNC = hsql_count_shared_terms_combine,
    INITCOND = '{}',
    PARALLEL = SAFE
);
