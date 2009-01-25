/*
 * debversion: PostgreSQL functions for debversion type
 * Copyright © 2001 James Troup <james@nocrew.org>
 * Copyright © 2008-2009 Roger Leigh <rleigh@debian.org>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 ***********************************************************************/

#include <apt-pkg/debversion.h>

extern "C"
{
#include <postgres.h>
#include <fmgr.h>
#include <access/hash.h>

#ifdef PG_MODULE_MAGIC
  PG_MODULE_MAGIC;
#endif

  extern Datum debversion_cmp (PG_FUNCTION_ARGS);
  extern Datum debversion_hash (PG_FUNCTION_ARGS);
  extern Datum debversion_eq (PG_FUNCTION_ARGS);
  extern Datum debversion_ne (PG_FUNCTION_ARGS);
  extern Datum debversion_gt (PG_FUNCTION_ARGS);
  extern Datum debversion_ge (PG_FUNCTION_ARGS);
  extern Datum debversion_lt (PG_FUNCTION_ARGS);
  extern Datum debversion_le (PG_FUNCTION_ARGS);
  extern Datum debversion_smaller (PG_FUNCTION_ARGS);
  extern Datum debversion_larger (PG_FUNCTION_ARGS);
}

namespace
{
  int32
  debversioncmp (text *left,
		 text *right)
  {
    int32 result;
    int32 lsize, rsize;
    char *lstr, *rstr;

    lsize = VARSIZE_ANY_EXHDR(left);
    lstr = (char *) palloc(lsize+1);
    memcpy(lstr, VARDATA_ANY(left), lsize);
    lstr[lsize] = '\0';

    rsize = VARSIZE_ANY_EXHDR(right);
    rstr = (char *) palloc(rsize+1);
    memcpy(rstr, VARDATA_ANY(right), rsize);
    rstr[rsize] = '\0';

    result = debVS.CmpVersion (lstr, rstr);

    pfree (lstr);
    pfree (rstr);

    return (result);
  }
}

extern "C"
{
  PG_FUNCTION_INFO_V1(debversion_cmp);

  Datum
  debversion_cmp(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    int32 result;

    result = debversioncmp(left, right);

    PG_FREE_IF_COPY(left, 0);
    PG_FREE_IF_COPY(right, 1);

    PG_RETURN_INT32(result);
  }

  PG_FUNCTION_INFO_V1(debversion_hash);

  Datum
  debversion_hash(PG_FUNCTION_ARGS)
  {
    int32 txt_size;
    text *txt = PG_GETARG_TEXT_PP(0);
    char *str;
    Datum result;

    txt_size = VARSIZE_ANY_EXHDR(txt);
    str = (char *) palloc(txt_size+1);
    memcpy(str, VARDATA_ANY(txt), txt_size);
    str[txt_size] = '\0';

    result = hash_any((unsigned char *) str, txt_size);
    pfree(str);

    PG_FREE_IF_COPY(txt, 0);

    PG_RETURN_DATUM(result);
  }

  PG_FUNCTION_INFO_V1(debversion_eq);

  Datum
  debversion_eq(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    bool  result;

    result = debversioncmp(left, right) == 0;

    PG_FREE_IF_COPY(left, 0);
    PG_FREE_IF_COPY(right, 1);

    PG_RETURN_BOOL(result);
  }

  PG_FUNCTION_INFO_V1(debversion_ne);

  Datum
  debversion_ne(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    bool  result;

    result = debversioncmp(left, right) != 0;

    PG_FREE_IF_COPY(left, 0);
    PG_FREE_IF_COPY(right, 1);

    PG_RETURN_BOOL(result);
  }

  PG_FUNCTION_INFO_V1(debversion_lt);

  Datum
  debversion_lt(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    bool  result;

    result = debversioncmp(left, right) < 0;

    PG_FREE_IF_COPY(left, 0);
    PG_FREE_IF_COPY(right, 1);

    PG_RETURN_BOOL(result);
  }

  PG_FUNCTION_INFO_V1(debversion_le);

  Datum
  debversion_le(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    bool  result;

    result = debversioncmp(left, right) <= 0;

    PG_FREE_IF_COPY(left, 0);
    PG_FREE_IF_COPY(right, 1);

    PG_RETURN_BOOL(result);
  }

  PG_FUNCTION_INFO_V1(debversion_gt);

  Datum
  debversion_gt(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    bool  result;

    result = debversioncmp(left, right) > 0;

    PG_FREE_IF_COPY(left, 0);
    PG_FREE_IF_COPY(right, 1);

    PG_RETURN_BOOL(result);
  }

  PG_FUNCTION_INFO_V1(debversion_ge);

  Datum
  debversion_ge(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    bool  result;

    result = debversioncmp(left, right) >= 0;

    PG_FREE_IF_COPY(left, 0);
    PG_FREE_IF_COPY(right, 1);

    PG_RETURN_BOOL(result);
  }

  PG_FUNCTION_INFO_V1(debversion_smaller);

  Datum
  debversion_smaller(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    text *result;

    result = debversioncmp(left, right) < 0 ? left : right;

    PG_RETURN_TEXT_P(result);
  }

  PG_FUNCTION_INFO_V1(debversion_larger);

  Datum
  debversion_larger(PG_FUNCTION_ARGS)
  {
    text *left  = PG_GETARG_TEXT_PP(0);
    text *right = PG_GETARG_TEXT_PP(1);
    text *result;

    result = debversioncmp(left, right) > 0 ? left : right;

    PG_RETURN_TEXT_P(result);
  }
}
