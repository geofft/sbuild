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

INSERT INTO architectures (arch) VALUES
  ('alpha'),
  ('amd64'),
  ('arm'),
  ('armel'),
  ('hppa'),
  ('hurd-i386'),
  ('i386'),
  ('ia64'),
  ('m68k'),
  ('mips'),
  ('mipsel'),
  ('powerpc'),
  ('s390'),
  ('sparc');

INSERT INTO suites (suite, priority) VALUES
  ('oldstable', 1),
  ('stable', 1),
  ('testing', 2),
  ('unstable', 3),
  ('experimental', 4);

INSERT INTO suites (suite, priority, depwait, hidden) VALUES
  ('oldstable-security', 1, 'f', 't'),
  ('stable-security', 1, 'f', 't'),
  ('testing-security', 2, 'f', 't');

INSERT INTO suite_arches (suite, arch) VALUES
  ('oldstable', 'alpha'),
  ('oldstable', 'amd64'),
  ('oldstable', 'arm'),
  ('oldstable', 'hppa'),
  ('oldstable', 'i386'),
  ('oldstable', 'ia64'),
  ('oldstable', 'mips'),
  ('oldstable', 'mipsel'),
  ('oldstable', 'powerpc'),
  ('oldstable', 's390'),
  ('oldstable', 'sparc'),
  ('stable', 'alpha'),
  ('stable', 'amd64'),
  ('stable', 'arm'),
  ('stable', 'armel'),
  ('stable', 'hppa'),
  ('stable', 'i386'),
  ('stable', 'ia64'),
  ('stable', 'mips'),
  ('stable', 'mipsel'),
  ('stable', 'powerpc'),
  ('stable', 's390'),
  ('stable', 'sparc'),
  ('testing', 'alpha'),
  ('testing', 'amd64'),
  ('testing', 'armel'),
  ('testing', 'hppa'),
  ('testing', 'i386'),
  ('testing', 'ia64'),
  ('testing', 'mips'),
  ('testing', 'mipsel'),
  ('testing', 'powerpc'),
  ('testing', 's390'),
  ('testing', 'sparc'),
  ('unstable', 'alpha'),
  ('unstable', 'amd64'),
  ('unstable', 'armel'),
  ('unstable', 'hppa'),
  ('unstable', 'i386'),
  ('unstable', 'ia64'),
  ('unstable', 'mips'),
  ('unstable', 'mipsel'),
  ('unstable', 'powerpc'),
  ('unstable', 's390'),
  ('unstable', 'sparc'),
  ('experimental', 'alpha'),
  ('experimental', 'amd64'),
  ('experimental', 'armel'),
  ('experimental', 'hppa'),
  ('experimental', 'i386'),
  ('experimental', 'ia64'),
  ('experimental', 'mips'),
  ('experimental', 'mipsel'),
  ('experimental', 'powerpc'),
  ('experimental', 's390'),
  ('experimental', 'sparc');

INSERT INTO components (component) VALUES
  ('main'),
  ('contrib'),
  ('non-free');

INSERT INTO package_types (type) VALUES
  ('deb'),
  ('udeb');

INSERT INTO package_priorities (pkg_prio, prio_val) VALUES
 ('required', 1),
 ('standard', 2),
 ('important', 3),
 ('optional', 4),
 ('extra', 5);
