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

sbuildlibexecdir = $(SBUILD_LIBEXEC_DIR)
wblibexecdir = $(WANNABUILD_LIBEXEC_DIR)

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
	sbuild-unhold		\
	wanna-build		\
	wanna-build-catdb	\
	wanna-build-mail	\
	wanna-build-statistics

sbin_SCRIPTS = 			\
	sbuild-adduser		\
	sbuild-createchroot

sbuildlibexec_SCRIPTS =		\
	dobuildlog

doc_DATA = 		\
	README.bins

EXTRA_DIST =			\
	$(bin_SCRIPTS)		\
	$(sbin_SCRIPTS) 	\
	$(sbuildlibexec_SCRIPTS)	\
	$(doc_DATA)

install-exec-hook:
# Links for compatibility.
	$(MKDIR_P) "$(DESTDIR)$(sbuildlibexecdir)"
	$(MKDIR_P) "$(DESTDIR)$(wblibexecdir)"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/wanna-build"

	ln -sf "$(bindir)/wanna-build-catdb" "$(DESTDIR)$(bindir)/wanna-build-catgdbm"
	ln -sf "$(bindir)/wanna-build-catdb" "$(DESTDIR)$(bindir)/wanna-build-catmldbm"

	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/wanna-build"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/uploaded-build"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/failed-build"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/dep-wait-build"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/forget-build"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/no-build"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/build-info"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-needs-build"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-building"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-uploaded"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-installed"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-failed"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-dep-wait"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-not-for-us"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/list-all"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/merge-quinn"
	ln -sf "$(bindir)/wanna-build" "$(DESTDIR)$(wblibexecdir)/merge-packages"

