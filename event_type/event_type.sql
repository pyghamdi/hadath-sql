/*
################################################################################
UDFs for events of a specific type (event_type.sql)
################################################################################
Selects the rows that report an event of a known type, such as an earthquake,
in two stages: a keyword match that keeps the rows containing a keyword of the
event type, and a classifier that decides whether a row reports an occurrence
of the event.

Defines:
  hsql_overlap(txt text, keywords text)                RETURNS integer
  hsql_overlap(tsv tsvector, keywords text)            RETURNS integer
  hsql_has_keyword(txt text, keywords text)            RETURNS boolean
  hsql_event_type(txt text, type text)                 RETURNS boolean
  hsql_event_type(tsv tsvector, type text)             RETURNS boolean
  hsql_event_type(txt text, type text, keywords text)  RETURNS boolean
  hsql_train_event_type(type text, source_tbl text, txt_col text, label_col text)
                                                       RETURNS integer
  hsql_event_type_model                                table: the trained classifiers

Parameters:
  txt         - Text of one row.
  tsv         - Terms of one row, as returned by to_tsvector.
  keywords    - Keywords of the event type in one string, separated by spaces
                or commas, for example 'earthquake, shaking'.
  type        - Name of the event type, for example 'earthquake'. It identifies
                the classifier that hsql_train_event_type stored under this name.
  source_tbl  - Name of the table with the labeled rows used for training.
  txt_col     - Name of its text column.
  label_col   - Name of its boolean column: true if the row reports an event of
                the type. Rows with a NULL label are ignored.

hsql_overlap returns the number of keywords that appear in the row.
hsql_has_keyword returns true if at least one keyword appears in the row; it
selects the same rows as hsql_overlap(...) > 0 and can use a GIN index (see
Notes). hsql_event_type returns true if the classifier of the event type labels
the row as reporting an event of that type. With a third argument, it first
applies the keyword match and classifies only the rows that pass it, so
hsql_event_type(txt, type, keywords) selects the same rows as
hsql_overlap(txt, keywords) > 0 AND hsql_event_type(txt, type).

The functions that take text extract the terms with PostgreSQL full-text
search, to_tsvector('english', txt), which lowercases the text, removes
punctuation and English stop words, and stems the remaining words. The
keywords are processed in the same way, so the keyword 'shaking' also matches
'shake' and 'shakes'. A NULL text or tsvector returns NULL.

Examples:
  -- Returns 2: both keywords appear in the text
  SELECT hsql_overlap('Earthquake! Everything is shaking', 'earthquake, shaking');

  -- Train the classifier of the type 'earthquake' from labeled rows
  SELECT hsql_train_event_type('earthquake', 'labeled_docs', 'txt', 'is_earthquake');

  -- Rows that report an earthquake
  SELECT *
  FROM docs
  WHERE hsql_overlap(txt, 'earthquake, shaking') > 0
    AND hsql_event_type(txt, 'earthquake');

  -- The same rows with one call
  SELECT * FROM docs
  WHERE hsql_event_type(txt, 'earthquake', 'earthquake, shaking');

  -- The same rows, with the keyword match answered by an index
  CREATE INDEX docs_txt_idx ON docs USING gin (to_tsvector('english', txt));
  SELECT * FROM docs
  WHERE hsql_has_keyword(txt, 'earthquake, shaking')
    AND hsql_event_type(txt, 'earthquake');

Classifier:
  The classifier is a naive Bayes classifier over the terms of a row. It is a
  linear model: every term has a weight, and a row is labeled as reporting the
  event if the sum of the weights of its terms plus a bias is greater than 0.
  A term counts once per row, and a term that did not occur in the training
  rows has weight 0. hsql_train_event_type computes, with add-one smoothing,
    weight(term) = ln P(term | reports the event) - ln P(term | does not)
    bias         = ln(number of positive rows / number of negative rows)
  and stores them in hsql_event_type_model. It is a prototype: it uses only the
  terms of the row as features. Any other linear model over the terms, such as
  a linear SVM trained outside the database, can be used by writing its
  weights to hsql_event_type_model; hsql_event_type only reads that table.

Notes:
  - hsql_overlap, hsql_has_keyword, and the hsql_event_type functions that take
    text are single SQL expressions, which PostgreSQL inlines into the calling
    query. With a constant keyword list, the keywords are processed once, while
    the query is planned. Inlining stops if a function becomes STRICT, gets a
    SET clause, or its body is no longer a single expression.
  - After inlining, hsql_has_keyword(txt, keywords) is the expression
    to_tsvector('english', txt) @@ <tsquery>, which can use a GIN index on
    to_tsvector('english', txt). hsql_overlap(...) > 0 cannot use an index.
  - hsql_event_type(tsvector, text) looks up the terms of every row it is given
    in hsql_event_type_model. It is declared with a high cost, so that the
    planner evaluates the other predicates of a WHERE clause before it.
  - Use the tsvector functions when the table already stores a tsvector column,
    so that the terms are not extracted again for every row.
  - An event type without a trained classifier raises an error.
################################################################################
*/


-- The trained classifiers: one row per term of an event type with the weight
-- of the term, and one row with the empty term that holds the bias. A term
-- returned by to_tsvector is never empty, so the empty term is free.
-- The terms are compared byte by byte (collation "C"), which is all that
-- looking up a term needs and is several times faster than comparing them
-- with the collation of the database.
CREATE TABLE hsql_event_type_model (
    event_type text COLLATE "C" NOT NULL,
    term text COLLATE "C" NOT NULL,
    weight double precision NOT NULL,
    PRIMARY KEY (event_type, term)
);

-- hsql_event_type looks up every term of a row. A hash index on the term
-- answers these lookups faster than the index of the primary key.
CREATE INDEX hsql_event_type_model_term_idx ON hsql_event_type_model USING hash (term);


-- Returns the tsquery that matches a row containing at least one keyword.
-- Each term is quoted, so that a term with characters that have a meaning in
-- a tsquery is taken literally. A keyword list without terms (empty, or only
-- stop words) gives an empty tsquery, which matches no row.
CREATE OR REPLACE FUNCTION hsql_keywords_tsquery(keywords text)
RETURNS tsquery
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT COALESCE(
        string_agg(
            '''' || replace(replace(k.term, '\', '\\'), '''', '''''') || '''',
            ' | '),
        '')::tsquery
    FROM unnest(tsvector_to_array(to_tsvector('english', keywords))) AS k(term);
$$;


-- ts_delete removes from the keywords the ones that appear in the row, so the
-- difference of the two lengths is the number of keywords that appear in it.
CREATE OR REPLACE FUNCTION hsql_overlap(tsv tsvector, keywords text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT length(to_tsvector('english', keywords))
         - length(ts_delete(to_tsvector('english', keywords), tsvector_to_array(tsv)));
$$;


CREATE OR REPLACE FUNCTION hsql_overlap(txt text, keywords text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT hsql_overlap(to_tsvector('english', txt), keywords);
$$;


-- The left operand has to stay to_tsvector('english', txt) for the planner to
-- match it with a GIN index on that expression.
CREATE OR REPLACE FUNCTION hsql_has_keyword(txt text, keywords text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT to_tsvector('english', txt) @@ hsql_keywords_tsquery(keywords);
$$;


-- Raises the error for an event type without a trained classifier; called only
-- when hsql_event_type finds no row of the type in hsql_event_type_model.
CREATE OR REPLACE FUNCTION hsql_unknown_event_type(type text)
RETURNS double precision
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
BEGIN
    RAISE EXCEPTION 'no classifier for the event type "%"; train one with hsql_train_event_type', type;
END;
$$;


-- Sums the weights of the terms of the row and the bias, which is stored
-- under the empty term. The bias row exists for every trained type, so a NULL
-- sum means that the type has no classifier.
CREATE OR REPLACE FUNCTION hsql_event_type(tsv tsvector, type text)
RETURNS boolean
LANGUAGE sql
STABLE
PARALLEL SAFE
COST 1000
AS $$
    SELECT CASE
        WHEN tsv IS NULL THEN NULL
        ELSE COALESCE(sum(m.weight), hsql_unknown_event_type(type)) > 0
    END
    FROM unnest(array_append(tsvector_to_array(tsv), '')) AS t(term)
    JOIN hsql_event_type_model AS m ON m.term = t.term AND m.event_type = type;
$$;


CREATE OR REPLACE FUNCTION hsql_event_type(txt text, type text)
RETURNS boolean
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT hsql_event_type(to_tsvector('english', txt), type);
$$;


-- The keyword match and the classifier in one call. After inlining, the two
-- operands of AND are separate predicates of the calling query, so the plan is
-- the same as for hsql_overlap(...) > 0 AND hsql_event_type(txt, type).
CREATE OR REPLACE FUNCTION hsql_event_type(txt text, type text, keywords text)
RETURNS boolean
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT hsql_overlap(txt, keywords) > 0 AND hsql_event_type(txt, type);
$$;


-- Trains the classifier of an event type from a table of labeled rows and
-- stores it in hsql_event_type_model, replacing the classifier that was stored
-- under the same type. Returns the number of terms of the classifier.
CREATE OR REPLACE FUNCTION hsql_train_event_type(
    type text,
    source_tbl text,
    txt_col text,
    label_col text
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    n_pos bigint;
    n_neg bigint;
    n_terms integer;
BEGIN
    IF type IS NULL OR type = '' THEN
        RAISE EXCEPTION 'type must be a non-empty name';
    END IF;

    EXECUTE format(
        'SELECT COUNT(*) FILTER (WHERE %2$I), COUNT(*) FILTER (WHERE NOT %2$I) FROM %1$I',
        source_tbl, label_col
    ) INTO n_pos, n_neg;

    IF n_pos = 0 OR n_neg = 0 THEN
        RAISE EXCEPTION 'table % needs rows of both labels in column % (got % true and % false)',
            source_tbl, label_col, n_pos, n_neg;
    END IF;

    DELETE FROM hsql_event_type_model AS m WHERE m.event_type = type;

    -- pos and neg of a term are the numbers of positive and negative rows that
    -- contain it; unnest of the term array returns each term of a row once.
    EXECUTE format(
        $q$
        WITH term_counts AS (
            SELECT t.term,
                   COUNT(*) FILTER (WHERE src.%3$I) AS pos,
                   COUNT(*) FILTER (WHERE NOT src.%3$I) AS neg
            FROM %1$I AS src
            CROSS JOIN LATERAL unnest(tsvector_to_array(to_tsvector('english', src.%2$I))) AS t(term)
            WHERE src.%3$I IS NOT NULL
            GROUP BY t.term
        ),
        totals AS (
            SELECT SUM(pos) AS pos, SUM(neg) AS neg, COUNT(*) AS vocabulary
            FROM term_counts
        )
        INSERT INTO hsql_event_type_model (event_type, term, weight)
        SELECT $1,
               c.term,
               ln((c.pos + 1.0) / (t.pos + t.vocabulary))
             - ln((c.neg + 1.0) / (t.neg + t.vocabulary))
        FROM term_counts AS c
        CROSS JOIN totals AS t
        $q$,
        source_tbl, txt_col, label_col
    ) USING type;
    GET DIAGNOSTICS n_terms = ROW_COUNT;

    INSERT INTO hsql_event_type_model (event_type, term, weight)
    VALUES (type, '', ln(n_pos::double precision / n_neg));

    RETURN n_terms;
END;
$$;
