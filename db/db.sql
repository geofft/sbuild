--- Debian Source Builder: Database Schema for PostgreSQL            -*- sql -*-
---
--- Copyright © 2008 Roger Leigh <rleigh@debian.org>
--- Copyright © 2008 Marc 'HE' Brockschmidt <he@debian.org>
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

CREATE DATABASE "sbuild-packages" ENCODING 'UTF8';
COMMENT ON DATABASE "sbuild-packages" IS 'Debian source builder package state management';
\c "sbuild-packages"

\i debversion.sql

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

DROP FUNCTION create_plpgsql_language()

CREATE TABLE architectures (
	name text
	  CONSTRAINT arch_pkey PRIMARY KEY
);

COMMENT ON TABLE architectures IS 'Architectures supported by this wanna-build instance';
COMMENT ON COLUMN architectures.name IS 'Architecture name';

INSERT INTO architectures (name) VALUES ('alpha');
INSERT INTO architectures (name) VALUES ('amd64');
INSERT INTO architectures (name) VALUES ('arm');
INSERT INTO architectures (name) VALUES ('armel');
INSERT INTO architectures (name) VALUES ('hppa');
INSERT INTO architectures (name) VALUES ('i386');
INSERT INTO architectures (name) VALUES ('ia64');
INSERT INTO architectures (name) VALUES ('m68k');
INSERT INTO architectures (name) VALUES ('mips');
INSERT INTO architectures (name) VALUES ('mipsel');
INSERT INTO architectures (name) VALUES ('powerpc');
INSERT INTO architectures (name) VALUES ('s390');
INSERT INTO architectures (name) VALUES ('sparc');

CREATE TABLE suites (
	name text
	  CONSTRAINT suite_pkey PRIMARY KEY,
	priority integer,
	depwait boolean
	  DEFAULT 't',
	hidden boolean
	  DEFAULT 'f'
);

COMMENT ON TABLE suites IS 'Valid suites';
COMMENT ON COLUMN suites.name IS 'Suite name';
COMMENT ON COLUMN suites.priority IS 'Sorting order (lower is higher priority)';
COMMENT ON COLUMN suites.depwait IS 'Automatically wait on dependencies?';
COMMENT ON COLUMN suites.hidden IS 'Hide suite from public view (e.g. for -security)?';

INSERT INTO suites (name, priority) VALUES ('experimental', 4);
INSERT INTO suites (name, priority) VALUES ('unstable', 3);
INSERT INTO suites (name, priority) VALUES ('testing', 2);
INSERT INTO suites (name, priority, depwait, hidden)
	VALUES ('testing-security', 2, 'f', 't');
INSERT INTO suites (name, priority) VALUES ('stable', 1);
INSERT INTO suites (name, priority, depwait, hidden)
	VALUES ('stable-security', 1, 'f', 't');

CREATE TABLE components (
	name text
	  CONSTRAINT component_pkey PRIMARY KEY
);

COMMENT ON TABLE components IS 'Valid archive components';
COMMENT ON COLUMN components.name IS 'Component name';

INSERT INTO components (name) VALUES ('main');
INSERT INTO components (name) VALUES ('contrib');
INSERT INTO components (name) VALUES ('non-free');

CREATE TABLE package_architectures (
	name text
	  CONSTRAINT pkg_arch_pkey PRIMARY KEY
);

COMMENT ON TABLE package_architectures IS 'Possible values for the Architecture field';
COMMENT ON COLUMN package_architectures.name IS 'Architecture name';

CREATE TABLE package_priorities (
	name text
	  CONSTRAINT pkg_pri_pkey PRIMARY KEY,
	value integer
	  DEFAULT 0
);

COMMENT ON TABLE package_priorities IS 'Valid package priorities';
COMMENT ON COLUMN package_priorities.name IS 'Priority name';
COMMENT ON COLUMN package_priorities.value IS 'Integer value for sorting priorities';

INSERT INTO package_priorities (name, value) VALUES ('required', 1);
INSERT INTO package_priorities (name, value) VALUES ('standard', 2);
INSERT INTO package_priorities (name, value) VALUES ('important', 3);
INSERT INTO package_priorities (name, value) VALUES ('optional', 4);
INSERT INTO package_priorities (name, value) VALUES ('extra', 5);

CREATE TABLE package_sections (
        name text
          CONSTRAINT pkg_sect_pkey PRIMARY KEY
);

COMMENT ON TABLE package_sections IS 'Valid package sections';
COMMENT ON COLUMN package_sections.name IS 'Section name';

INSERT INTO package_sections (name) VALUES ('admin');
INSERT INTO package_sections (name) VALUES ('comm');
INSERT INTO package_sections (name) VALUES ('debian-installer');
INSERT INTO package_sections (name) VALUES ('devel');
INSERT INTO package_sections (name) VALUES ('doc');
INSERT INTO package_sections (name) VALUES ('editors');
INSERT INTO package_sections (name) VALUES ('electronics');
INSERT INTO package_sections (name) VALUES ('embedded');
INSERT INTO package_sections (name) VALUES ('games');
INSERT INTO package_sections (name) VALUES ('gnome');
INSERT INTO package_sections (name) VALUES ('graphics');
INSERT INTO package_sections (name) VALUES ('hamradio');
INSERT INTO package_sections (name) VALUES ('interpreters');
INSERT INTO package_sections (name) VALUES ('kde');
INSERT INTO package_sections (name) VALUES ('libdevel');
INSERT INTO package_sections (name) VALUES ('libs');
INSERT INTO package_sections (name) VALUES ('mail');
INSERT INTO package_sections (name) VALUES ('math');
INSERT INTO package_sections (name) VALUES ('misc');
INSERT INTO package_sections (name) VALUES ('net');
INSERT INTO package_sections (name) VALUES ('news');
INSERT INTO package_sections (name) VALUES ('oldlibs');
INSERT INTO package_sections (name) VALUES ('otherosfs');
INSERT INTO package_sections (name) VALUES ('perl');
INSERT INTO package_sections (name) VALUES ('python');
INSERT INTO package_sections (name) VALUES ('science');
INSERT INTO package_sections (name) VALUES ('shells');
INSERT INTO package_sections (name) VALUES ('sound');
INSERT INTO package_sections (name) VALUES ('tex');
INSERT INTO package_sections (name) VALUES ('text');
INSERT INTO package_sections (name) VALUES ('utils');
INSERT INTO package_sections (name) VALUES ('web');
INSERT INTO package_sections (name) VALUES ('x11');


CREATE TABLE builders (
	name text
	  CONSTRAINT builder_pkey PRIMARY KEY,
	address text
	  NOT NULL
);

COMMENT ON TABLE builders IS 'buildd usernames (database users from _userinfo in old MLDBM db format)';
COMMENT ON COLUMN builders.name IS 'Username';
COMMENT ON COLUMN builders.address IS 'Remote e-mail address of the buildd user';

CREATE TABLE sources (
	name text
	  NOT NULL,
	version debversion NOT NULL,
	component_name text
	  CONSTRAINT source_comp_fkey REFERENCES components(name)
	  ON DELETE CASCADE
	  NOT NULL,
	pkg_section_name text
	  CONSTRAINT source_pkg_sect_fkey REFERENCES package_sections(name)
	  NOT NULL,
	pkg_priority_name text
	  CONSTRAINT source_pkg_pri_fkey REFERENCES package_priorities(name)
	  NOT NULL,
	maintainer text NOT NULL,
	uploaders text,
	build_dep text,
	build_dep_indep text,
	build_confl text,
	build_confl_indep text,
	stdver text,
	CONSTRAINT sources_pkey PRIMARY KEY (name, version)
);

CREATE INDEX sources_pkg_idx ON sources (name);

COMMENT ON TABLE sources IS 'Source packages common to all architectures (from Sources)';
COMMENT ON COLUMN sources.name IS 'Package name';
COMMENT ON COLUMN sources.version IS 'Package version number';
COMMENT ON COLUMN sources.component_name IS 'Archive component';
COMMENT ON COLUMN sources.pkg_section_name IS 'Package section';
COMMENT ON COLUMN sources.pkg_priority_name IS 'Package priority';
COMMENT ON COLUMN sources.maintainer IS 'Package maintainer name';
COMMENT ON COLUMN sources.uploaders IS 'Package uploader names';
COMMENT ON COLUMN sources.build_dep IS 'Package build dependencies (architecture dependent)';
COMMENT ON COLUMN sources.build_dep_indep IS 'Package build dependencies (architecture independent)';
COMMENT ON COLUMN sources.build_confl IS 'Package build conflicts (architecture dependent)';
COMMENT ON COLUMN sources.build_confl_indep IS 'Package build conflicts (architecture independent)';
COMMENT ON COLUMN sources.stdver IS 'Debian Standards (policy) version number';

CREATE TABLE source_architectures (
	source_name text
	  NOT NULL,
	source_version debversion NOT NULL,
	arch_name text
	  CONSTRAINT source_arch_arch_fkey
	  REFERENCES package_architectures(name)
	  ON DELETE CASCADE
	  NOT NULL,
	UNIQUE (source_name,source_version,arch_name),
	CONSTRAINT source_arch_source_fkey FOREIGN KEY (source_name, source_version)
	  REFERENCES sources (name, version)
	  ON DELETE CASCADE
);

COMMENT ON TABLE source_architectures IS 'Source package architectures (from Sources)';
COMMENT ON COLUMN source_architectures.source_name IS 'Package name';
COMMENT ON COLUMN source_architectures.source_version IS 'Package version number';
COMMENT ON COLUMN source_architectures.arch_name IS 'Architecture name';

CREATE TABLE binaries (
	name text NOT NULL,
	version debversion NOT NULL,
	arch_name text
	  CONSTRAINT bin_arch_fkey REFERENCES package_architectures(name)
	  ON DELETE CASCADE
	  NOT NULL,
       	source_name text
	  NOT NULL,
	source_version debversion NOT NULL,
	pkg_section_name text
	  CONSTRAINT bin_sect_fkey REFERENCES package_sections(name)
	  NOT NULL,
	pkg_priority_name text
	  CONSTRAINT bin_pri_fkey REFERENCES package_priorities(name)
	  NOT NULL,
	CONSTRAINT bin_pkey PRIMARY KEY (name, version, arch_name),
	CONSTRAINT bin_src_fkey FOREIGN KEY (source_name, source_version)
	  REFERENCES sources (name, version)
	  ON DELETE CASCADE
);

COMMENT ON TABLE binaries IS 'Binary packages specific to single architectures (from Packages)';
COMMENT ON COLUMN binaries.name IS 'Binary package name';
COMMENT ON COLUMN binaries.version IS 'Binary package version number';
COMMENT ON COLUMN binaries.arch_name IS 'Architecture name';
COMMENT ON COLUMN binaries.source_name IS 'Source package name';
COMMENT ON COLUMN binaries.source_version IS 'Source package version number';
COMMENT ON COLUMN binaries.pkg_section_name IS 'Package section';
COMMENT ON COLUMN binaries.pkg_priority_name IS 'Package priority';

CREATE TABLE job_states (
	name text
	  CONSTRAINT state_pkey PRIMARY KEY
);

COMMENT ON TABLE job_states IS 'Build job states';
COMMENT ON COLUMN job_states.name IS 'State name';

INSERT INTO job_states (name) VALUES ('build-attempted');
INSERT INTO job_states (name) VALUES ('building');
INSERT INTO job_states (name) VALUES ('built');
INSERT INTO job_states (name) VALUES ('dep-wait');
INSERT INTO job_states (name) VALUES ('dep-wait-removed');
INSERT INTO job_states (name) VALUES ('failed');
INSERT INTO job_states (name) VALUES ('failed-removed');
INSERT INTO job_states (name) VALUES ('install-wait');
INSERT INTO job_states (name) VALUES ('installed');
INSERT INTO job_states (name) VALUES ('needs-build');
INSERT INTO job_states (name) VALUES ('not-for-us');
INSERT INTO job_states (name) VALUES ('old-failed');
INSERT INTO job_states (name) VALUES ('reupload-wait');
INSERT INTO job_states (name) VALUES ('state');
INSERT INTO job_states (name) VALUES ('uploaded');

CREATE TABLE suite_sources (
       	source_name text
	  NOT NULL,
	source_version debversion NOT NULL,
	suite_name text
	  CONSTRAINT suite_sources_suite_fkey REFERENCES suites(name)
	  ON DELETE CASCADE
	  NOT NULL,
	CONSTRAINT suite_sources_pkey PRIMARY KEY (source_name, suite_name),
	CONSTRAINT suite_sources_src_fkey FOREIGN KEY (source_name, source_version)
	  REFERENCES sources (name, version)
	  ON DELETE CASCADE
);

COMMENT ON TABLE suite_sources IS 'Source packages contained within a suite';
COMMENT ON COLUMN suite_sources.source_name IS 'Source package name';
COMMENT ON COLUMN suite_sources.source_version IS 'Source package version number';
COMMENT ON COLUMN suite_sources.suite_name IS 'Suite name';

CREATE TABLE suite_binaries (
       	binary_name text
	  NOT NULL,
	binary_version debversion NOT NULL,
	arch_name text
	  CONSTRAINT suite_bin_arch_fkey REFERENCES package_architectures(name)
          ON DELETE CASCADE
	  NOT NULL,
	suite_name text
	  CONSTRAINT suite_bin_suite_fkey REFERENCES suites(name)
          ON DELETE CASCADE
	  NOT NULL,
	CONSTRAINT suite_bin_pkey PRIMARY KEY (binary_name, suite_name),
	CONSTRAINT suite_bin_bin_fkey FOREIGN KEY (binary_name, binary_version, arch_name)
	  REFERENCES binaries (name, version, arch_name)
	  ON DELETE CASCADE,
	CONSTRAINT suite_bin_unique UNIQUE (binary_name, binary_version, arch_name, suite_name)
);

COMMENT ON TABLE suite_binaries IS 'Binary packages contained within a suite';
COMMENT ON COLUMN suite_binaries.binary_name IS 'Binary package name';
COMMENT ON COLUMN suite_binaries.binary_version IS 'Binary package version number';
COMMENT ON COLUMN suite_binaries.arch_name IS 'Architecture name';
COMMENT ON COLUMN suite_binaries.suite_name IS 'Suite name';

CREATE TABLE build_jobs (
	id serial
	  CONSTRAINT build_jobs_pkey PRIMARY KEY,
       	source_name text
	  NOT NULL,
	source_version debversion
	  NOT NULL,
	arch_name text
 	  CONSTRAINT build_jobs_arch_fkey REFERENCES architectures(name)
	  ON DELETE CASCADE
	  NOT NULL,
	suite_name text
	  CONSTRAINT build_jobs_suite_fkey REFERENCES suites(name)
	  ON DELETE CASCADE
	  NOT NULL,
	user_name text NOT NULL DEFAULT CURRENT_USER,
	builder_name text
	  CONSTRAINT build_jobs_builder_fkey REFERENCES builders(name)
	  NOT NULL,
	state_name text
	  CONSTRAINT build_jobs_state_fkey REFERENCES job_states(name)
	  NOT NULL,
	ctime timestamp with time zone
	  NOT NULL DEFAULT CURRENT_TIMESTAMP,
	CONSTRAINT build_jobs_unique UNIQUE(source_name, source_version,
					    arch_name),
	CONSTRAINT build_jobs_src_fkey FOREIGN KEY(source_name, source_version)
	  REFERENCES sources(name, version)
	  ON DELETE CASCADE
);

CREATE INDEX build_jobs_name ON build_jobs (source_name);
CREATE INDEX build_jobs_ctime ON build_jobs (ctime);

COMMENT ON SEQUENCE build_jobs_id_seq IS 'Build job ticket number sequence';
COMMENT ON TABLE build_jobs IS 'Build job tickets (state changes) specific for single architecture';
COMMENT ON COLUMN build_jobs.id IS 'Job number';
COMMENT ON COLUMN build_jobs.source_name IS 'Source package name';
COMMENT ON COLUMN build_jobs.source_version IS 'Source package version number';
COMMENT ON COLUMN build_jobs.arch_name IS 'Architecture name';
COMMENT ON COLUMN build_jobs.suite_name IS 'Suite name';
COMMENT ON COLUMN build_jobs.user_name IS 'User making this change (username)';
COMMENT ON COLUMN build_jobs.builder_name IS 'Build dæmon making this change (username)';
COMMENT ON COLUMN build_jobs.state_name IS 'State name';
COMMENT ON COLUMN build_jobs.ctime IS 'Stage change time';

CREATE TABLE build_job_properties (
	job_id integer
	  NOT NULL
	  REFERENCES build_jobs(id)
	  ON DELETE CASCADE,
	prop_name text NOT NULL,
	prop_value text NOT NULL
);

COMMENT ON TABLE build_job_properties IS 'Additional job-specific properties (e.g. For PermBuildPri/BuildPri/Binary-NMU-(Version|ChangeLog)/Notes)';
COMMENT ON COLUMN build_job_properties.job_id IS 'Job reference number';
COMMENT ON COLUMN build_job_properties.prop_name IS 'Property name';
COMMENT ON COLUMN build_job_properties.prop_value IS 'Property value';

CREATE TABLE log (
	time timestamp with time zone
	  NOT NULL DEFAULT CURRENT_TIMESTAMP,
	username text NOT NULL DEFAULT CURRENT_USER,
	message text NOT NULL
);

CREATE INDEX log_idx ON log (time);

COMMENT ON TABLE log IS 'Log messages';
COMMENT ON COLUMN log.time IS 'Log entry time';
COMMENT ON COLUMN log.username IS 'Log user name';
COMMENT ON COLUMN log.message IS 'Log entry message';

CREATE OR REPLACE FUNCTION package_checkrel() RETURNS trigger AS $package_checkrel$
BEGIN
  PERFORM name FROM package_sections WHERE (name = NEW.pkg_section_name);
  IF FOUND = 'f' THEN
    INSERT INTO package_sections (name) VALUES (NEW.pkg_section_name);
  END IF;
  PERFORM name FROM package_priorities WHERE (name = NEW.pkg_priority_name);
  IF FOUND = 'f' THEN
    INSERT INTO package_priorities (name) VALUES (NEW.pkg_priority_name);
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


CREATE OR REPLACE FUNCTION package_check_arch() RETURNS trigger AS $package_check_arch$
BEGIN
  PERFORM name FROM package_architectures WHERE (name = NEW.arch_name);
  IF FOUND = 'f' THEN
    INSERT INTO package_architectures (name) VALUES (NEW.arch_name);
  END IF;
  RETURN NEW;
END;
$package_check_arch$ LANGUAGE plpgsql;

COMMENT ON FUNCTION package_check_arch ()
  IS 'Insert missing values into package_architectures (from NEW.arch_name)';

CREATE TRIGGER check_arch BEFORE INSERT OR UPDATE ON source_architectures
  FOR EACH ROW EXECUTE PROCEDURE package_check_arch();
COMMENT ON TRIGGER check_arch ON source_architectures
  IS 'Ensure foreign key references (arch_name) exist';

CREATE TRIGGER check_arch BEFORE INSERT OR UPDATE ON binaries
  FOR EACH ROW EXECUTE PROCEDURE package_check_arch();
COMMENT ON TRIGGER check_arch ON binaries
  IS 'Ensure foreign key references (arch_name) exist';
