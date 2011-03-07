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

man_MANS =				\
	buildd.1			\
	buildd.conf.5			\
	buildd-mail.1			\
	buildd-uploader.1		\
	buildd-vlog.1			\
	buildd-watcher.1		\
	sbuild.1			\
	sbuild.conf.5			\
	sbuild-abort.1			\
	sbuild-adduser.8		\
	sbuild-apt.1			\
	sbuild-checkpackages.1		\
	sbuild-createchroot.8		\
	sbuild-hold.1			\
	sbuild-setup.7			\
	sbuild-shell.1			\
	sbuild-stats.1			\
	sbuild-update.1			\
	wanna-build.1			\
	wanna-build-catdb.1		\
	wanna-build-mail.1		\
	wanna-build-merge-packages.1	\
	wanna-build-statistics.1

sbuild.conf.man: $(abs_top_srcdir)/tools/sbuild-dumpconfig
	PERL5LIB=$(abs_top_srcdir)/lib:$(abs_top_builddir)/lib \
	  $< sbuild man > $@

buildd.conf.man: $(abs_top_srcdir)/tools/sbuild-dumpconfig
	PERL5LIB=$(abs_top_srcdir)/lib:$(abs_top_builddir)/lib \
	  $< buildd man > $@

sbuild.conf.5: sbuild.conf.5.in defs.man sbuild.conf.man
	soelim $< > $@

buildd.conf.5: buildd.conf.5.in defs.man buildd.conf.man
	soelim $< > $@

%.1: %.1.in defs.man
	soelim $< > $@

%.5: %.5.in defs.man
	soelim $< > $@

%.7: %.7.in defs.man
	soelim $< > $@

%.8: %.8.in defs.man
	soelim $< > $@

CLEANFILES = 				\
	sbuild.conf.man			\
	buildd.conf.man

EXTRA_DIST =				\
	defs.man.in			\
	$(addsuffix .in, $(man_MANS))

install-data-hook:
	ln -sf sbuild-hold.1 $(DESTDIR)$(man1dir)/sbuild-unhold.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/sbuild-upgrade.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/sbuild-distupgrade.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/sbuild-clean.1
	ln -sf wanna-build-catdb.1 $(DESTDIR)$(man1dir)/wanna-build-catgdbm.1
	ln -sf wanna-build-catdb.1 $(DESTDIR)$(man1dir)/wanna-build-catmldbm.1
	ln -sf wanna-build-merge-packages.1 $(DESTDIR)$(man1dir)/wanna-build-merge-quinn.1
	ln -sf buildd-mail.1 $(DESTDIR)$(man1dir)/buildd-mail-wrapper.1
	ln -sf sbuild-abort.1 $(DESTDIR)$(man1dir)/buildd-abort.1
	ln -sf sbuild-update.1 $(DESTDIR)$(man1dir)/buildd-update-chroots.1
	ln -sf sbuild-createchroot.8 $(DESTDIR)$(man8dir)/buildd-make-chroot.8
