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

CREATE DATABASE "sbuild-packages" ENCODING 'UTF8';
COMMENT ON DATABASE "sbuild-packages" IS 'Debian source builder package state management';
\c "sbuild-packages"

\i debversion.sql

SET search_path = public;

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
	arch text
	  CONSTRAINT arch_pkey PRIMARY KEY
);

COMMENT ON TABLE architectures IS 'Architectures supported by this wanna-build instance';
COMMENT ON COLUMN architectures.arch IS 'Architecture name';

INSERT INTO architectures (arch) VALUES ('alpha');
INSERT INTO architectures (arch) VALUES ('amd64');
INSERT INTO architectures (arch) VALUES ('arm');
INSERT INTO architectures (arch) VALUES ('armel');
INSERT INTO architectures (arch) VALUES ('hppa');
INSERT INTO architectures (arch) VALUES ('i386');
INSERT INTO architectures (arch) VALUES ('ia64');
INSERT INTO architectures (arch) VALUES ('m68k');
INSERT INTO architectures (arch) VALUES ('mips');
INSERT INTO architectures (arch) VALUES ('mipsel');
INSERT INTO architectures (arch) VALUES ('powerpc');
INSERT INTO architectures (arch) VALUES ('s390');
INSERT INTO architectures (arch) VALUES ('sparc');

CREATE TABLE suites (
	suite text
	  CONSTRAINT suite_pkey PRIMARY KEY,
	priority integer,
	depwait boolean
	  DEFAULT 't',
	hidden boolean
	  DEFAULT 'f'
);

COMMENT ON TABLE suites IS 'Valid suites';
COMMENT ON COLUMN suites.suite IS 'Suite name';
COMMENT ON COLUMN suites.priority IS 'Sorting order (lower is higher priority)';
COMMENT ON COLUMN suites.depwait IS 'Automatically wait on dependencies?';
COMMENT ON COLUMN suites.hidden IS 'Hide suite from public view (e.g. for -security)?';

INSERT INTO suites (suite, priority) VALUES ('experimental', 4);
INSERT INTO suites (suite, priority) VALUES ('unstable', 3);
INSERT INTO suites (suite, priority) VALUES ('testing', 2);
INSERT INTO suites (suite, priority, depwait, hidden)
	VALUES ('testing-security', 2, 'f', 't');
INSERT INTO suites (suite, priority) VALUES ('stable', 1);
INSERT INTO suites (suite, priority, depwait, hidden)
	VALUES ('stable-security', 1, 'f', 't');

CREATE TABLE components (
	component text
	  CONSTRAINT component_pkey PRIMARY KEY
);

COMMENT ON TABLE components IS 'Valid archive components';
COMMENT ON COLUMN components.component IS 'Component name';

INSERT INTO components (component) VALUES ('main');
INSERT INTO components (component) VALUES ('contrib');
INSERT INTO components (component) VALUES ('non-free');

CREATE TABLE package_architectures (
	arch text
	  CONSTRAINT pkg_arch_pkey PRIMARY KEY
);

COMMENT ON TABLE package_architectures IS 'Possible values for the Architecture field';
COMMENT ON COLUMN package_architectures.arch IS 'Architecture name';

CREATE TABLE package_priorities (
	pkg_prio text
	  CONSTRAINT pkg_pri_pkey PRIMARY KEY,
	prio_val integer
	  DEFAULT 0
);

COMMENT ON TABLE package_priorities IS 'Valid package priorities';
COMMENT ON COLUMN package_priorities.pkg_prio IS 'Priority name';
COMMENT ON COLUMN package_priorities.prio_val IS 'Integer value for sorting priorities';

INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('required', 1);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('standard', 2);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('important', 3);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('optional', 4);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('extra', 5);

CREATE TABLE package_sections (
        section text
          CONSTRAINT pkg_sect_pkey PRIMARY KEY
);

COMMENT ON TABLE package_sections IS 'Valid package sections';
COMMENT ON COLUMN package_sections.section IS 'Section name';

CREATE TABLE builders (
	builder text
	  CONSTRAINT builder_pkey PRIMARY KEY,
	arch text
	  CONSTRAINT builder_arch_fkey REFERENCES architectures(arch)
	  NOT NULL,
	address text
	  NOT NULL
);

COMMENT ON TABLE builders IS 'buildd usernames (database users from _userinfo in old MLDBM db format)';
COMMENT ON COLUMN builders.builder IS 'Username';
COMMENT ON COLUMN builders.arch IS 'Buildd architecture';
COMMENT ON COLUMN builders.address IS 'Remote e-mail address of the buildd user';

CREATE TABLE sources (
	source text
	  NOT NULL,
	version debversion
	  NOT NULL,
	component text
	  CONSTRAINT source_comp_fkey REFERENCES components(component)
	  ON DELETE CASCADE
	  NOT NULL,
	section text
	  CONSTRAINT source_section_fkey REFERENCES package_sections(section)
	  NOT NULL,
	pkg_prio text
	  CONSTRAINT source_pkg_prio_fkey REFERENCES package_priorities(pkg_prio)
	  NOT NULL,
	maintainer text NOT NULL,
	build_dep text,
	build_dep_indep text,
	build_confl text,
	build_confl_indep text,
	stdver text,
	CONSTRAINT sources_pkey PRIMARY KEY (source, version)
);

CREATE INDEX sources_pkg_idx ON sources (source);

COMMENT ON TABLE sources IS 'Source packages common to all architectures (from Sources)';
COMMENT ON COLUMN sources.source IS 'Package name';
COMMENT ON COLUMN sources.version IS 'Package version number';
COMMENT ON COLUMN sources.component IS 'Archive component';
COMMENT ON COLUMN sources.section IS 'Package section';
COMMENT ON COLUMN sources.pkg_prio IS 'Package priority';
COMMENT ON COLUMN sources.maintainer IS 'Package maintainer name';
COMMENT ON COLUMN sources.build_dep IS 'Package build dependencies (architecture dependent)';
COMMENT ON COLUMN sources.build_dep_indep IS 'Package build dependencies (architecture independent)';
COMMENT ON COLUMN sources.build_confl IS 'Package build conflicts (architecture dependent)';
COMMENT ON COLUMN sources.build_confl_indep IS 'Package build conflicts (architecture independent)';
COMMENT ON COLUMN sources.stdver IS 'Debian Standards (policy) version number';

CREATE TABLE source_architectures (
	source text
	  NOT NULL,
	version debversion
	  NOT NULL,
	arch text
	  CONSTRAINT source_arch_arch_fkey
	  REFERENCES package_architectures(arch)
	  ON DELETE CASCADE
	  NOT NULL,
	UNIQUE (source, version, arch),
	CONSTRAINT source_arch_source_fkey FOREIGN KEY (source, version)
	  REFERENCES sources (source, version)
	  ON DELETE CASCADE
);

COMMENT ON TABLE source_architectures IS 'Source package architectures (from Sources)';
COMMENT ON COLUMN source_architectures.source IS 'Package name';
COMMENT ON COLUMN source_architectures.version IS 'Package version number';
COMMENT ON COLUMN source_architectures.arch IS 'Architecture name';

CREATE TABLE uploaders (
	source text
	  NOT NULL,
	version debversion
	  NOT NULL,
	uploader text
	  NOT NULL,
	UNIQUE (source, version, uploader),
	CONSTRAINT uploader_source_fkey FOREIGN KEY (source, version)
	  REFERENCES sources (source, version)
	  ON DELETE CASCADE
);

COMMENT ON TABLE uploaders IS 'Uploader names for source packages';
COMMENT ON COLUMN uploaders.source IS 'Package name';
COMMENT ON COLUMN uploaders.version IS 'Package version number';
COMMENT ON COLUMN uploaders.uploader IS 'Uploader name and address';

CREATE TABLE binaries (
	-- PostgreSQL won't allow "binary" as column name
	package text NOT NULL,
	version debversion NOT NULL,
	arch text
	  CONSTRAINT bin_arch_fkey REFERENCES package_architectures(arch)
	  ON DELETE CASCADE
	  NOT NULL,
	source text
	  NOT NULL,
	source_version debversion
	  NOT NULL,
	section text
	  CONSTRAINT bin_section_fkey REFERENCES package_sections(section)
	  NOT NULL,
	pkg_prio text
	  CONSTRAINT bin_pkg_prio_fkey REFERENCES package_priorities(pkg_prio)
	  NOT NULL,
	CONSTRAINT bin_pkey PRIMARY KEY (package, version, arch),
	CONSTRAINT bin_src_fkey FOREIGN KEY (source, source_version)
	  REFERENCES sources (source, version)
	  ON DELETE CASCADE
);

COMMENT ON TABLE binaries IS 'Binary packages specific to single architectures (from Packages)';
COMMENT ON COLUMN binaries.package IS 'Binary package name';
COMMENT ON COLUMN binaries.version IS 'Binary package version number';
COMMENT ON COLUMN binaries.arch IS 'Architecture name';
COMMENT ON COLUMN binaries.source IS 'Source package name';
COMMENT ON COLUMN binaries.source_version IS 'Source package version number';
COMMENT ON COLUMN binaries.section IS 'Package section';
COMMENT ON COLUMN binaries.pkg_prio IS 'Package priority';

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
	source text
	  NOT NULL,
	version debversion
	  NOT NULL,
	suite text
	  CONSTRAINT suite_sources_suite_fkey REFERENCES suites(suite)
	  ON DELETE CASCADE
	  NOT NULL,
	CONSTRAINT suite_sources_pkey PRIMARY KEY (source, suite),
	CONSTRAINT suite_sources_src_fkey FOREIGN KEY (source, version)
	  REFERENCES sources (source, version)
	  ON DELETE CASCADE
);

COMMENT ON TABLE suite_sources IS 'Source packages contained within a suite';
COMMENT ON COLUMN suite_sources.source IS 'Source package name';
COMMENT ON COLUMN suite_sources.version IS 'Source package version number';
COMMENT ON COLUMN suite_sources.suite IS 'Suite name';

CREATE TABLE suite_binaries (
	package text
	  NOT NULL,
	version debversion
	  NOT NULL,
	arch text
	  CONSTRAINT suite_bin_arch_fkey REFERENCES package_architectures(arch)
          ON DELETE CASCADE
	  NOT NULL,
	suite text
	  CONSTRAINT suite_bin_suite_fkey REFERENCES suites(suite)
          ON DELETE CASCADE
	  NOT NULL,
	CONSTRAINT suite_bin_pkey PRIMARY KEY (package, suite),
	CONSTRAINT suite_bin_bin_fkey FOREIGN KEY (package, version, arch)
	  REFERENCES binaries (package, version, arch)
	  ON DELETE CASCADE,
	CONSTRAINT suite_bin_unique UNIQUE (package, version, arch, suite)
);

COMMENT ON TABLE suite_binaries IS 'Binary packages contained within a suite';
COMMENT ON COLUMN suite_binaries.package IS 'Binary package name';
COMMENT ON COLUMN suite_binaries.version IS 'Binary package version number';
COMMENT ON COLUMN suite_binaries.arch IS 'Architecture name';
COMMENT ON COLUMN suite_binaries.suite IS 'Suite name';

CREATE TABLE build_jobs (
	id serial
	  CONSTRAINT build_jobs_pkey PRIMARY KEY,
	source text
	  NOT NULL,
	version debversion
	  NOT NULL,
	arch text
	  CONSTRAINT build_jobs_arch_fkey REFERENCES architectures(arch)
	  ON DELETE CASCADE
	  NOT NULL,
	suite text
	  CONSTRAINT build_jobs_suite_fkey REFERENCES suites(suite)
	  ON DELETE CASCADE
	  NOT NULL,
	user_name text NOT NULL DEFAULT CURRENT_USER,
	builder text
	  CONSTRAINT build_jobs_builder_fkey REFERENCES builders(builder)
	  NOT NULL,
	state text
	  CONSTRAINT build_jobs_state_fkey REFERENCES job_states(name)
	  NOT NULL,
	ctime timestamp with time zone
	  NOT NULL DEFAULT CURRENT_TIMESTAMP,
	CONSTRAINT build_jobs_unique UNIQUE(source, version, arch),
	CONSTRAINT build_jobs_src_fkey FOREIGN KEY(source, version)
	  REFERENCES sources(source, version)
	  ON DELETE CASCADE
);

CREATE INDEX build_jobs_source ON build_jobs (source);
CREATE INDEX build_jobs_ctime ON build_jobs (ctime);

COMMENT ON SEQUENCE build_jobs_id_seq IS 'Build job ticket number sequence';
COMMENT ON TABLE build_jobs IS 'Build job tickets (state changes) specific for single architecture';
COMMENT ON COLUMN build_jobs.id IS 'Job number';
COMMENT ON COLUMN build_jobs.source IS 'Source package name';
COMMENT ON COLUMN build_jobs.version IS 'Source package version number';
COMMENT ON COLUMN build_jobs.arch IS 'Architecture name';
COMMENT ON COLUMN build_jobs.suite IS 'Suite name';
COMMENT ON COLUMN build_jobs.user_name IS 'User making this change (username)';
COMMENT ON COLUMN build_jobs.builder IS 'Build daemon making this change (username)';
COMMENT ON COLUMN build_jobs.state IS 'State name';
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

-- Make this a table because in the future we may have more fine-grained
-- result states.
CREATE TABLE build_log_result (
	result text
	  CONSTRAINT build_log_result_pkey PRIMARY KEY,
	is_success boolean
	  DEFAULT 'f'
);

COMMENT ON TABLE build_log_result IS 'Possible results states of a build log';
COMMENT ON COLUMN build_log_result.result IS 'Meaningful and short name for the result';
COMMENT ON COLUMN build_log_result.is_success IS 'Whether the result of the build is successful';

INSERT INTO build_log_result (result) VALUES ('maybe-failed');
INSERT INTO build_log_result (result, is_success) VALUES ('maybe-successful', 't');

CREATE TABLE build_logs (
	source text
	  NOT NULL,
	version debversion
	  NOT NULL,
	arch text
	  CONSTRAINT build_logs_arch_fkey REFERENCES architectures(arch)
	  NOT NULL,
	suite text
	  CONSTRAINT build_logs_suite_fkey REFERENCES suites(suite)
	  NOT NULL,
	date timestamp with time zone
	  NOT NULL,
	result text
	  CONSTRAINT build_logs_result_fkey REFERENCES build_log_result(result)
	  NOT NULL,
	build_time interval,
	used_space integer,
	path text
	  CONSTRAINT build_logs_pkey PRIMARY KEY
);
CREATE INDEX build_logs_source_idx ON build_logs (source);

COMMENT ON TABLE build_logs IS 'Available build logs';
COMMENT ON COLUMN build_logs.source IS 'Source package name';
COMMENT ON COLUMN build_logs.version IS 'Source package version';
COMMENT ON COLUMN build_logs.arch IS 'Architecture name';
COMMENT ON COLUMN build_logs.suite IS 'Suite name';
COMMENT ON COLUMN build_logs.date IS 'Date of the log';
COMMENT ON COLUMN build_logs.result IS 'Result state';
COMMENT ON COLUMN build_logs.build_time IS 'Time needed by the build';
COMMENT ON COLUMN build_logs.used_space IS 'Space needed by the build';
COMMENT ON COLUMN build_logs.path IS 'Relative path to the log file';

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

CREATE TABLE people (
	login text
	  CONSTRAINT people_pkey PRIMARY KEY,
	full_name text
	  NOT NULL,
	address text
	  NOT NULL
);

COMMENT ON TABLE people IS 'People wanna-build should know about';
COMMENT ON COLUMN people.login IS 'Debian login';
COMMENT ON COLUMN people.full_name IS 'Full name';
COMMENT ON COLUMN people.address IS 'E-mail address';

CREATE TABLE buildd_admins (
	builder text
	  CONSTRAINT buildd_admin_builder_fkey REFERENCES builders(builder)
	  ON DELETE CASCADE
	  NOT NULL,
	admin text
	  CONSTRAINT buildd_admin_admin_fkey REFERENCES people(login)
	  ON DELETE CASCADE
	  NOT NULL,
	backup boolean
	  DEFAULT 'f',
	UNIQUE (builder, admin)
);

COMMENT ON TABLE buildd_admins IS 'Admins for each buildd';
COMMENT ON COLUMN buildd_admins.builder IS 'The buildd';
COMMENT ON COLUMN buildd_admins.admin IS 'The admin login';
COMMENT ON COLUMN buildd_admins.backup IS 'Whether this is only a backup admin';

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
