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

--
-- Triggers to insert missing sections and priorities
--

CREATE OR REPLACE FUNCTION package_checkrel() RETURNS trigger AS $package_checkrel$
BEGIN
  PERFORM section FROM package_sections WHERE (section = NEW.section);
  IF FOUND = 'f' THEN
    INSERT INTO package_sections (section) VALUES (NEW.section);
  END IF;
  PERFORM pkg_prio FROM package_priorities WHERE (pkg_prio = NEW.pkg_prio);
  IF FOUND = 'f' THEN
    INSERT INTO package_priorities (pkg_prio) VALUES (NEW.pkg_prio);
  END IF;
  RETURN NEW;
END;
$package_checkrel$ LANGUAGE plpgsql;
COMMENT ON FUNCTION package_checkrel ()
  IS 'Check foreign key references (package sections and priorities) exist';

CREATE TRIGGER checkrel BEFORE INSERT OR UPDATE ON sources
  FOR EACH ROW EXECUTE PROCEDURE package_checkrel();
COMMENT ON TRIGGER checkrel ON sources
  IS 'Check foreign key references (package sections and priorities) exist';

CREATE TRIGGER checkrel BEFORE INSERT OR UPDATE ON binaries
  FOR EACH ROW EXECUTE PROCEDURE package_checkrel();
COMMENT ON TRIGGER checkrel ON binaries
  IS 'Check foreign key references (package sections and priorities) exist';

--
-- Triggers to insert missing package architectures
--

CREATE OR REPLACE FUNCTION package_check_arch() RETURNS trigger AS $package_check_arch$
BEGIN
  PERFORM arch FROM package_architectures WHERE (arch = NEW.arch);
  IF FOUND = 'f' THEN
    INSERT INTO package_architectures (arch) VALUES (NEW.arch);
  END IF;
  RETURN NEW;
END;
$package_check_arch$ LANGUAGE plpgsql;

COMMENT ON FUNCTION package_check_arch ()
  IS 'Insert missing values into package_architectures (from NEW.arch)';

CREATE TRIGGER check_arch BEFORE INSERT OR UPDATE ON source_architectures
  FOR EACH ROW EXECUTE PROCEDURE package_check_arch();
COMMENT ON TRIGGER check_arch ON source_architectures
  IS 'Ensure foreign key references (arch) exist';

CREATE TRIGGER check_arch BEFORE INSERT OR UPDATE ON binaries
  FOR EACH ROW EXECUTE PROCEDURE package_check_arch();
COMMENT ON TRIGGER check_arch ON binaries
  IS 'Ensure foreign key references (arch) exist';

-- Triggers on build_status:
--   - unconditionally update ctime
--   - verify bin_nmu is a positive integer (and change 0 to NULL)
--   - insert a record into status_history for every change in build_status

CREATE OR REPLACE FUNCTION set_ctime()
RETURNS trigger AS $set_ctime$
BEGIN
  NEW.ctime = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$set_ctime$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_bin_nmu_number()
RETURNS trigger AS $check_bin_nmu_number$
BEGIN
  IF NEW.bin_nmu = 0 THEN
    NEW.bin_nmu = NULL; -- Avoid two values with same meaning
  ELSIF NEW.bin_nmu < 0 THEN
    RAISE EXCEPTION 'Invalid value for "bin_nmu" column: %', NEW.bin_nmu;
  END IF;
  RETURN NEW;
END;
$check_bin_nmu_number$ LANGUAGE plpgsql;

CREATE TRIGGER check_bin_nmu BEFORE INSERT OR UPDATE ON build_status
  FOR EACH ROW EXECUTE PROCEDURE check_bin_nmu_number();
COMMENT ON TRIGGER check_bin_nmu ON build_status
  IS 'Ensure "bin_nmu" is a positive integer, or set it to NULL if 0';

CREATE TRIGGER set_or_update_ctime BEFORE INSERT OR UPDATE ON build_status
  FOR EACH ROW EXECUTE PROCEDURE set_ctime();
COMMENT ON TRIGGER set_or_update_ctime ON build_status
  IS 'Set or update the "ctime" column to now()';

CREATE OR REPLACE FUNCTION update_status_history()
RETURNS trigger AS $update_status_history$
BEGIN
  INSERT INTO status_history
    (source, source_version, arch, suite,
     bin_nmu, user_name, builder, status, ctime)
    VALUES
      (NEW.source, NEW.source_version, NEW.arch, NEW.suite,
       NEW.bin_nmu, NEW.user_name, NEW.builder, NEW.status, NEW.ctime);
  RETURN NULL;
END;
$update_status_history$ LANGUAGE plpgsql;

CREATE TRIGGER update_history AFTER INSERT OR UPDATE ON build_status
  FOR EACH ROW EXECUTE PROCEDURE update_status_history();
COMMENT ON TRIGGER update_history ON build_status
  IS 'Insert a record of the status change into status_history';
