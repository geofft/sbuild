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
	sbuild-abort		\
	sbuild-apt		\
	sbuild-checkpackages	\
	sbuild-update		\
	sbuild-upgrade		\
	sbuild-shell		\
	sbuild-stats		\
	sbuild-hold		\
	sbuild-unhold

sbin_SCRIPTS = 			\
	sbuild-adduser		\
	sbuild-createchroot

pkglibexec_SCRIPTS =		\
	dobuildlog

doc_DATA = 		\
	README.bins

EXTRA_DIST =			\
	$(bin_SCRIPTS)		\
	$(sbin_SCRIPTS) 	\
	$(pkglibexec_SCRIPTS)	\
	$(doc_DATA)

install-exec-hook:
# Links for compatibility.
	ln -sf $(sbindir)/sbuild-adduser $(DESTDIR)$(pkglibexecdir)/add_sbuild_user
	ln -sf $(sbindir)/sbuild-createchroot $(DESTDIR)$(pkglibexecdir)/buildd.chroot
	ln -sf $(bindir)/sbuild-apt $(DESTDIR)$(pkglibexecdir)/chrapt
	ln -sf $(bindir)/sbuild-upgrade $(DESTDIR)$(pkglibexecdir)/upgradechroot
	ln -sf $(bindir)/sbuild-update $(DESTDIR)$(pkglibexecdir)/updatechroot
	ln -sf $(bindir)/sbuild-shell $(DESTDIR)$(pkglibexecdir)/gochroot
	ln -sf $(bindir)/sbuild-hold $(DESTDIR)$(pkglibexecdir)/chr-hold
	ln -sf $(bindir)/sbuild-unhold $(DESTDIR)$(pkglibexecdir)/chr-unhold
	ln -sf $(bindir)/sbuild-abort $(DESTDIR)$(pkglibexecdir)/abort-current-build
	ln -sf $(bindir)/sbuild-checkpackages $(DESTDIR)$(pkglibexecdir)/checkchroot
	ln -sf sbuild-stats $(DESTDIR)$(bindir)/avg-pkg-build-time
	ln -sf sbuild-stats $(DESTDIR)$(bindir)/avg-pkg-build-space
