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

pkglibexecdir = $(SBUILD_LIBEXEC_DIR)

bin_SCRIPTS = 			\
	sbuild			\
	sbuild-createchroot

pkglibexec_SCRIPTS =		\
	abort-current-build	\
	add_sbuild_user		\
	avg-pkg-build-time	\
	checkchroot		\
	chrapt			\
	chr-hold		\
	chr-unhold		\
	dobuildlog		\
	gochroot		\
	updatechroot		\
	upgradechroot

doc_DATA = 		\
	README.bins

install-exec-hook:
	ln -sf avg-pkg-build-time $(DESTDIR)$(pkglibexecdir)/avg-pkg-build-space
	ln -sf $(bindir)/sbuild-createchroot $(DESTDIR)$(pkglibexecdir)/buildd.chroot
