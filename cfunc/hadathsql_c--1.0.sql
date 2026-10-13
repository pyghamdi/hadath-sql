/*
################################################################################
hadathsql_c extension, version 1.0 (hadathsql_c--1.0.sql)
################################################################################
Defines:
  hsql_entropy_c(txt text)                                RETURNS double precision
  hsql_entropy_c(tsv tsvector)                            RETURNS double precision
  hsql_count_shared_terms_c(txt text, minimum integer)    RETURNS integer
  hsql_count_shared_terms_c(tsv tsvector, minimum integer) RETURNS integer

C implementations of the HadathSQL aggregates. They return the same values as
hsql_entropy (agg_funcs/entropy.sql) and hsql_count_shared_terms
(agg_funcs/count_shared_terms.sql) and are called in the same way:

  -- Entropy of the terms of each event
  SELECT event_id, hsql_entropy_c(txt) AS term_entropy
  FROM candidate_events
  GROUP BY event_id;

  -- Events with at least 3 terms that occur in 2 or more documents
  SELECT event_id, hsql_count_shared_terms_c(txt, 2) AS shared_term_count
  FROM candidate_events
  GROUP BY event_id
  HAVING hsql_count_shared_terms_c(txt, 2) >= 3;

  -- Terms that were already extracted (to_tsvector or a stored tsvector column)
  SELECT event_id,
         hsql_entropy_c(to_tsvector('english', txt)),
         hsql_count_shared_terms_c(to_tsvector('english', txt), 2)
  FROM candidate_events
  GROUP BY event_id;

Differences from the SQL implementations:
  - The state is a hash table of term counts that is updated in place. The
    work per row does not depend on the size of the group, and the memory used
    by a group grows with its number of distinct terms, not with the size of
    its text.
  - In a parallel plan the workers extract and count the terms; the leader
    only merges the counts.
  - hsql_entropy_c(text) counts every occurrence of a term in a row, whereas
    hsql_entropy(text) counts at most 256. The two differ only for rows in
    which a term occurs more than 256 times.
  - They must be compiled and installed on the database server (see README.md
    in this directory), which is not possible on most managed PostgreSQL
    services.

For hsql_count_shared_terms_c, pass the same non-null minimum for every row of
a group, typically a constant.

This file is run by CREATE EXTENSION hadathsql_c; do not run it with psql.
################################################################################
*/

\echo Use "CREATE EXTENSION hadathsql_c" to load this file. \quit

-- ---------------------------------------------------------------------------
-- Functions shared by the two aggregates
-- ---------------------------------------------------------------------------

-- Combine function: adds the term counts of the second state to the first.
CREATE FUNCTION hsql_term_counts_combine(internal, internal)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- Serialize and deserialize functions: transfer a state from a parallel worker
-- to the leader.
CREATE FUNCTION hsql_term_counts_serialize(internal)
RETURNS bytea
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION hsql_term_counts_deserialize(bytea, internal)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- hsql_entropy_c
-- ---------------------------------------------------------------------------

-- Transition functions: add the occurrences of the terms of one row.
CREATE FUNCTION hsql_entropy_c_text_sfunc(internal, text)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION hsql_entropy_c_tsvector_sfunc(internal, tsvector)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- Final function: computes the entropy from the term counts.
CREATE FUNCTION hsql_entropy_c_final(internal)
RETURNS double precision
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE AGGREGATE hsql_entropy_c(text) (
    SFUNC = hsql_entropy_c_text_sfunc,
    STYPE = internal,
    FINALFUNC = hsql_entropy_c_final,
    COMBINEFUNC = hsql_term_counts_combine,
    SERIALFUNC = hsql_term_counts_serialize,
    DESERIALFUNC = hsql_term_counts_deserialize,
    PARALLEL = SAFE
);

CREATE AGGREGATE hsql_entropy_c(tsvector) (
    SFUNC = hsql_entropy_c_tsvector_sfunc,
    STYPE = internal,
    FINALFUNC = hsql_entropy_c_final,
    COMBINEFUNC = hsql_term_counts_combine,
    SERIALFUNC = hsql_term_counts_serialize,
    DESERIALFUNC = hsql_term_counts_deserialize,
    PARALLEL = SAFE
);

-- ---------------------------------------------------------------------------
-- hsql_count_shared_terms_c
-- ---------------------------------------------------------------------------

-- Transition functions: add one to the count of each distinct term of one row
-- and record the threshold.
CREATE FUNCTION hsql_count_shared_terms_c_text_sfunc(internal, text, integer)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION hsql_count_shared_terms_c_tsvector_sfunc(internal, tsvector, integer)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- Final function: counts the terms whose count is at least the threshold.
CREATE FUNCTION hsql_count_shared_terms_c_final(internal)
RETURNS integer
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE AGGREGATE hsql_count_shared_terms_c(text, integer) (
    SFUNC = hsql_count_shared_terms_c_text_sfunc,
    STYPE = internal,
    FINALFUNC = hsql_count_shared_terms_c_final,
    COMBINEFUNC = hsql_term_counts_combine,
    SERIALFUNC = hsql_term_counts_serialize,
    DESERIALFUNC = hsql_term_counts_deserialize,
    PARALLEL = SAFE
);

CREATE AGGREGATE hsql_count_shared_terms_c(tsvector, integer) (
    SFUNC = hsql_count_shared_terms_c_tsvector_sfunc,
    STYPE = internal,
    FINALFUNC = hsql_count_shared_terms_c_final,
    COMBINEFUNC = hsql_term_counts_combine,
    SERIALFUNC = hsql_term_counts_serialize,
    DESERIALFUNC = hsql_term_counts_deserialize,
    PARALLEL = SAFE
);
