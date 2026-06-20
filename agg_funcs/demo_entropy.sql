-- #########################################################
-- Demo: word entropy (plain SQL)
--
-- Prerequisite: install the hsql_entropy aggregate first (run entropy.sql once).
--
-- Token counts for "cat hat cat bat" (whitespace split, as-is):
--   cat = 2, hat = 1, bat = 1  (4 tokens, V = 3)
--   P(cat) = 2/4 = 0.5,  P(hat) = P(bat) = 1/4 = 0.25
--   H(W) = -(0.5*log2(0.5) + 0.25*log2(0.25) + 0.25*log2(0.25)) = 1.5
-- #########################################################

-- Entropy value for one sample
SELECT hsql_entropy(txt) AS entropy_bits
-- FROM (VALUES ('cat hat cat bat')) AS v(txt);
FROM (
    VALUES 
    ('cat hat')
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
        ('cat hat cat bat'),  -- H = 1.5  -> -1
        ('a b c d')           -- H = 2.0  -> 1
) AS v(txt)
GROUP BY txt;


-- Using entropy over event groups
-- Given rows (event_id, txt), GROUP BY event_id and apply hsql_entropy(txt). The
-- aggregate pools every txt value in the group into one word-frequency bag, then
-- returns H(W) in bits (base-2). Use CASE WHEN hsql_entropy(txt) >= <threshold> to
-- map each event to a flag (e.g. 1 if diverse enough, -1 otherwise).

-- Per-event entropy flag: 1 if H(W) >= 2, else -1 (grouped by event_id)
SELECT
    event_id,
    /* hsql_entropy(txt) AS "H(W)", */
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