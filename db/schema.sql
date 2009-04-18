--- Debian Source Builder: Database Schema for PostgreSQL            -*- sql -*-
---
--- Copyright © 2009 Roger Leigh <rleigh@debian.org>
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

CREATE TABLE schema (
	version integer
	  CONSTRAINT schema_pkey PRIMARY KEY,
	description text NOT NULL
);

COMMENT ON TABLE schema IS 'Schema revision history';
COMMENT ON COLUMN schema.version IS 'Schema version';
COMMENT ON COLUMN schema.description IS 'Schema change description';
