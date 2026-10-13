/*
 * hadathsql_c.c
 *
 * C implementation of the HadathSQL aggregates:
 *
 *   hsql_entropy_c             entropy of the terms of a group
 *   hsql_count_shared_terms_c  number of terms that occur in at least a given
 *                              number of rows of a group
 *
 * Both aggregates use the same state: a hash table that maps each term of a
 * group to a count. For hsql_entropy_c the count is the number of occurrences
 * of the term; for hsql_count_shared_terms_c it is the number of rows that
 * contain the term. The transition functions add the terms of one row to the
 * table in place, so the work per row does not depend on the size of the
 * group, and the memory used by a group grows with its number of distinct terms
 * rather than with the size of its text.
 *
 * The state is an in-memory structure (type "internal"), so parallel
 * aggregation needs the serialize and deserialize functions defined here: a
 * worker serializes its table, and the leader deserializes it and merges it
 * into its own table with the combine function. The combine, serialize, and
 * deserialize functions are shared by the two aggregates.
 *
 * See hadathsql_c--1.0.sql for the SQL declarations and README.md in this
 * directory for build instructions.
 */
#include "postgres.h"

#include <math.h>

#include "common/hashfn.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "libpq/pqformat.h"
#include "tsearch/ts_type.h"
#include "tsearch/ts_utils.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "varatt.h"

PG_MODULE_MAGIC;

/* A term is a byte string that is not null-terminated. */
typedef struct TermKey
{
	const char *data;
	int			len;
} TermKey;

typedef struct TermEntry
{
	TermKey		key;			/* the term; data is allocated in the state's context */
	int64		count;			/* occurrences of the term, or rows that contain it */
	int64		last_row;		/* last row in which the term was counted (see
								 * term_counts_add_once) */
	uint32		hash;			/* hash of the term, kept to speed up lookups */
	char		status;			/* used by simplehash */
} TermEntry;

#define SH_PREFIX termtab
#define SH_ELEMENT_TYPE TermEntry
#define SH_KEY_TYPE TermKey
#define SH_KEY key
#define SH_HASH_KEY(tb, k) hash_bytes((const unsigned char *) (k).data, (k).len)
#define SH_EQUAL(tb, a, b) ((a).len == (b).len && memcmp((a).data, (b).data, (a).len) == 0)
#define SH_STORE_HASH
#define SH_GET_HASH(tb, e) ((e)->hash)
#define SH_SCOPE static inline
#define SH_DECLARE
#define SH_DEFINE
#include "lib/simplehash.h"

/* Aggregate state: the term counts of one group. */
typedef struct TermCounts
{
	MemoryContext context;		/* context that holds the table and the terms */
	termtab_hash *terms;		/* term -> count */
	int64		total;			/* sum of the counts of all terms */
	int64		nrows;			/* rows processed; numbers the rows for last_row */
	int32		minimum;		/* threshold of hsql_count_shared_terms_c */
	bool		has_minimum;	/* false until a non-null threshold was seen */
	Oid			cfg;			/* text search configuration, looked up on first use */
} TermCounts;

/* Initial number of buckets; small, because a query can have many groups. */
#define INITIAL_TERMS 32

static TermCounts *
term_counts_create(MemoryContext context)
{
	TermCounts *state;

	state = (TermCounts *) MemoryContextAlloc(context, sizeof(TermCounts));
	state->context = context;
	state->terms = termtab_create(context, INITIAL_TERMS, NULL);
	state->total = 0;
	state->nrows = 0;
	state->minimum = 0;
	state->has_minimum = false;
	state->cfg = InvalidOid;
	return state;
}

/* Return the entry of a term, inserting it with a count of zero if it is new. */
static TermEntry *
term_counts_entry(TermCounts *state, const char *term, int len)
{
	TermKey		key;
	TermEntry  *entry;
	bool		found;

	key.data = term;
	key.len = len;
	entry = termtab_insert(state->terms, key, &found);
	if (!found)
	{
		char	   *copy = (char *) MemoryContextAlloc(state->context, len > 0 ? len : 1);

		memcpy(copy, term, len);
		entry->key.data = copy;
		entry->count = 0;
		entry->last_row = 0;
	}
	return entry;
}

/* Add "count" to the count of a term. */
static void
term_counts_add(TermCounts *state, const char *term, int len, int64 count)
{
	term_counts_entry(state, term, len)->count += count;
	state->total += count;
}

/*
 * Add one to the count of a term unless the term was already counted in row
 * "row". Rows are numbered from 1, so that a term which occurs several times
 * in a row is counted once for that row.
 */
static void
term_counts_add_once(TermCounts *state, const char *term, int len, int64 row)
{
	TermEntry  *entry = term_counts_entry(state, term, len);

	if (entry->last_row != row)
	{
		entry->last_row = row;
		entry->count++;
		state->total++;
	}
}

/*
 * Extract the terms of a text with the English text search configuration.
 * The result has one entry per occurrence of a term (unlike to_tsvector, which
 * keeps at most 256 positions of a term).
 */
static void
term_counts_parse(TermCounts *state, text *txt, ParsedText *prs)
{
	if (!OidIsValid(state->cfg))
		state->cfg = DatumGetObjectId(DirectFunctionCall1(regconfigin,
														  CStringGetDatum("english")));

	/* Same initial estimate of the number of words as to_tsvector. */
	prs->lenwords = VARSIZE_ANY_EXHDR(txt) / 6;
	if (prs->lenwords < 2)
		prs->lenwords = 2;
	else if (prs->lenwords > MaxAllocSize / sizeof(ParsedWord))
		prs->lenwords = MaxAllocSize / sizeof(ParsedWord);
	prs->curwords = 0;
	prs->pos = 0;
	prs->words = (ParsedWord *) palloc(sizeof(ParsedWord) * prs->lenwords);

	parsetext(state->cfg, prs, VARDATA_ANY(txt), VARSIZE_ANY_EXHDR(txt));
}

/*
 * Return the state passed as argument "argno", creating it in the aggregate's
 * memory context when it is NULL. Raises an error when the function is not
 * called as part of an aggregate.
 */
static TermCounts *
term_counts_arg(FunctionCallInfo fcinfo, int argno, const char *funcname)
{
	MemoryContext aggcontext;

	if (!AggCheckCallContext(fcinfo, &aggcontext))
		elog(ERROR, "%s called in non-aggregate context", funcname);

	if (PG_ARGISNULL(argno))
		return term_counts_create(aggcontext);
	return (TermCounts *) PG_GETARG_POINTER(argno);
}

/*
 * Transition function of hsql_entropy_c(tsvector): adds the terms of one
 * tsvector. The number of occurrences of a term in the row is the number of
 * its positions; a term without positions counts once.
 */
PG_FUNCTION_INFO_V1(hsql_entropy_c_tsvector_sfunc);
Datum
hsql_entropy_c_tsvector_sfunc(PG_FUNCTION_ARGS)
{
	TermCounts *state = term_counts_arg(fcinfo, 0, "hsql_entropy_c_tsvector_sfunc");

	if (!PG_ARGISNULL(1))
	{
		TSVector	tsv = PG_GETARG_TSVECTOR(1);
		WordEntry  *entries = ARRPTR(tsv);
		char	   *lexemes = STRPTR(tsv);

		for (int i = 0; i < tsv->size; i++)
		{
			int			npos = POSDATALEN(tsv, &entries[i]);

			term_counts_add(state, lexemes + entries[i].pos, entries[i].len,
							  npos > 0 ? npos : 1);
		}
	}
	PG_RETURN_POINTER(state);
}

/*
 * Transition function of hsql_entropy_c(text): extracts the terms of one text
 * and adds every occurrence of every term.
 */
PG_FUNCTION_INFO_V1(hsql_entropy_c_text_sfunc);
Datum
hsql_entropy_c_text_sfunc(PG_FUNCTION_ARGS)
{
	TermCounts *state = term_counts_arg(fcinfo, 0, "hsql_entropy_c_text_sfunc");

	if (!PG_ARGISNULL(1))
	{
		ParsedText	prs;

		term_counts_parse(state, PG_GETARG_TEXT_PP(1), &prs);
		for (int i = 0; i < prs.curwords; i++)
			term_counts_add(state, prs.words[i].word, prs.words[i].len, 1);
	}
	PG_RETURN_POINTER(state);
}

/*
 * Transition function of hsql_count_shared_terms_c(text, integer): extracts
 * the terms of one text and adds one to the count of each distinct term, so
 * that the count of a term is the number of rows that contain it.
 */
PG_FUNCTION_INFO_V1(hsql_count_shared_terms_c_text_sfunc);
Datum
hsql_count_shared_terms_c_text_sfunc(PG_FUNCTION_ARGS)
{
	TermCounts *state = term_counts_arg(fcinfo, 0, "hsql_count_shared_terms_c_text_sfunc");
	int64		row = ++state->nrows;

	if (!PG_ARGISNULL(2))
	{
		state->minimum = PG_GETARG_INT32(2);
		state->has_minimum = true;
	}
	if (!PG_ARGISNULL(1))
	{
		ParsedText	prs;

		term_counts_parse(state, PG_GETARG_TEXT_PP(1), &prs);
		for (int i = 0; i < prs.curwords; i++)
			term_counts_add_once(state, prs.words[i].word, prs.words[i].len, row);
	}
	PG_RETURN_POINTER(state);
}

/*
 * Transition function of hsql_count_shared_terms_c(tsvector, integer): adds
 * one to the count of each term of one tsvector. The terms of a tsvector are
 * distinct.
 */
PG_FUNCTION_INFO_V1(hsql_count_shared_terms_c_tsvector_sfunc);
Datum
hsql_count_shared_terms_c_tsvector_sfunc(PG_FUNCTION_ARGS)
{
	TermCounts *state = term_counts_arg(fcinfo, 0, "hsql_count_shared_terms_c_tsvector_sfunc");

	state->nrows++;
	if (!PG_ARGISNULL(2))
	{
		state->minimum = PG_GETARG_INT32(2);
		state->has_minimum = true;
	}
	if (!PG_ARGISNULL(1))
	{
		TSVector	tsv = PG_GETARG_TSVECTOR(1);
		WordEntry  *entries = ARRPTR(tsv);
		char	   *lexemes = STRPTR(tsv);

		for (int i = 0; i < tsv->size; i++)
			term_counts_add(state, lexemes + entries[i].pos, entries[i].len, 1);
	}
	PG_RETURN_POINTER(state);
}

/*
 * Combine function of both aggregates: adds the term counts of the second
 * state to the first. The second state is left unchanged.
 */
PG_FUNCTION_INFO_V1(hsql_term_counts_combine);
Datum
hsql_term_counts_combine(PG_FUNCTION_ARGS)
{
	TermCounts *state = term_counts_arg(fcinfo, 0, "hsql_term_counts_combine");

	if (!PG_ARGISNULL(1))
	{
		TermCounts *other = (TermCounts *) PG_GETARG_POINTER(1);
		termtab_iterator iter;
		TermEntry  *entry;

		termtab_start_iterate(other->terms, &iter);
		while ((entry = termtab_iterate(other->terms, &iter)) != NULL)
			term_counts_add(state, entry->key.data, entry->key.len, entry->count);

		/*
		 * Row numbers of the merged state continue after those of both
		 * states, so the last_row marks of existing entries stay in the past.
		 */
		state->nrows += other->nrows;
		if (!state->has_minimum && other->has_minimum)
		{
			state->minimum = other->minimum;
			state->has_minimum = true;
		}
	}
	PG_RETURN_POINTER(state);
}

/*
 * Serialize function of both aggregates: converts a state to bytea so that a
 * parallel worker can send it to the leader. Format: number of rows, whether
 * a threshold is set, the threshold, the number of terms, then for each term
 * its length, its bytes, and its count.
 */
PG_FUNCTION_INFO_V1(hsql_term_counts_serialize);
Datum
hsql_term_counts_serialize(PG_FUNCTION_ARGS)
{
	TermCounts *state;
	StringInfoData buf;
	termtab_iterator iter;
	TermEntry  *entry;

	if (!AggCheckCallContext(fcinfo, NULL))
		elog(ERROR, "hsql_term_counts_serialize called in non-aggregate context");

	state = (TermCounts *) PG_GETARG_POINTER(0);

	pq_begintypsend(&buf);
	pq_sendint64(&buf, state->nrows);
	pq_sendbyte(&buf, state->has_minimum ? 1 : 0);
	pq_sendint32(&buf, state->minimum);
	pq_sendint32(&buf, state->terms->members);
	termtab_start_iterate(state->terms, &iter);
	while ((entry = termtab_iterate(state->terms, &iter)) != NULL)
	{
		pq_sendint32(&buf, entry->key.len);
		pq_sendbytes(&buf, entry->key.data, entry->key.len);
		pq_sendint64(&buf, entry->count);
	}
	PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/*
 * Deserialize function of both aggregates: rebuilds a state from the bytea
 * written by the serialize function. The state is built in the current memory
 * context; the combine function copies its terms into the leader's state.
 */
PG_FUNCTION_INFO_V1(hsql_term_counts_deserialize);
Datum
hsql_term_counts_deserialize(PG_FUNCTION_ARGS)
{
	bytea	   *serialized;
	StringInfoData buf;
	TermCounts *state;
	int32		nterms;

	if (!AggCheckCallContext(fcinfo, NULL))
		elog(ERROR, "hsql_term_counts_deserialize called in non-aggregate context");

	serialized = PG_GETARG_BYTEA_PP(0);

	/* Copy the bytes into a StringInfo so that they can be read with pq_getmsg*. */
	initStringInfo(&buf);
	appendBinaryStringInfo(&buf, VARDATA_ANY(serialized), VARSIZE_ANY_EXHDR(serialized));

	state = term_counts_create(CurrentMemoryContext);
	state->nrows = pq_getmsgint64(&buf);
	state->has_minimum = pq_getmsgbyte(&buf) != 0;
	state->minimum = pq_getmsgint(&buf, 4);
	nterms = pq_getmsgint(&buf, 4);
	for (int32 i = 0; i < nterms; i++)
	{
		int32		len = pq_getmsgint(&buf, 4);
		const char *term = pq_getmsgbytes(&buf, len);
		int64		count = pq_getmsgint64(&buf);

		term_counts_add(state, term, len, count);
	}
	pq_getmsgend(&buf);
	pfree(buf.data);

	PG_RETURN_POINTER(state);
}

/*
 * Final function of hsql_entropy_c: the entropy, in bits, of the term distribution. A group
 * with no terms (or no rows) returns 0. The state is not modified.
 */
PG_FUNCTION_INFO_V1(hsql_entropy_c_final);
Datum
hsql_entropy_c_final(PG_FUNCTION_ARGS)
{
	TermCounts *state;
	termtab_iterator iter;
	TermEntry  *entry;
	double		total;
	double		entropy = 0.0;

	if (!AggCheckCallContext(fcinfo, NULL))
		elog(ERROR, "hsql_entropy_c_final called in non-aggregate context");

	if (PG_ARGISNULL(0))
		PG_RETURN_FLOAT8(0.0);

	state = (TermCounts *) PG_GETARG_POINTER(0);
	if (state->total == 0)
		PG_RETURN_FLOAT8(0.0);

	total = (double) state->total;
	termtab_start_iterate(state->terms, &iter);
	while ((entry = termtab_iterate(state->terms, &iter)) != NULL)
	{
		double		p = (double) entry->count / total;

		/* p * log2(1 / p), so that a single term gives 0 and not -0 */
		entropy += p * log2(total / (double) entry->count);
	}
	PG_RETURN_FLOAT8(entropy);
}

/*
 * Final function of hsql_count_shared_terms_c: the number of terms whose
 * count (the number of rows that contain the term) is at least the threshold.
 * A group with no rows, or for which no threshold was given, returns 0. The
 * state is not modified.
 */
PG_FUNCTION_INFO_V1(hsql_count_shared_terms_c_final);
Datum
hsql_count_shared_terms_c_final(PG_FUNCTION_ARGS)
{
	TermCounts *state;
	termtab_iterator iter;
	TermEntry  *entry;
	int32		shared = 0;

	if (!AggCheckCallContext(fcinfo, NULL))
		elog(ERROR, "hsql_count_shared_terms_c_final called in non-aggregate context");

	if (PG_ARGISNULL(0))
		PG_RETURN_INT32(0);

	state = (TermCounts *) PG_GETARG_POINTER(0);
	if (!state->has_minimum)
		PG_RETURN_INT32(0);

	termtab_start_iterate(state->terms, &iter);
	while ((entry = termtab_iterate(state->terms, &iter)) != NULL)
	{
		if (entry->count >= state->minimum)
			shared++;
	}
	PG_RETURN_INT32(shared);
}
