/*
################################################################################
entropy_test aggregate (entropy_test.sql)
################################################################################
Aggregates for per-event (GROUP BY) text analytics.

Defines:
  - hsql_entropy_test(txt, threshold) — returns 1 when event word entropy
    H(W) >= threshold, else -1

Event entropy (base 2):
  H(W) = -sum_{i=1}^{V} P(w_i) log_2 P(w_i)
  where P(w_i) = count(w_i) / total word count in the group.

Tokenization: whitespace split, no stemming; words are counted as-is.
Parallel aggregation uses COMBINEFUNC (hsql_entropy_test_combine).
################################################################################
*/

DROP AGGREGATE IF EXISTS entropy_test(text, double precision);
DROP FUNCTION IF EXISTS entropy_test_combine(jsonb, jsonb);
DROP FUNCTION IF EXISTS entropy_test_final(jsonb);
DROP FUNCTION IF EXISTS entropy_test_sfunc(jsonb, text, double precision);

DROP AGGREGATE IF EXISTS hsql_entropy_test(text, double precision);
DROP FUNCTION IF EXISTS hsql_entropy_test_combine(jsonb, jsonb);
DROP FUNCTION IF EXISTS hsql_entropy_test_final(jsonb);
DROP FUNCTION IF EXISTS hsql_entropy_test_sfunc(jsonb, text, double precision);


CREATE OR REPLACE FUNCTION hsql_entropy_test_sfunc(
    state jsonb,
    txt text,
    threshold double precision
)
RETURNS jsonb
LANGUAGE sql
PARALLEL SAFE
AS $$
    WITH base AS (
        SELECT COALESCE(state, '{}'::jsonb)
            || jsonb_build_object('__threshold__', threshold) AS st
    ),
    words AS (
        SELECT w AS word, COUNT(*)::integer AS n
        FROM regexp_split_to_table(coalesce(txt, ''), '\s+') AS w
        WHERE w <> ''
        GROUP BY w
    )
    SELECT b.st || COALESCE(
        (
            SELECT jsonb_object_agg(
                wd.word,
                COALESCE((b.st ->> wd.word)::integer, 0) + wd.n
            )
            FROM words AS wd
        ),
        '{}'::jsonb
    )
    FROM base AS b;
$$;


CREATE OR REPLACE FUNCTION hsql_entropy_test_combine(state1 jsonb, state2 jsonb)
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
                '__threshold__',
                COALESCE(
                    (state1 ->> '__threshold__')::double precision,
                    (state2 ->> '__threshold__')::double precision
                )
            ) || COALESCE(
                (
                    SELECT jsonb_object_agg(word, cnt)
                    FROM (
                        SELECT word, SUM(c)::integer AS cnt
                        FROM (
                            SELECT key AS word, (value #>> '{}')::integer AS c
                            FROM jsonb_each(state1)
                            WHERE key <> '__threshold__'
                            UNION ALL
                            SELECT key, (value #>> '{}')::integer
                            FROM jsonb_each(state2)
                            WHERE key <> '__threshold__'
                        ) AS pairs
                        GROUP BY word
                    ) AS summed
                ),
                '{}'::jsonb
            )
        )
    END;
$$;


CREATE OR REPLACE FUNCTION hsql_entropy_test_final(state jsonb)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    WITH counts AS (
        SELECT (value #>> '{}')::integer AS cnt
        FROM jsonb_each(state) AS e(key, value)
        WHERE e.key <> '__threshold__'
    ),
    totals AS (
        SELECT COALESCE(SUM(cnt), 0)::double precision AS total
        FROM counts
    ),
    entropy AS (
        SELECT CASE
            WHEN t.total = 0 THEN 0::double precision
            ELSE COALESCE(
                (
                    SELECT -SUM(
                        (c.cnt / t.total)
                        * (ln(c.cnt / t.total) / ln(2::double precision))
                    )
                    FROM counts AS c
                ),
                0::double precision
            )
        END AS h
        FROM totals AS t
    )
    SELECT CASE
        WHEN COALESCE((SELECT h FROM entropy), 0) >= COALESCE(
            (state ->> '__threshold__')::double precision,
            0
        ) THEN 1
        ELSE -1
    END;
$$;


CREATE AGGREGATE hsql_entropy_test(text, double precision) (
    SFUNC = hsql_entropy_test_sfunc,
    STYPE = jsonb,
    FINALFUNC = hsql_entropy_test_final,
    COMBINEFUNC = hsql_entropy_test_combine,
    INITCOND = '{}'
);
