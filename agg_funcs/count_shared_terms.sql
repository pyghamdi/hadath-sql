/*
################################################################################
count_shared_terms aggregate (count_shared_terms.sql)
################################################################################
Aggregates for per-event (GROUP BY) text analytics.

Defines:
  - count_shared_terms(txt, minimum) — count of terms appearing in at least
    `minimum` tuples within the group

A shared term is one that appears in >= `minimum` distinct tuples
(rows) in the aggregate group. Tokenization matches hsql_process_text
(English stemming via to_tsvector).

Parallel aggregation uses COMBINEFUNC (count_shared_terms_combine) to sum
per-term tuple counts across partial states.
################################################################################
*/

DROP AGGREGATE IF EXISTS co_occur_term(text, integer);
DROP FUNCTION IF EXISTS co_occur_term_final(jsonb);
DROP FUNCTION IF EXISTS co_occur_term_sfunc(jsonb, text, integer);

DROP AGGREGATE IF EXISTS count_recurrent_terms(text, integer);
DROP FUNCTION IF EXISTS count_recurrent_terms_final(jsonb);
DROP FUNCTION IF EXISTS count_recurrent_terms_sfunc(jsonb, text, integer);

DROP AGGREGATE IF EXISTS count_shared_terms(text, integer);
DROP FUNCTION IF EXISTS count_shared_terms_combine(jsonb, jsonb);
DROP FUNCTION IF EXISTS count_shared_terms_final(jsonb);
DROP FUNCTION IF EXISTS count_shared_terms_sfunc(jsonb, text, integer);


CREATE OR REPLACE FUNCTION count_shared_terms_sfunc(state jsonb, txt text, minimum integer)
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


CREATE OR REPLACE FUNCTION count_shared_terms_combine(state1 jsonb, state2 jsonb)
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


CREATE OR REPLACE FUNCTION count_shared_terms_final(state jsonb)
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


CREATE AGGREGATE count_shared_terms(text, integer) (
    SFUNC = count_shared_terms_sfunc,
    STYPE = jsonb,
    FINALFUNC = count_shared_terms_final,
    COMBINEFUNC = count_shared_terms_combine,
    INITCOND = '{}'
);
