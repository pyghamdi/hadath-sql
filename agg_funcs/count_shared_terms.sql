/*
################################################################################
count_shared_terms aggregate (count_shared_terms.sql)
################################################################################
Defines:
  hsql_count_shared_terms(txt text, minimum integer) RETURNS integer

For a group of rows, returns the number of shared terms. A shared term is a
term that appears in at least `minimum` rows of the group; repeating a term
inside one row counts once. It is used to keep candidate events whose
documents mention the same terms.

Parameters:
  txt      - Text of one row (NULL is treated as empty text).
  minimum  - Number of rows a term must appear in to be counted. Pass the same
             value for every row of a group, typically a constant.

Terms are extracted with hsql_process_text (tf_idf/tf_idf.sql), which applies
PostgreSQL English stemming and removes stop words, so that file must be
loaded first. An empty group returns 0.

Example:
  -- Keep the events reported by more than 2 users that have at least 3 terms
  -- shared by 2 or more documents.
  SELECT event_id,
         COUNT(DISTINCT username) AS user_count,
         hsql_count_shared_terms(txt, 2) AS shared_term_count
  FROM candidate_events
  GROUP BY event_id
  HAVING COUNT(DISTINCT username) > 2
     AND hsql_count_shared_terms(txt, 2) >= 3;

Implementation:
  The aggregate state is a JSONB map from each term to the number of rows it
  appears in, plus the key `__minimum__` that carries the threshold to the
  final function. A combine function (hsql_count_shared_terms_combine) is
  defined for partial aggregation, but the aggregate is not declared
  PARALLEL = SAFE, so PostgreSQL does not use it in parallel plans.
################################################################################
*/


-- Transition function: adds 1 to the row count of every distinct term of `txt`
-- and records `minimum` in the state.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_sfunc(state jsonb, txt text, minimum integer)
RETURNS jsonb
LANGUAGE sql
PARALLEL SAFE
AS $$
    WITH base AS (
        SELECT COALESCE(state, '{}'::jsonb) || jsonb_build_object('__minimum__', minimum) AS st
    ),
    terms AS (
        SELECT DISTINCT term
        FROM hsql_process_text(txt)
    )
    SELECT b.st || COALESCE(
        (
            SELECT jsonb_object_agg(
                t.term,
                COALESCE((b.st ->> t.term)::integer, 0) + 1
            )
            FROM terms AS t
        ),
        '{}'::jsonb
    )
    FROM base AS b;
$$;


-- Combine function: merges two partial states by adding the row counts of
-- matching terms.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_combine(state1 jsonb, state2 jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN state1 IS NULL THEN state2
        WHEN state2 IS NULL THEN state1
        ELSE (
            SELECT jsonb_build_object(
                '__minimum__',
                COALESCE(
                    (state1 ->> '__minimum__')::integer,
                    (state2 ->> '__minimum__')::integer
                )
            ) || COALESCE(
                (
                    SELECT jsonb_object_agg(term, cnt)
                    FROM (
                        SELECT term, SUM(c)::integer AS cnt
                        FROM (
                            SELECT key AS term, (value #>> '{}')::integer AS c
                            FROM jsonb_each(state1)
                            WHERE key <> '__minimum__'
                            UNION ALL
                            SELECT key, (value #>> '{}')::integer
                            FROM jsonb_each(state2)
                            WHERE key <> '__minimum__'
                        ) AS pairs
                        GROUP BY term
                    ) AS summed
                ),
                '{}'::jsonb
            )
        )
    END;
$$;


-- Final function: counts the terms whose row count is at least the threshold.
CREATE OR REPLACE FUNCTION hsql_count_shared_terms_final(state jsonb)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN state IS NULL THEN 0
        ELSE COALESCE(
            (
                SELECT COUNT(*)::integer
                FROM jsonb_each(state) AS e(key, value)
                WHERE e.key <> '__minimum__'
                  AND (e.value #>> '{}')::integer >= (state ->> '__minimum__')::integer
            ),
            0
        )
    END;
$$;


CREATE AGGREGATE hsql_count_shared_terms(text, integer) (
    SFUNC = hsql_count_shared_terms_sfunc,
    STYPE = jsonb,
    FINALFUNC = hsql_count_shared_terms_final,
    COMBINEFUNC = hsql_count_shared_terms_combine,
    INITCOND = '{}'
);
