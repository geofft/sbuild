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

sbuilddatadir = $(SBUILD_DATA_DIR)

bin_SCRIPTS = 				\
	sbuild				\
	sbuild-abort			\
	sbuild-apt			\
	sbuild-checkpackages		\
	sbuild-update			\
	sbuild-upgrade			\
	sbuild-distupgrade		\
	sbuild-clean			\
	sbuild-shell			\
	sbuild-hold			\
	sbuild-unhold			\
	buildd				\
	buildd-mail			\
	buildd-uploader			\
	buildd-vlog			\
	buildd-update-chroots		\
	buildd-watcher

sbin_SCRIPTS = 			\
	sbuild-adduser		\
	sbuild-createchroot

sbuilddata_SCRIPTS =		\
	create-chroot		\
	dobuildlog

doc_DATA = 		\
	README.bins

EXTRA_DIST =			\
	$(bin_SCRIPTS)		\
	$(sbin_SCRIPTS) 	\
	$(sbuilddata_SCRIPTS)	\
	$(doc_DATA)

install-exec-hook:
# Additional directories
	$(MKDIR_P) "$(DESTDIR)$(sbuilddatadir)"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/.ssh"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/build"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/build-trees"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/logs"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/mqueue"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/old-logs"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/stats/graphs"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/upload"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/buildd/upload-security"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/sbuild"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/sbuild/build"
	$(MKDIR_P) "$(DESTDIR)$(localstatedir)/lib/sbuild/apt-keys"

# Links for compatibility.
	ln -sf "$(bindir)/buildd-mail" "$(DESTDIR)$(bindir)/buildd-mail-wrapper"
	ln -sf "$(bindir)/sbuild-abort" "$(DESTDIR)$(bindir)/buildd-abort"

