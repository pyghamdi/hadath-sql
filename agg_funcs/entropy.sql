/*
################################################################################
entropy aggregate (entropy.sql)
################################################################################
Aggregates for per-event (GROUP BY) text analytics.

Defines:
  - hsql_entropy(txt) — event word entropy H(W) (base 2)

  H(W) = -sum_{i=1}^{V} P(w_i) log_2 P(w_i)
  where P(w_i) = count(w_i) / total word count in the group.

Tokenization: whitespace split, no stemming; words are counted as-is.
Parallel aggregation uses COMBINEFUNC (hsql_entropy_combine).

Demo:
  psql -f agg_funcs/demo_entropy.sql
  -- hsql_entropy('cat hat cat bat') => 1.5
################################################################################
*/

DROP AGGREGATE IF EXISTS entropy(text);
DROP FUNCTION IF EXISTS entropy_combine(jsonb, jsonb);
DROP FUNCTION IF EXISTS entropy_final(jsonb);
DROP FUNCTION IF EXISTS entropy_sfunc(jsonb, text);

DROP AGGREGATE IF EXISTS hsql_entropy(text);
DROP FUNCTION IF EXISTS hsql_entropy_combine(jsonb, jsonb);
DROP FUNCTION IF EXISTS hsql_entropy_final(jsonb);
DROP FUNCTION IF EXISTS hsql_entropy_sfunc(jsonb, text);


CREATE OR REPLACE FUNCTION hsql_entropy_sfunc(state jsonb, txt text)
RETURNS jsonb
LANGUAGE sql
PARALLEL SAFE
AS $$
    WITH base AS (
        SELECT COALESCE(state, '{}'::jsonb) AS st
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


CREATE OR REPLACE FUNCTION hsql_entropy_combine(state1 jsonb, state2 jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN state1 IS NULL THEN state2
        WHEN state2 IS NULL THEN state1
        ELSE COALESCE(
            (
                SELECT jsonb_object_agg(word, cnt)
                FROM (
                    SELECT word, SUM(c)::integer AS cnt
                    FROM (
                        SELECT key AS word, (value #>> '{}')::integer AS c
                        FROM jsonb_each(state1)
                        UNION ALL
                        SELECT key, (value #>> '{}')::integer
                        FROM jsonb_each(state2)
                    ) AS pairs
                    GROUP BY word
                ) AS summed
            ),
            '{}'::jsonb
        )
    END;
$$;


CREATE OR REPLACE FUNCTION hsql_entropy_final(state jsonb)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    WITH counts AS (
        SELECT (value #>> '{}')::integer AS cnt
        FROM jsonb_each(COALESCE(state, '{}'::jsonb)) AS e(key, value)
    ),
    totals AS (
        SELECT COALESCE(SUM(cnt), 0)::double precision AS total
        FROM counts
    )
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
    END
    FROM totals AS t;
$$;


CREATE AGGREGATE hsql_entropy(text) (
    SFUNC = hsql_entropy_sfunc,
    STYPE = jsonb,
    FINALFUNC = hsql_entropy_final,
    COMBINEFUNC = hsql_entropy_combine,
    INITCOND = '{}'
);
