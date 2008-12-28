--- WannaBuild Database Schema for PostgreSQL                        -*- sql -*-
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

CREATE DATABASE "wannabuild" ENCODING 'UTF8';
\c wannabuild

CREATE TABLE architectures (
	name text	       -- arch name
	  CONSTRAINT arch_name PRIMARY KEY
);

INSERT INTO architectures (name) VALUES ('all');
INSERT INTO architectures (name) VALUES ('any');
INSERT INTO architectures (name) VALUES ('alpha');
INSERT INTO architectures (name) VALUES ('amd64');
INSERT INTO architectures (name) VALUES ('arm');
INSERT INTO architectures (name) VALUES ('armel');
INSERT INTO architectures (name) VALUES ('hppa');
INSERT INTO architectures (name) VALUES ('i386');
INSERT INTO architectures (name) VALUES ('ia64');
INSERT INTO architectures (name) VALUES ('kfreebsd-amd64');
INSERT INTO architectures (name) VALUES ('kfreebsd-i386');
INSERT INTO architectures (name) VALUES ('m68k');
INSERT INTO architectures (name) VALUES ('mips');
INSERT INTO architectures (name) VALUES ('mipsel');
INSERT INTO architectures (name) VALUES ('powerpc');
INSERT INTO architectures (name) VALUES ('s390');
INSERT INTO architectures (name) VALUES ('sparc');

--- List of architectures with a primary key
CREATE TABLE architecture_list (
	name text	       -- arch name
	  CONSTRAINT arch_list_name PRIMARY KEY
);

--- Mapping between architecture list and architectures
CREATE TABLE architecture_list_mapping (
	arch_list_name text	-- architecture list reference
	  CONSTRAINT arch_list_map_list REFERENCES architecture_list(name)
	  NOT NULL,
	arch_name text		-- architecture reference
	  CONSTRAINT arch_list_map_arch REFERENCES architectures(name)
	  NOT NULL,
	UNIQUE (arch_list_name, arch_name)
);


--- Set up initial single mappings
INSERT INTO architecture_list (name)
  SELECT name FROM architectures;

INSERT INTO architecture_list_mapping (arch_list_name, arch_name)
  SELECT l.name AS arch_list_name,
         a.name AS arch_name
  FROM architectures AS a
  INNER JOIN architecture_list AS l
  ON (l.name = a.name);

--- Test more complex mapping
INSERT INTO architecture_list (name) VALUES ('allmips');
INSERT INTO architecture_list_mapping SELECT l.name AS arch_list_name, a.name AS arch_name FROM architectures AS a CROSS JOIN architecture_list AS l WHERE (l.name = 'allmips' AND (a.name = 'mips' OR a.name = 'mipsel'));

--- Test queries (wrap with view to make simpler)
SELECT a.name AS name, l.name AS list FROM architectures AS a LEFT OUTER JOIN architecture_list_mapping AS m ON (m.arch_name = a.name) LEFT OUTER JOIN architecture_list AS l ON (m.arch_list_name = l.name) WHERE (l.name = 'allmips');

SELECT l.name AS list, array_to_string(ARRAY(SELECT a.name FROM architectures AS a WHERE (a.name = m.arch_name) ORDER BY a.name ASC), ',') FROM architecture_list_mapping AS m INNER JOIN architecture_list AS l ON (m.arch_list_name = l.name) WHERE (l.name = 'allmips');

--- Allowed distributions
CREATE TABLE distributions (
	name text 		-- distribution name
	  CONSTRAINT dist_name PRIMARY KEY,
	priority integer,	-- distribution priority
	depwait boolean		-- distribution auto dep wait?
	  DEFAULT 't',
	hidden boolean		-- distribution is hidden?
	  DEFAULT 'f'
);

INSERT INTO distributions (name, priority) VALUES ('experimental', 4);
INSERT INTO distributions (name, priority) VALUES ('unstable', 3);
INSERT INTO distributions (name, priority) VALUES ('testing', 2);
INSERT INTO distributions (name, priority, depwait, hidden)
	VALUES ('testing-security', 2, 'f', 't');
INSERT INTO distributions (name, priority) VALUES ('stable', 1);
INSERT INTO distributions (name, priority, depwait, hidden)
	VALUES ('stable-security', 1, 'f', 't');

--- Archive sections
CREATE TABLE sections (
	name text		-- section name
	  CONSTRAINT section_name PRIMARY KEY
);

INSERT INTO sections (name) VALUES ('main');
INSERT INTO sections (name) VALUES ('contrib');
INSERT INTO sections (name) VALUES ('non-free');

-- package_priorities e.g. optional, extra.
CREATE TABLE package_priorities (
	name text                  -- package priority name
	  CONSTRAINT pkg_pri_name PRIMARY KEY
);

INSERT INTO package_priorities (name) VALUES ('extra');
INSERT INTO package_priorities (name) VALUES ('important');
INSERT INTO package_priorities (name) VALUES ('optional');
INSERT INTO package_priorities (name) VALUES ('required');
INSERT INTO package_priorities (name) VALUES ('standard');

-- package_sections e.g. base, editors, libs, text, utils.
CREATE TABLE package_sections (
        name text                  -- package section name
          CONSTRAINT pkg_sect_name PRIMARY KEY
);

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

--- Database users: from _userinfo in old db format.
CREATE TABLE builders (
	name text		-- builder name
	  CONSTRAINT builder_name PRIMARY KEY
);

--- Source information common to all arches (from Sources)
CREATE TABLE sources (
	name text		-- builder name
	  NOT NULL,
	version text NOT NULL,	-- package version number
	section_name text	-- package section
	  CONSTRAINT source_sect REFERENCES sections(name)
	  NOT NULL,
	pkg_section_name text	-- package section
	  CONSTRAINT source_pkg_sect REFERENCES package_sections(name)
	  NOT NULL,
	pkg_priority_name text	-- package priority
	  CONSTRAINT source_pkg_pri REFERENCES package_priorities(name)
	  NOT NULL,
	arch_list_name text	-- package
	  CONSTRAINT source_arch REFERENCES architecture_list(name)
	  NOT NULL,
	maintainer text NOT NULL,	-- maintainer name
	uploaders text,		-- uploader names
	build_dep text,		-- build dependencies (arch dep)
	build_dep_indep text,	-- build dependencies (arch indep)
	build_confl text,	-- build conflicts (arch dep)
	build_confl_indep text,	-- build conflicts (arch indep)
	stdver text,		-- standards version
	CONSTRAINT sources_pkey PRIMARY KEY (name, version)
);

--- Arch-specific package information (from Packages)
CREATE TABLE binaries (
	name text NOT NULL,	-- builder name
	version text NOT NULL,	-- package version number
	arch_name text		-- package
	  CONSTRAINT bin_arch REFERENCES architectures(name)
	  NOT NULL,
       	source_name text		-- package source
	  NOT NULL,
	source_version text NOT NULL,	-- package source version number
	section_name text	-- package section
	  CONSTRAINT bin_sect REFERENCES package_sections(name)
	  NOT NULL,
	priority_name text	-- package priority
	  CONSTRAINT bin_pri REFERENCES package_priorities(name)
	  NOT NULL,
	CONSTRAINT bin_pkey PRIMARY KEY (name, version, arch_name),
	CONSTRAINT bin_fkey FOREIGN KEY (source_name, source_version)
	  REFERENCES sources (name, version)
);

--- Wanna-Build package states
CREATE TABLE states (
	name text		-- state name
	  CONSTRAINT state_name PRIMARY KEY
);

INSERT INTO states (name) VALUES ('build-attempted');
INSERT INTO states (name) VALUES ('building');
INSERT INTO states (name) VALUES ('built');
INSERT INTO states (name) VALUES ('dep-wait');
INSERT INTO states (name) VALUES ('dep-wait-removed');
INSERT INTO states (name) VALUES ('failed');
INSERT INTO states (name) VALUES ('failed-removed');
INSERT INTO states (name) VALUES ('install-wait');
INSERT INTO states (name) VALUES ('installed');
INSERT INTO states (name) VALUES ('needs-build');
INSERT INTO states (name) VALUES ('not-for-us');
INSERT INTO states (name) VALUES ('old-failed');
INSERT INTO states (name) VALUES ('reupload-wait');
INSERT INTO states (name) VALUES ('state');
INSERT INTO states (name) VALUES ('uploaded');

CREATE TABLE dist_sources (
       	source_name text		-- package
	  NOT NULL,
	source_version text NOT NULL,	-- package version number
	distribution_name text		-- distribution
	  CONSTRAINT dist_src_dist REFERENCES distributions(name)
	  NOT NULL,
	CONSTRAINT dist_sources_pkey PRIMARY KEY (source_name, distribution_name),
	CONSTRAINT dist_sources_fkey FOREIGN KEY (source_name, source_version)
	  REFERENCES sources (name, version)
);

CREATE TABLE dist_binaries (
       	pkg_name text			-- package
	  NOT NULL,
	pkg_version text NOT NULL,	-- package version number
	arch_name text		-- package
	  CONSTRAINT dist_bin_arch REFERENCES architectures(name)
	  NOT NULL,
	distribution_name text		-- distribution
	  CONSTRAINT dist_bin_dist REFERENCES distributions(name)
	  NOT NULL,
	CONSTRAINT dist_bin_pkey PRIMARY KEY (pkg_name, distribution_name),
	CONSTRAINT dist_bin_fkey FOREIGN KEY (pkg_name, pkg_version, arch_name)
	  REFERENCES binaries (name, version, arch_name)
);

--- Arch-specific package information
CREATE TABLE build_jobs (
	id serial			-- build id
	  CONSTRAINT build_jobs_pkey PRIMARY KEY,
       	source_name text		-- package
	  NOT NULL,
	source_version text		-- package version number
	  NOT NULL,
	arch_name text			-- architecture
	  CONSTRAINT build_jobs_arch REFERENCES architectures(name)
	  NOT NULL,
	distribution_name text		-- distribution
	  CONSTRAINT build_jobs_dist REFERENCES distributions(name)
	  NOT NULL,
	builder_name text		-- builder (person making change)
	  CONSTRAINT build_jobs_builder REFERENCES builders(name)
	  NOT NULL,
	state_name text			-- build state
	  CONSTRAINT build_jobs_state REFERENCES states(name)
	  NOT NULL,
	notes text,			-- notes about package
	ctime timestamp with time zone	-- changed time stamp
	  NOT NULL DEFAULT CURRENT_TIMESTAMP,
	CONSTRAINT build_jobs_unique UNIQUE(source_name, source_version,
					    arch_name, ctime),
	CONSTRAINT build_jobs_fkey FOREIGN KEY(source_name, source_version)
	  REFERENCES sources(name, version)
);

--- For PermBuildPri/BuildPri/Binary-NMU-(Version|ChangeLog)
CREATE TABLE source_arch_props (
	job_id integer NOT NULL	        -- job reference
	  REFERENCES build_jobs(id),
	prop_name text NOT NULL,	-- property name
	prop_value text NOT NULL	--property value
);
