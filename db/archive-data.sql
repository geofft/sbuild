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

INSERT INTO architectures (arch) VALUES ('alpha');
INSERT INTO architectures (arch) VALUES ('amd64');
INSERT INTO architectures (arch) VALUES ('arm');
INSERT INTO architectures (arch) VALUES ('armel');
INSERT INTO architectures (arch) VALUES ('hppa');
INSERT INTO architectures (arch) VALUES ('hurd-i386');
INSERT INTO architectures (arch) VALUES ('i386');
INSERT INTO architectures (arch) VALUES ('ia64');
INSERT INTO architectures (arch) VALUES ('m68k');
INSERT INTO architectures (arch) VALUES ('mips');
INSERT INTO architectures (arch) VALUES ('mipsel');
INSERT INTO architectures (arch) VALUES ('powerpc');
INSERT INTO architectures (arch) VALUES ('s390');
INSERT INTO architectures (arch) VALUES ('sparc');

INSERT INTO suites (suite, priority) VALUES ('experimental', 4);
INSERT INTO suites (suite, priority) VALUES ('unstable', 3);
INSERT INTO suites (suite, priority) VALUES ('testing', 2);
INSERT INTO suites (suite, priority, depwait, hidden)
	VALUES ('testing-security', 2, 'f', 't');
INSERT INTO suites (suite, priority) VALUES ('stable', 1);
INSERT INTO suites (suite, priority, depwait, hidden)
	VALUES ('stable-security', 1, 'f', 't');
INSERT INTO suites (suite, priority) VALUES ('oldstable', 1);

INSERT INTO components (component) VALUES ('main');
INSERT INTO components (component) VALUES ('contrib');
INSERT INTO components (component) VALUES ('non-free');

INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('required', 1);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('standard', 2);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('important', 3);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('optional', 4);
INSERT INTO package_priorities (pkg_prio, prio_val) VALUES ('extra', 5);
