# sbuild Makefile template
#
#
# Copyright © 2004-2009  Roger Leigh <rleigh@debian.org>
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

if BUILD_DEBVERSION
pg_server_lib_LTLIBRARIES =	\
	debversion.la

debversion_la_SOURCES =	\
	debversion.cc

debversion_la_CXXFLAGS = -I$(pg_server_includedir)
debversion_la_LDFLAGS = -module -avoid-version $(APT_PKG_LIBS)

pg_contrib_DATA =			\
	debversion.sql			\
	uninstall_debversion.sql
endif

debversion.sql: debversion.sql.in
	sed 's,MODULE_PATHNAME,$$libdir/$*,g' $< >$@

CLEANFILES =	\
	debversion.sql

EXTRA_DIST =				\
	db.sql				\
	debversion.sql.in		\
	uninstall_debversion.sql	\
	Makefile-pgxs
