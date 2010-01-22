# sbuild Makefile template
#
#
# Copyright © 2004-2008  Roger Leigh <rleigh@debian.org>
#
# sbuild is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# sbuild is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#####################################################################

include $(top_srcdir)/scripts/global.mk

sbuildsysconfdir = $(SBUILD_SYSCONF_DIR)
sbuildsysconf_DATA = sbuild.conf nssdatabases-defaults

builddsysconfdir = $(BUILDD_SYSCONF_DIR)
builddsysconf_DATA = buildd.conf wanna-build.conf

exampleconfdir = $(docdir)/examples
exampleconf_DATA = example.sbuildrc

schrootsysconfdir = $(SCHROOT_SYSCONF_DIR)
schrootsysconf_DATA = mount-defaults.buildd script-defaults.buildd

schrootsetupdir = $(SCHROOT_SYSCONF_DIR)/setup.d
schrootsetup_SCRIPTS = 25nssdatabases

EXTRA_DIST =			\
	$(sbuildsysconf_DATA)	\
	$(builddsysconf_DATA)	\
	$(exampleconf_DATA)	\
	$(schrootsysconf_DATA)	\
	$(schrootsetup_SCRIPTS)
