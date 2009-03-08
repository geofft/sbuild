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

INSERT INTO package_states (name) VALUES ('build-attempted');
INSERT INTO package_states (name) VALUES ('building');
INSERT INTO package_states (name) VALUES ('built');
INSERT INTO package_states (name) VALUES ('dep-wait');
INSERT INTO package_states (name) VALUES ('dep-wait-removed');
INSERT INTO package_states (name) VALUES ('failed');
INSERT INTO package_states (name) VALUES ('failed-removed');
INSERT INTO package_states (name) VALUES ('install-wait');
INSERT INTO package_states (name) VALUES ('installed');
INSERT INTO package_states (name) VALUES ('needs-build');
INSERT INTO package_states (name) VALUES ('not-for-us');
INSERT INTO package_states (name) VALUES ('old-failed');
INSERT INTO package_states (name) VALUES ('reupload-wait');
INSERT INTO package_states (name) VALUES ('state');
INSERT INTO package_states (name) VALUES ('uploaded');

INSERT INTO build_log_result (result) VALUES ('maybe-failed');
INSERT INTO build_log_result (result, is_success) VALUES ('maybe-successful', 't');
INSERT INTO build_log_result (result) VALUES ('skipped');
