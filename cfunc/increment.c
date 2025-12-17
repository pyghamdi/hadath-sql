/* src/tutorial/increment.c */

/******************************************************************************
  This is a user-defined function that can be bound to a Postgres backend
  and called by Postgres to execute SQL functions of the same name.

  The calling format for this function is defined by the CREATE FUNCTION
  SQL statement that binds it to the backend.
*****************************************************************************/

#include "/Users/rami/Workspace/PostgreSQL/pg17.5_install/include/postgresql/server/postgres.h"			/* general Postgres declarations */
#include "/Users/rami/Workspace/PostgreSQL/pg17.5_install/include/postgresql/server/fmgr.h"				/* for function manager macros */

PG_MODULE_MAGIC;

/* By Value - Increment Function */

PG_FUNCTION_INFO_V1(increment);

Datum
increment(PG_FUNCTION_ARGS)
{
	int32		arg = PG_GETARG_INT32(0);

	PG_RETURN_INT32(arg + 1);
}
