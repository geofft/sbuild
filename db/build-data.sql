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

INSERT INTO package_states (name) VALUES
  ('build-attempted'),
  ('building'),
  ('built'),
  ('dep-wait'),
  ('dep-wait-removed'),
  ('failed'),
  ('failed-removed'),
  ('install-wait'),
  ('installed'),
  ('needs-build'),
  ('not-for-us'),
  ('old-failed'),
  ('reupload-wait'),
  ('state'),
  ('uploaded');

INSERT INTO build_log_result (result, is_success) VALUES
  ('maybe-failed', 'f'),
  ('maybe-successful', 't'),
  ('skipped', 'f');
