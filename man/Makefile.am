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

man_MANS = \
	sbuild.1		\
	sbuild-abort.1		\
	sbuild-adduser.8	\
	sbuild-apt.1		\
	sbuild-checkpackages.1	\
	sbuild-createchroot.8	\
	sbuild-hold.1		\
	sbuild-setup.7		\
	sbuild-shell.1		\
	sbuild-stats.1		\
	sbuild-update.1		\
	sbuild-upgrade.1	\
	wanna-build.1		\
	wanna-build-catdb.1

install-data-hook:
	ln -sf sbuild-hold.1 $(DESTDIR)$(man1dir)/sbuild-unhold.1
	ln -sf wanna-build-catdb $(DESTDIR)$(man1dir)/wanna-build-catgdbm.1
	ln -sf wanna-build-catdb $(DESTDIR)$(man1dir)/wanna-build-catmldbm.1
