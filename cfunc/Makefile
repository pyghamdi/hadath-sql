# Builds and installs the hadathsql_c extension with PGXS.
#
#   make                  compile
#   make install          copy the library and the extension files into the
#                         PostgreSQL installation (may need sudo)
#
# The PostgreSQL installation is the one whose pg_config is first on PATH.
# To build for another one: make PG_CONFIG=/path/to/pg_config

MODULES = hadathsql_c
EXTENSION = hadathsql_c
DATA = hadathsql_c--1.0.sql

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
