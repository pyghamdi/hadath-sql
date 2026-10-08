/* ################################################################################
hsql_table_exists_any_schema
--------------------------------------------------------------------------------
Checks whether a table exists in any user schema (excludes pg_catalog and
information_schema). Used by the clustering functions before they create
their output tables.

Parameters:
  table_name - Name of the table to check, without a schema. The name is
               trimmed and lowercased before the lookup.

Returns: TRUE if the table exists, FALSE otherwise

Example:
  SELECT hsql_table_exists_any_schema('docs');
################################################################################ */

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