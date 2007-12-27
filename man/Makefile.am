# sbuild Makefile template
#
#
# Copyright © 2004-2007  Roger Leigh <rleigh@debian.org>
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

man_MANS = \
	avg-pkg-build-time.1	\
	sbuild.1		\
	sbuild-createchroot.1	\
	sbuild-setup.7

install-data-hook:
	ln -sf avg-pkg-build-time.1 $(DESTDIR)$(man1dir)/avg-pkg-build-space.1