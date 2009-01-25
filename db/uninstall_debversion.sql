SET search_path = public;

DROP OPERATOR CLASS debversion_ops USING btree CASCADE;
DROP OPERATOR CLASS debversion_ops USING hash CASCADE;

DROP AGGREGATE min(debversion);
DROP AGGREGATE max(debversion);

DROP OPERATOR = (debversion, debversion);
DROP OPERATOR <> (debversion, debversion);
DROP OPERATOR < (debversion, debversion);
DROP OPERATOR <= (debversion, debversion);
DROP OPERATOR >= (debversion, debversion);
DROP OPERATOR > (debversion, debversion);

DROP CAST (debversion AS text);
DROP CAST (debversion AS varchar);
DROP CAST (debversion AS bpchar);
DROP CAST (text AS debversion);
DROP CAST (varchar AS debversion);
DROP CAST (bpchar AS debversion);

DROP FUNCTION debversion(bpchar);
DROP FUNCTION debversion_eq(debversion, debversion);
DROP FUNCTION debversion_ne(debversion, debversion);
DROP FUNCTION debversion_lt(debversion, debversion);
DROP FUNCTION debversion_le(debversion, debversion);
DROP FUNCTION debversion_gt(debversion, debversion);
DROP FUNCTION debversion_ge(debversion, debversion);
DROP FUNCTION debversion_cmp(debversion, debversion);
DROP FUNCTION debversion_hash(debversion);
DROP FUNCTION debversion_smaller(debversion, debversion);
DROP FUNCTION debversion_larger(debversion, debversion);

DROP TYPE debversion CASCADE;
