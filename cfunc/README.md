# hadathsql_c: C implementation of the HadathSQL aggregates

This directory contains an optional PostgreSQL extension, `hadathsql_c`, with C
implementations of the two aggregates that `install.sql` installs in SQL:

| SQL implementation (`install.sql`) | C implementation (this extension) |
|---|---|
| `hsql_entropy` | `hsql_entropy_c` |
| `hsql_count_shared_terms` | `hsql_count_shared_terms_c` |

Both implementations can be installed in the same database; they have different
names, take the same arguments, and return the same values.

| | SQL implementation | C implementation |
|---|---|---|
| Installation | `install.sql`, no compilation | compiled and installed on the database server |
| Where it can be installed | any PostgreSQL database, including managed services | servers where you can install extensions (not most managed services) |
| Memory used by a group | grows with the size of its text | grows with its number of distinct terms |
| Cost of adding a row | `hsql_entropy`: constant; `hsql_count_shared_terms`: grows with the rows already in the group | constant |
| Parallel plans | workers collect the rows; the leader extracts and counts the terms | workers extract and count the terms; the leader merges the counts |
| Occurrences of a term counted per row (entropy) | at most 256 | all |

Use the SQL implementation when you cannot install extensions or when the
groups are small (up to a few thousand rows). Use the C implementation for
large groups, large tables, or parallel plans.

## Requirements

- A C compiler and `make`
- The PostgreSQL server development files, which provide `pg_config` and the
  server headers (package `postgresql-server-dev-<version>` on Debian/Ubuntu,
  `postgresql<version>-devel` on Red Hat; included with Homebrew and with
  source builds)
- Permission to write to the PostgreSQL installation directories

Tested with PostgreSQL 18.

## Build and install

From this directory:

```bash
make
make install        # may need sudo
```

`make` uses the `pg_config` that is first on `PATH`. To build for another
PostgreSQL installation, pass it explicitly:

```bash
make PG_CONFIG=/path/to/pg_config
make install PG_CONFIG=/path/to/pg_config
```

Then create the extension in each database that should use it:

```sql
CREATE EXTENSION hadathsql_c;
```

To remove it, run `DROP EXTENSION hadathsql_c;` in the database and
`make uninstall` in this directory.

## Usage

The C aggregates are called like the SQL aggregates:

```sql
-- Terms are extracted from the text with the English configuration
SELECT event_id,
       hsql_entropy_c(txt) AS term_entropy,
       hsql_count_shared_terms_c(txt, 2) AS shared_term_count
FROM candidate_events
GROUP BY event_id;

-- Terms that were already extracted, for example a stored tsvector column or
-- another text search configuration
SELECT event_id,
       hsql_entropy_c(txt_tsv) AS term_entropy,
       hsql_count_shared_terms_c(txt_tsv, 2) AS shared_term_count
FROM candidate_events
GROUP BY event_id;
```

## Tests

With HadathSQL (`install.sql`) and the extension installed, from the repository root:

```bash
psql -v ON_ERROR_STOP=1 -d <database> -f cfunc/tests/test_entropy_c.sql
psql -v ON_ERROR_STOP=1 -d <database> -f cfunc/tests/test_count_shared_terms_c.sql
```

Each script compares a C aggregate with expected values and with its SQL
counterpart, in serial and in parallel plans.

## Files

| File | Content |
|---|---|
| `hadathsql_c.c` | C source of the support functions of both aggregates |
| `hadathsql_c--1.0.sql` | SQL declarations run by `CREATE EXTENSION` |
| `hadathsql_c.control` | Extension control file |
| `Makefile` | PGXS build file |
