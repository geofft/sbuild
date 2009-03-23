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

CREATE TABLE package_states (
	name text
	  CONSTRAINT state_pkey PRIMARY KEY
);

COMMENT ON TABLE package_states IS 'Package states';
COMMENT ON COLUMN package_states.name IS 'State name';

CREATE TABLE build_status (
	source text
	  NOT NULL,
	source_version debversion
	  NOT NULL,
	arch text
	  CONSTRAINT build_status_arch_fkey REFERENCES architectures(arch)
	  ON DELETE CASCADE
	  NOT NULL,
	suite text
	  CONSTRAINT build_status_suite_fkey REFERENCES suites(suite)
	  ON DELETE CASCADE
	  NOT NULL,
	bin_nmu integer,
	user_name text
	  NOT NULL
	  DEFAULT CURRENT_USER,
	builder text
	  -- Can be NULL in case of states set up manually by people.
	  CONSTRAINT build_status_builder_fkey REFERENCES builders(builder),
	status text
	  CONSTRAINT build_status_status_fkey REFERENCES package_states(name)
	  NOT NULL,
	ctime timestamp with time zone
	  NOT NULL
	  DEFAULT 'epoch'::timestamp,
	CONSTRAINT build_status_pkey PRIMARY KEY (source, arch, suite),
	CONSTRAINT build_status_src_fkey FOREIGN KEY(source, source_version)
	  REFERENCES sources(source, source_version)
	  ON DELETE CASCADE,
	CONSTRAINT suite_bin_suite_arch_fkey FOREIGN KEY (suite, arch)
	  REFERENCES suite_arches (suite, arch)
	  ON DELETE CASCADE
);

CREATE INDEX build_status_source ON build_status (source);

COMMENT ON TABLE build_status IS 'Build status for each package';
COMMENT ON COLUMN build_status.source IS 'Source package name';
COMMENT ON COLUMN build_status.source_version IS 'Source package version number';
COMMENT ON COLUMN build_status.arch IS 'Architecture name';
COMMENT ON COLUMN build_status.suite IS 'Suite name';
COMMENT ON COLUMN build_status.bin_nmu IS 'Scheduled binary NMU version, if any';
COMMENT ON COLUMN build_status.user_name IS 'User making this change (username)';
COMMENT ON COLUMN build_status.builder IS 'Build dæmon making this change (username)';
COMMENT ON COLUMN build_status.status IS 'Status name';
COMMENT ON COLUMN build_status.ctime IS 'Stage change time';

CREATE TABLE build_status_history (
	source text
	  NOT NULL,
	source_version debversion
	  NOT NULL,
	arch text
	  CONSTRAINT build_status_history_arch_fkey REFERENCES architectures(arch)
	  ON DELETE CASCADE
	  NOT NULL,
	suite text
	  CONSTRAINT build_status_history_suite_fkey REFERENCES suites(suite)
	  ON DELETE CASCADE
	  NOT NULL,
	bin_nmu integer,
	user_name text
	  NOT NULL
	  DEFAULT CURRENT_USER,
	builder text
	  CONSTRAINT build_status_history_builder_fkey REFERENCES builders(builder),
	status text
	  CONSTRAINT build_status_history_status_fkey REFERENCES package_states(name)
	  NOT NULL,
	ctime timestamp with time zone
	  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX build_status_history_source ON build_status_history (source);
CREATE INDEX build_status_history_ctime ON build_status_history (ctime);

COMMENT ON TABLE build_status_history IS 'Build status history for each package';
COMMENT ON COLUMN build_status_history.source IS 'Source package name';
COMMENT ON COLUMN build_status_history.source_version IS 'Source package version number';
COMMENT ON COLUMN build_status_history.arch IS 'Architecture name';
COMMENT ON COLUMN build_status_history.suite IS 'Suite name';
COMMENT ON COLUMN build_status_history.bin_nmu IS 'Scheduled binary NMU version, if any';
COMMENT ON COLUMN build_status_history.user_name IS 'User making this change (username)';
COMMENT ON COLUMN build_status_history.builder IS 'Build dæmon making this change (username)';
COMMENT ON COLUMN build_status_history.status IS 'Status name';
COMMENT ON COLUMN build_status_history.ctime IS 'Stage change time';

CREATE TABLE build_status_properties (
	source text NOT NULL,
	arch text NOT NULL,
	source suite NOT NULL,
	prop_name text NOT NULL,
	prop_value text NOT NULL,
	CONSTRAINT build_status_properties_fkey
	  FOREIGN KEY(source, arch)
	  REFERENCES build_status(id)
	  ON DELETE CASCADE,
	CONSTRAINT build_status_properties_unique
	  UNIQUE (source, arch, prop_name)
);

COMMENT ON TABLE build_status_properties IS 'Additional package-specific properties (e.g. For PermBuildPri/BuildPri/Binary-NMU-(Version|ChangeLog)/Notes)';
COMMENT ON COLUMN build_status_properties.source IS 'Source package name';
COMMENT ON COLUMN build_status_properties.arch IS 'Architecture name';
COMMENT ON COLUMN build_status_properties.suite IS 'Suite name';
COMMENT ON COLUMN build_status_properties.prop_name IS 'Property name';
COMMENT ON COLUMN build_status_properties.prop_value IS 'Property value';

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

CREATE TABLE build_logs (
	source text
	  NOT NULL,
	source_version debversion
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
COMMENT ON COLUMN build_logs.source_version IS 'Source package version';
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
