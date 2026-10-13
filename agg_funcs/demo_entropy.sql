-- #########################################################
-- Demo: term entropy with hsql_entropy
--
-- Prerequisite: HadathSQL is installed (install.sql), or at least entropy.sql is loaded.
--
-- Run (from repository root):
--   psql -d <database> -f agg_funcs/demo_entropy.sql
--
-- Terms are extracted with to_tsvector('english', txt): the text is lowercased,
-- English stop words are removed, and the remaining words are stemmed.
--
-- Term counts for "cat hat cat bat":
--   cat = 2, hat = 1, bat = 1  (4 terms, 3 distinct)
--   P(cat) = 2/4 = 0.5,  P(hat) = P(bat) = 1/4 = 0.25
--   H = -(0.5*log2(0.5) + 0.25*log2(0.25) + 0.25*log2(0.25)) = 1.5
-- #########################################################

-- Entropy of two rows pooled into one bag of terms:
-- cat = 2, hat = 1, bat = 1, so H = 1.5
SELECT hsql_entropy(txt) AS entropy_bits
FROM (
    VALUES 
    ('cat hat'),
    ('cat bat')
) AS v(txt);

-- Threshold test: return 1 if entropy >= 2, else -1
SELECT
    txt AS sample,
    hsql_entropy(txt) AS entropy_bits,
    CASE
        WHEN hsql_entropy(txt) >= 2 THEN 1
        ELSE -1
    END AS entropy_flag
FROM (
    VALUES
        ('cat hat cat bat'),       -- H = 1.5  -> -1
        ('red blue green yellow')  -- H = 2.0  -> 1
) AS v(txt)
GROUP BY txt;


-- Using entropy over event groups
-- Given rows (event_id, txt), GROUP BY event_id and apply hsql_entropy(txt). The
-- aggregate pools every txt value in the group into one bag of terms, then
-- returns the entropy in bits (base-2). Use CASE WHEN hsql_entropy(txt) >= <threshold> to
-- map each event to a flag (e.g. 1 if diverse enough, -1 otherwise).

-- Per-event entropy flag: 1 if entropy >= 2, else -1 (grouped by event_id)
SELECT
    event_id,
    /* hsql_entropy(txt) AS entropy_bits, */
    COUNT(DISTINCT username) AS "Username Count",
    CASE
        WHEN hsql_entropy(txt) >= 2 THEN 1
        ELSE -1
    END AS entropy_flag
FROM (
    VALUES
        (1, 'cat cat cat', 'user1'),
        (1, 'cat hat', 'user2'),
        (2, 'alpha beta gamma delta', 'user2'),
        (2, 'epsilon zeta eta theta', 'user3'),
        (3, 'run run jump', 'user3'),
        (3, 'run jump play', 'user3'),
        (4, 'red blue green yellow', 'user4'),
        (5, 'same same same', 'user5'),
        (5, 'same word repeat', 'user5'),
        (6, 'one two three four five six', 'user6'),
        (6, 'six five four three two one', 'user6')
) AS t(event_id, txt, username)
GROUP BY event_id
ORDER BY entropy_flag DESC, COUNT(DISTINCT username) DESC;


-- Same entropy from terms that were already extracted. to_tsvector is evaluated
-- while the rows are scanned, so a parallel plan divides it among its workers;
-- a stored tsvector column can be passed in the same way.
SELECT
    event_id,
    hsql_entropy(txt) AS from_text,
    hsql_entropy(to_tsvector('english', txt)) AS from_tsvector
FROM (
    VALUES
        (1, 'cat cat cat'),
        (1, 'cat hat'),
        (2, 'alpha beta gamma delta'),
        (2, 'epsilon zeta eta theta')
) AS t(event_id, txt)
GROUP BY event_id
ORDER BY event_id;
