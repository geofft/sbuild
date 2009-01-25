--- WannaBuild Database Schema for PostgreSQL                        -*- sql -*-
--- Debian version type and operators
---
--- Code derived from Dpkg::Version:
--- Copyright © Colin Watson <cjwatson@debian.org>
--- Copyright © Ian Jackson <iwj@debian.org>
--- Copyright © 2007 by Don Armstrong <don@donarmstrong.com>
---
--- PostgreSQL SQL, PL/pgSQL and PL/Perl:
--- Copyright © 2008 Roger Leigh <rleigh@debian.org>
---
--- This program is free software: you can redistribute it and/or modify
--- it under the terms of the GNU General Public License as published by
--- the Free Software Foundation, either version 2 of the License, or
--- (at your option) any later version.
---
--- This program is distributed in the hope that it will be useful, but
--- WITHOUT ANY WARRANTY; without even the implied warranty of
--- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
--- General Public License for more details.
---
--- You should have received a copy of the GNU General Public License
--- along with this program.  If not, see
--- <http://www.gnu.org/licenses/>.

SET SESSION plperl.use_strict TO 't';

CREATE TYPE debversion;

CREATE OR REPLACE FUNCTION debversionin(cstring)
RETURNS debversion
AS 'textin'
LANGUAGE internal IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION debversionout(debversion)
RETURNS cstring
AS 'textout'
LANGUAGE internal IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION debversionrecv(internal)
RETURNS debversion
AS 'textrecv'
LANGUAGE internal STABLE STRICT;

CREATE OR REPLACE FUNCTION debversionsend(debversion)
RETURNS bytea
AS 'textsend'
LANGUAGE internal STABLE STRICT;

CREATE TYPE debversion (
    INPUT          = debversionin,
    OUTPUT         = debversionout,
    RECEIVE        = debversionrecv,
    SEND           = debversionsend,
    INTERNALLENGTH = VARIABLE,
    STORAGE        = extended,
    -- make it a non-preferred member of string type category
    CATEGORY       = 'S',
    PREFERRED      = false
);

COMMENT ON TYPE debversion IS 'Debian package version number';

CREATE OR REPLACE FUNCTION debversion(bpchar)
RETURNS debversion
AS 'rtrim1'
LANGUAGE internal IMMUTABLE STRICT;

CREATE CAST (debversion AS text)    WITHOUT FUNCTION AS IMPLICIT;
CREATE CAST (debversion AS varchar) WITHOUT FUNCTION AS IMPLICIT;
CREATE CAST (debversion AS bpchar)  WITHOUT FUNCTION AS ASSIGNMENT;
CREATE CAST (text AS debversion)    WITHOUT FUNCTION AS ASSIGNMENT;
CREATE CAST (varchar AS debversion) WITHOUT FUNCTION AS ASSIGNMENT;
CREATE CAST (bpchar AS debversion)  WITH FUNCTION debversion(bpchar);

-- ALTER DOMAIN debversion
--   ADD CONSTRAINT debversion_syntax
--     CHECK (VALUE !~ '[^-+:.0-9a-zA-Z~]');

-- From Dpkg::Version::parseversion
CREATE OR REPLACE FUNCTION debversion_split (debversion)
  RETURNS text[] AS $$
    my $ver = shift;
    my %verhash;
    if ($ver =~ /:/)
    {
        $ver =~ /^(\d+):(.+)/ or die "bad version number '$ver'";
        $verhash{epoch} = $1;
        $ver = $2;
    }
    else
    {
        $verhash{epoch} = 0;
    }
    if ($ver =~ /(.+)-(.*)$/)
    {
        $verhash{version} = $1;
        $verhash{revision} = $2;
    }
    else
    {
        $verhash{version} = $ver;
        $verhash{revision} = 0;
    }

    return [$verhash{'epoch'}, $verhash{'version'}, $verhash{'revision'}];
$$
  LANGUAGE plperl
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_split (debversion)
  IS 'Split debian version into epoch, upstream version and revision';

CREATE OR REPLACE FUNCTION debversion_epoch (version debversion)
  RETURNS text AS $$
DECLARE
  split text[];
BEGIN
  split := debversion_split(version);
  RETURN split[1];
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_epoch (debversion)
  IS 'Get debian version epoch';

CREATE OR REPLACE FUNCTION debversion_version (version debversion)
  RETURNS text AS $$
DECLARE
  split text[];
BEGIN
  split := debversion_split(version);
  RETURN split[2];
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_version (debversion)
  IS 'Get debian version upstream version';

CREATE OR REPLACE FUNCTION debversion_revision (version debversion)
  RETURNS text AS $$
DECLARE
  split text[];
BEGIN
  split := debversion_split(version);
  RETURN split[3];
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_revision (debversion)
  IS 'Get debian version revision';

-- From Dpkg::Version::parseversion
CREATE OR REPLACE FUNCTION debversion_cmp_single (version1 text,
       	  	  	   			  version2 text)
  RETURNS integer AS $$
     sub order{
	  my ($x) = @_;
	  ##define order(x) ((x) == '~' ? -1 \
	  #           : cisdigit((x)) ? 0 \
	  #           : !(x) ? 0 \
	  #           : cisalpha((x)) ? (x) \
	  #           : (x) + 256)
	  # This comparison is out of dpkg's order to avoid
	  # comparing things to undef and triggering warnings.
	  if (not defined $x or not length $x) {
	       return 0;
	  }
	  elsif ($x eq '~') {
	       return -1;
	  }
	  elsif ($x =~ /^\d$/) {
	       return 0;
	  }
	  elsif ($x =~ /^[A-Z]$/i) {
	       return ord($x);
	  }
	  else {
	       return ord($x) + 256;
	  }
     }

     sub next_elem(\@){
	  my $a = shift;
	  return @{$a} ? shift @{$a} : undef;
     }
     my ($val, $ref) = @_;
     $val = "" if not defined $val;
     $ref = "" if not defined $ref;
     my @val = split //,$val;
     my @ref = split //,$ref;
     my $vc = next_elem @val;
     my $rc = next_elem @ref;
     while (defined $vc or defined $rc) {
	  my $first_diff = 0;
	  while ((defined $vc and $vc !~ /^\d$/) or
		 (defined $rc and $rc !~ /^\d$/)) {
	       my $vo = order($vc); my $ro = order($rc);
	       # Unlike dpkg's verrevcmp, we only return 1 or -1 here.
	       return (($vo - $ro > 0) ? 1 : -1) if $vo != $ro;
	       $vc = next_elem @val; $rc = next_elem @ref;
	  }
	  while (defined $vc and $vc eq '0') {
	       $vc = next_elem @val;
	  }
	  while (defined $rc and $rc eq '0') {
	       $rc = next_elem @ref;
	  }
	  while (defined $vc and $vc =~ /^\d$/ and
		 defined $rc and $rc =~ /^\d$/) {
	       $first_diff = ord($vc) - ord($rc) if !$first_diff;
	       $vc = next_elem @val; $rc = next_elem @ref;
	  }
	  return 1 if defined $vc and $vc =~ /^\d$/;
	  return -1 if defined $rc and $rc =~ /^\d$/;
	  return (($first_diff  > 0) ? 1 : -1) if $first_diff;
     }
     return 0;
$$
  LANGUAGE plperl
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_cmp_single (text, text)
  IS 'Compare upstream or revision parts of Debian versions';

-- Logic only derived from Dpkg::Version::parseversion
CREATE OR REPLACE FUNCTION debversion_cmp (version1 debversion,
       	  	  	   		   version2 debversion)
  RETURNS integer AS $$
DECLARE
  split1 text[];
  split2 text[];
  result integer;
BEGIN
  result := 0;
  split1 := debversion_split(version1);
  split2 := debversion_split(version2);

  -- RAISE NOTICE 'Version 1: %', version1;
  -- RAISE NOTICE 'Version 2: %', version2;
  -- RAISE NOTICE 'Split 1: %', split1;
  -- RAISE NOTICE 'Split 2: %', split2;

  IF split1[1] > split2[1] THEN
    result := 1;
  ELSIF split1[1] < split2[1] THEN
    result := -1;
  ELSE
    result := debversion_cmp_single(split1[2], split2[2]);
    IF result = 0 THEN
      result := debversion_cmp_single(split1[3], split2[3]);
    END IF;
  END IF;

  RETURN result;
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_cmp (debversion, debversion)
  IS 'Compare Debian versions';

CREATE OR REPLACE FUNCTION debversion_eq (version1 debversion,
       	  	  	   		  version2 debversion)
  RETURNS boolean AS $$
DECLARE
  comp integer;
  result boolean;
BEGIN
  comp := debversion_cmp(version1, version2);
  result := comp = 0;
  RETURN result;
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_eq (debversion, debversion)
  IS 'debversion equal';

CREATE OR REPLACE FUNCTION debversion_ne (version1 debversion,
       	  	  	   		  version2 debversion)
  RETURNS boolean AS $$
DECLARE
  comp integer;
  result boolean;
BEGIN
  comp := debversion_cmp(version1, version2);
  result := comp <> 0;
  RETURN result;
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_ne (debversion, debversion)
  IS 'debversion not equal';

CREATE OR REPLACE FUNCTION debversion_lt (version1 debversion,
       	  	  	   		  version2 debversion)
  RETURNS boolean AS $$
DECLARE
  comp integer;
  result boolean;
BEGIN
  comp := debversion_cmp(version1, version2);
  result := comp < 0;
  RETURN result;
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_lt (debversion, debversion)
  IS 'debversion less-than';

CREATE OR REPLACE FUNCTION debversion_gt (version1 debversion,
       	  	  	   		  version2 debversion) RETURNS boolean AS $$
DECLARE
  comp integer;
  result boolean;
BEGIN
  comp := debversion_cmp(version1, version2);
  result := comp > 0;
  RETURN result;
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_gt (debversion, debversion)
  IS 'debversion greater-than';

CREATE OR REPLACE FUNCTION debversion_le (version1 debversion,
       	  	  	   		  version2 debversion)
  RETURNS boolean AS $$
DECLARE
  comp integer;
  result boolean;
BEGIN
  comp := debversion_cmp(version1, version2);
  result := comp <= 0;
  RETURN result;
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_le (debversion, debversion)
  IS 'debversion less-than-or-equal';

CREATE OR REPLACE FUNCTION debversion_ge (version1 debversion,
       	  	  	   		  version2 debversion)
  RETURNS boolean AS $$
DECLARE
  comp integer;
  result boolean;
BEGIN
  comp := debversion_cmp(version1, version2);
  result := comp >= 0;
  RETURN result;
END;
$$
  LANGUAGE plpgsql
  IMMUTABLE STRICT;
COMMENT ON FUNCTION debversion_ge (debversion, debversion)
  IS 'debversion greater-than-or-equal';

CREATE OPERATOR = (
  PROCEDURE = debversion_eq,
  LEFTARG = debversion,
  RIGHTARG = debversion,
  COMMUTATOR = =,
  NEGATOR = !=
);
COMMENT ON OPERATOR = (debversion, debversion)
  IS 'debversion equal';

CREATE OPERATOR != (
  PROCEDURE = debversion_ne,
  LEFTARG = debversion,
  RIGHTARG = debversion,
  COMMUTATOR = !=,
  NEGATOR = =
);
COMMENT ON OPERATOR != (debversion, debversion)
  IS 'debversion not equal';

CREATE OPERATOR < (
  PROCEDURE = debversion_lt,
  LEFTARG = debversion,
  RIGHTARG = debversion,
  COMMUTATOR = >,
  NEGATOR = >=
);
COMMENT ON OPERATOR < (debversion, debversion)
  IS 'debversion less-than';

CREATE OPERATOR > (
  PROCEDURE = debversion_gt,
  LEFTARG = debversion,
  RIGHTARG = debversion,
  COMMUTATOR = <,
  NEGATOR = >=
);
COMMENT ON OPERATOR > (debversion, debversion)
  IS 'debversion greater-than';

CREATE OPERATOR <= (
  PROCEDURE = debversion_le,
  LEFTARG = debversion,
  RIGHTARG = debversion,
  COMMUTATOR = >=,
  NEGATOR = >
);
COMMENT ON OPERATOR <= (debversion, debversion)
  IS 'debversion less-than-or-equal';

CREATE OPERATOR >= (
  PROCEDURE = debversion_ge,
  LEFTARG = debversion,
  RIGHTARG = debversion,
  COMMUTATOR = <=,
  NEGATOR = <
);
COMMENT ON OPERATOR >= (debversion, debversion)
  IS 'debversion greater-than-or-equal';

CREATE OPERATOR CLASS debversion_ops
DEFAULT FOR TYPE DEBVERSION USING btree AS
    OPERATOR    1   <  (debversion, debversion),
    OPERATOR    2   <= (debversion, debversion),
    OPERATOR    3   =  (debversion, debversion),
    OPERATOR    4   >= (debversion, debversion),
    OPERATOR    5   >  (debversion, debversion),
    FUNCTION    1   debversion_cmp(debversion, debversion);

