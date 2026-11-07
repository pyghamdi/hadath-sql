-- #########################################################
-- Tests for hsql_overlap, hsql_has_keyword, hsql_event_type, and
-- hsql_train_event_type (event_type/event_type.sql).
--
-- HOW TO RUN (from repository root):
--
--   psql -v ON_ERROR_STOP=1 -d <database> -f event_type/tests/test_event_type.sql
--
-- PREREQUISITES
--   - HadathSQL is installed in the database (install.sql). If hsql_event_type
--     is missing, this script loads event_type/event_type.sql.
--   - English full-text configuration is available (to_tsvector('english', ...)).
--
-- FLOW
--   1) Check hsql_overlap and hsql_has_keyword on small texts.
--   2) Train a classifier on a few labeled rows and check hsql_event_type on
--      the rows of the example of the paper.
--   3) Check that the text functions are inlined and that hsql_has_keyword
--      uses a GIN index.
--   The script raises an error if any check fails. It creates temporary
--   tables, and it stores a classifier under the event type
--   '_test_earthquake', which it deletes at the end.
-- #########################################################

\set ON_ERROR_STOP on

-- Load the module only when it is not installed yet. The module files create
-- their objects without dropping existing ones, so loading one twice fails.
SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'hsql_event_type') AS hsql_missing \gset
\if :hsql_missing
\ir ../event_type.sql
\endif

\echo '>>> running event_type tests'

CREATE TEMP TABLE _event_type_test_results (
    test_id text PRIMARY KEY,
    want text,
    got text
);

-- ---------------------------------------------------------
-- 1) Keyword match
-- ---------------------------------------------------------
INSERT INTO _event_type_test_results (test_id, want, got) VALUES
    ('overlap_both_keywords', '2',
        hsql_overlap('Earthquake! Everything is shaking', 'earthquake, shaking')::text),
    ('overlap_one_keyword', '1',
        hsql_overlap('Now it is shaking', 'earthquake, shaking')::text),
    ('overlap_no_keyword', '0',
        hsql_overlap('Heavy rain downtown this morning', 'earthquake, shaking')::text),
    -- A keyword that is repeated in the text counts once.
    ('overlap_repeated_keyword', '1',
        hsql_overlap('earthquake earthquake', 'earthquake, shaking')::text),
    -- shakes and shaking are the same term after stemming.
    ('overlap_stemming', '1',
        hsql_overlap('The ground shakes', 'shaking')::text),
    ('overlap_keywords_separated_by_spaces', '2',
        hsql_overlap('earthquake shaking', 'earthquake shaking')::text),
    ('overlap_empty_keywords', '0',
        hsql_overlap('earthquake', '')::text),
    ('overlap_null_text', NULL,
        hsql_overlap(NULL::text, 'earthquake')::text),
    ('overlap_tsvector', '1',
        hsql_overlap(to_tsvector('english', 'Now it is shaking'), 'earthquake, shaking')::text),
    ('has_keyword_true', 'true',
        hsql_has_keyword('Now it is shaking', 'earthquake, shaking')::text),
    ('has_keyword_false', 'false',
        hsql_has_keyword('Heavy rain downtown', 'earthquake, shaking')::text),
    -- A keyword with characters that have a meaning in a tsquery.
    ('has_keyword_special_characters', 'true',
        hsql_has_keyword('see a/b and o''brien', 'a/b')::text);

-- ---------------------------------------------------------
-- 2) Classifier
-- ---------------------------------------------------------
CREATE TEMP TABLE _event_type_test_labeled (txt text, is_earthquake boolean);

INSERT INTO _event_type_test_labeled VALUES
    ('Earthquake! felt it right now', true),
    ('earthquake', true),
    ('Earthquake!!', true),
    ('Now it is shaking, strong tremor', true),
    ('big earthquake felt now, the house is shaking', true),
    ('I am attending an Earthquake Conference', false),
    ('Someone is shaking hands with my boss', false),
    ('earthquake conference talk about hands', false),
    ('Heavy rain downtown this morning', false),
    ('a row without a label', NULL);

SELECT hsql_train_event_type('_test_earthquake', '_event_type_test_labeled', 'txt', 'is_earthquake') AS model_terms;

-- The rows of the example of the paper.
CREATE TEMP TABLE _event_type_test_docs (id integer, txt text, want boolean);

INSERT INTO _event_type_test_docs VALUES
    (1, 'Earthquake!', true),
    (2, 'Now it is shaking', true),
    (3, 'I am attending an Earthquake Conference', false),
    (4, 'Someone is shaking hands with my boss', false),
    (5, 'Heavy rain downtown this morning', false);

INSERT INTO _event_type_test_results (test_id, want, got)
SELECT 'event_type_row_' || id, want::text, hsql_event_type(txt, '_test_earthquake')::text
FROM _event_type_test_docs;

INSERT INTO _event_type_test_results (test_id, want, got)
SELECT 'event_type_tsvector_row_' || id, want::text,
       hsql_event_type(to_tsvector('english', txt), '_test_earthquake')::text
FROM _event_type_test_docs;

INSERT INTO _event_type_test_results (test_id, want, got)
SELECT 'event_type_with_keywords_row_' || id, want::text,
       hsql_event_type(txt, '_test_earthquake', 'earthquake, shaking')::text
FROM _event_type_test_docs;

INSERT INTO _event_type_test_results (test_id, want, got) VALUES
    ('event_type_null_text', NULL,
        hsql_event_type(NULL::text, '_test_earthquake')::text),
    -- 'felt' and 'now' are positive terms, but the row has no keyword.
    ('event_type_with_keywords_requires_keyword', 'true,false',
        hsql_event_type('felt it right now', '_test_earthquake')::text || ',' ||
        hsql_event_type('felt it right now', '_test_earthquake', 'earthquake, shaking')::text),
    -- Training again replaces the classifier instead of adding to it.
    ('train_replaces_classifier', 'true',
        (SELECT (COUNT(*) = hsql_train_event_type('_test_earthquake', '_event_type_test_labeled', 'txt', 'is_earthquake') + 1)::text
         FROM hsql_event_type_model WHERE event_type = '_test_earthquake'));

-- An event type without a classifier, and a training table with one label.
DO $$
BEGIN
    BEGIN
        PERFORM hsql_event_type('Earthquake!', '_test_no_such_type');
        RAISE EXCEPTION 'TEST FAILED: unknown event type did not raise an error';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'no classifier for the event type%' THEN
            RAISE;
        END IF;
    END;

    CREATE TEMP TABLE _event_type_test_one_label AS
    SELECT txt, is_earthquake FROM _event_type_test_labeled WHERE is_earthquake;
    BEGIN
        PERFORM hsql_train_event_type('_test_one_label', '_event_type_test_one_label', 'txt', 'is_earthquake');
        RAISE EXCEPTION 'TEST FAILED: training with one label did not raise an error';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%needs rows of both labels%' THEN
            RAISE;
        END IF;
    END;
END;
$$;

-- ---------------------------------------------------------
-- 3) Inlining and index use
-- ---------------------------------------------------------
CREATE TEMP TABLE _event_type_test_plans (test_id text, plan text);

CREATE INDEX _event_type_test_docs_idx ON _event_type_test_docs USING gin (to_tsvector('english', txt));

DO $$
DECLARE
    v_line text;
    v_plan text;
BEGIN
    -- After inlining, the plan does not call the text functions.
    v_plan := '';
    FOR v_line IN EXPLAIN (COSTS OFF)
        SELECT * FROM _event_type_test_docs
        WHERE hsql_event_type(txt, '_test_earthquake', 'earthquake, shaking')
    LOOP
        v_plan := v_plan || v_line || E'\n';
    END LOOP;
    INSERT INTO _event_type_test_plans VALUES ('inlined', v_plan);

    SET LOCAL enable_seqscan = off;
    v_plan := '';
    FOR v_line IN EXPLAIN (COSTS OFF)
        SELECT * FROM _event_type_test_docs
        WHERE hsql_has_keyword(txt, 'earthquake, shaking')
    LOOP
        v_plan := v_plan || v_line || E'\n';
    END LOOP;
    INSERT INTO _event_type_test_plans VALUES ('gin_index', v_plan);
END;
$$;

INSERT INTO _event_type_test_results (test_id, want, got)
SELECT 'text_functions_are_inlined', 'true',
       (plan NOT LIKE '%hsql_overlap%'
        AND plan NOT LIKE '%hsql_event_type(txt%'
        AND plan LIKE '%hsql_event_type(to_tsvector(%')::text
FROM _event_type_test_plans WHERE test_id = 'inlined';

INSERT INTO _event_type_test_results (test_id, want, got)
SELECT 'has_keyword_uses_gin_index', 'true', (plan LIKE '%_event_type_test_docs_idx%')::text
FROM _event_type_test_plans WHERE test_id = 'gin_index';

-- ---------------------------------------------------------
-- Report
-- ---------------------------------------------------------
DELETE FROM hsql_event_type_model WHERE event_type = '_test_earthquake';

SELECT test_id, want, got, (want IS NOT DISTINCT FROM got) AS passed
FROM _event_type_test_results
ORDER BY test_id;

DO $$
DECLARE
    v_failed integer;
BEGIN
    SELECT COUNT(*) INTO v_failed
    FROM _event_type_test_results
    WHERE want IS DISTINCT FROM got;

    IF v_failed > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: % event_type check(s) failed', v_failed;
    END IF;
    RAISE NOTICE 'All event_type tests passed';
END;
$$;
