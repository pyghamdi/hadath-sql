/*
################################################################################
entropy aggregate (entropy.sql)
################################################################################
Defines:
  hsql_entropy(txt text) RETURNS double precision

For a group of rows, returns the word entropy of their text, in bits. All text
values of the group are pooled into one bag of words, and the entropy is

  H(W) = -sum_i P(w_i) * log2(P(w_i)),
  where P(w_i) = (occurrences of word w_i) / (total number of words in the group).

Low entropy means that the group repeats a few words, which is typical of spam
and duplicated posts; it is used to move such candidate events down a ranking.

Parameters:
  txt  - Text of one row (NULL is treated as empty text).

Words are obtained by splitting the text on whitespace. They are not stemmed
or lowercased, so `Fire` and `fire` are different words. A group with no words
returns 0.

Examples:
  -- Returns 1.5 (cat = 2, hat = 1, bat = 1 out of 4 words)
  SELECT hsql_entropy(txt) FROM (VALUES ('cat hat cat bat')) AS v(txt);

  -- Rank events: those with entropy of at least 3.5 first, then by number of users
  SELECT event_id,
         hsql_entropy(txt) AS word_entropy,
         COUNT(DISTINCT username) AS user_count
  FROM candidate_events
  GROUP BY event_id
  ORDER BY CASE WHEN hsql_entropy(txt) >= 3.5 THEN 1 ELSE 0 END DESC,
           COUNT(DISTINCT username) DESC;

  More examples are in demo_entropy.sql in this directory.

Implementation:
  The aggregate state is a JSONB map from each word to its number of
  occurrences. A combine function (hsql_entropy_combine) is defined for partial
  aggregation, but the aggregate is not declared PARALLEL = SAFE, so PostgreSQL
  does not use it in parallel plans.
################################################################################
*/


-- Transition function: adds the word counts of `txt` to the state.
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


-- Combine function: merges two partial states by adding the counts of matching words.
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


-- Final function: computes the entropy from the word counts.
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
