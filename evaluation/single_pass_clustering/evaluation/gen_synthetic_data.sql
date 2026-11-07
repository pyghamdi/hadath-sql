-- Synthetic corpus for the single-pass clustering experiment: sp_docs(doc_id, txt, ts).
-- Each document belongs to one of :topics topics (chosen uniformly at random) and
-- consists of :topic_words words drawn with replacement from its topic's vocabulary
-- (:vocab words per topic, disjoint across topics) and :bg_words words drawn with
-- replacement from a background vocabulary of :bg_vocab words shared by all topics.
-- Words are letter strings (digits mapped to letters; 'x' prefix for topic words,
-- 'y' for background words) so that to_tsvector keeps them and none is a stop word.
-- Documents are timestamped one minute apart in doc_id order.
--
-- Settings (datasets Synthetic-Tweets and Synthetic-News):
--   synthetic_tweets: -v topic_words=8   -v vocab=12  -v bg_words=4   -v bg_vocab=2000
--   synthetic_news:   -v topic_words=200 -v vocab=200 -v bg_words=200 -v bg_vocab=20000
-- Usage: psql -v n=1000 -v topics=50 -v seed=0.42 -v topic_words=8 -v vocab=12 \
--             -v bg_words=4 -v bg_vocab=2000 -f gen_synthetic_data.sql

DROP TABLE IF EXISTS sp_docs;
SELECT setseed(:seed);
CREATE TABLE sp_docs AS
WITH d AS (
  SELECT g AS doc_id, 1 + floor(random() * :topics)::int AS topic
  FROM generate_series(1, :n) g
)
SELECT d.doc_id,
       (SELECT string_agg(w, ' ')
        FROM (
          SELECT 'x' || translate((d.topic * 1000 + floor(random() * :vocab)::int)::text,
                                  '0123456789', 'qwrzjkvbpm') AS w
          FROM generate_series(1, :topic_words) s WHERE s > 0 * d.doc_id
          UNION ALL
          SELECT 'y' || translate((floor(random() * :bg_vocab)::int)::text,
                                  '0123456789', 'qwrzjkvbpm')
          FROM generate_series(1, :bg_words) s WHERE s > 0 * d.doc_id
        ) words) AS txt,
       timestamp '2020-01-01' + d.doc_id * interval '1 minute' AS ts
FROM d;
ALTER TABLE sp_docs ADD PRIMARY KEY (doc_id);
