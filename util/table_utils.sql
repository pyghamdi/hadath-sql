/* ################################################################################
hsql_table_exists_any_schema
--------------------------------------------------------------------------------
Checks whether a table exists in any user schema (excludes pg_catalog and
information_schema).

Parameters:
  table_name - Name of the table to check

Returns: TRUE if the table exists, FALSE otherwise
################################################################################ */
DROP FUNCTION IF EXISTS hsql_table_exists_any_schema(text) CASCADE;
DROP FUNCTION IF EXISTS util_table_exists_any_schema(text) CASCADE;
DROP FUNCTION IF EXISTS util_table_exists(text) CASCADE;

CREATE OR REPLACE FUNCTION hsql_table_exists_any_schema(table_name text)
RETURNS boolean
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
          AND tablename = lower(trim(table_name))
    );
END;
$$ LANGUAGE plpgsql;