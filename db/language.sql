--- Debian Source Builder: Database Schema for PostgreSQL            -*- sql -*-
---
--- Copyright © 2008-2009 Roger Leigh <rleigh@debian.org>
--- Copyright © 2008-2009 Marc 'HE' Brockschmidt <he@debian.org>
--- Copyright © 2008-2009 Adeodato Simó <adeodato@debian.org>
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

CREATE OR REPLACE FUNCTION create_plpgsql_language ()
  RETURNS TEXT AS $$
    CREATE LANGUAGE plpgsql;
    SELECT 'language plpgsql created'::TEXT;
$$
LANGUAGE SQL;

SELECT CASE WHEN
 (SELECT 't'::boolean
    FROM pg_language
      WHERE lanname='plpgsql')
  THEN
    (SELECT 'language plpgsql already installed'::TEXT)
  ELSE
    (SELECT create_plpgsql_language())
END;

DROP FUNCTION create_plpgsql_language();
