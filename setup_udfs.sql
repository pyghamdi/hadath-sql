-- Run TF-IDF and clustering DDL in dependency order.
--
-- Loads:
--   1) util helpers (e.g. hsql_table_exists_any_schema)
--   2) TF-IDF core UDFs and `tfidf_weight` type (`hsql_*` table builders in tf_idf.sql)
--   3) Aggregate UDAs: count_shared_terms, entropy (agg_funcs/)
--   4) Single-pass clustering (`hsql_*` in single_pass_clustering/sp_clustering.sql)
--
-- This file uses psql meta-commands (\ir, \echo). Run it with psql from the
-- repository root, for example:
--   psql -v ON_ERROR_STOP=1 -d <database> -f setup_udfs.sql
--
-- Plain SQL executed on the server cannot load other files; psql is the usual way
-- to chain scripts. \ir paths are resolved relative to this file's directory.

\set ON_ERROR_STOP on

\echo '>>> util/table_utils.sql'
\ir util/table_utils.sql

\echo '>>> tf_idf/tf_idf.sql'
\ir tf_idf/tf_idf.sql

\echo '>>> agg_funcs/count_shared_terms.sql'
\ir agg_funcs/count_shared_terms.sql

\echo '>>> agg_funcs/entropy.sql'
\ir agg_funcs/entropy.sql

\echo '>>> single_pass_clustering/sp_clustering.sql'
\ir single_pass_clustering/sp_clustering.sql

\echo '>>> done.'
