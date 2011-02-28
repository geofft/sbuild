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
sbuildsysconf_DATA = sbuild.conf

builddsysconfdir = $(BUILDD_SYSCONF_DIR)
builddsysconf_DATA = buildd.conf wanna-build.conf

exampleconfdir = $(docdir)/examples
exampleconf_DATA = example.sbuildrc

COMPAT_SETUP = 25nssdatabases 99builddsourceslist
SETUP =

sbuild.conf: ../tools/sbuild-dumpconfig
	PERL5LIB=../lib $< sbuild config > $@

buildd.conf: ../tools/sbuild-dumpconfig
	PERL5LIB=../lib $< buildd config > $@

schrootsetupdir = $(SCHROOT_SYSCONF_DIR)/setup.d
if SBUILD_COMPAT
schrootsetup_SCRIPTS = $(COMPAT_SETUP) $(SETUP)
else
schrootsetup_SCRIPTS = $(SETUP)
endif

PROFILES =		\
	buildd

profiles: profiles-stamp
profiles-stamp: genprofile
	$(MKDIR_P) profiles
	for profile in $(PROFILES); do 					\
	  $(srcdir)/genprofile "$$profile" "$(PLATFORM)" "$(srcdir)/profile-templates" "profiles/$$profile";	\
	done
	touch $@

all-local: profiles

install-data-hook:
	for profile in $(PROFILES); do 						\
	  $(MKDIR_P) "$(DESTDIR)$(SCHROOT_SYSCONF_DIR)/$$profile";			\
	  for file in "profiles/$$profile"/*; do						\
	    $(INSTALL_DATA) "$$file" "$(DESTDIR)$(SCHROOT_SYSCONF_DIR)/$$profile";	\
	  done;									\
	done

CLEANFILES =		\
	sbuild.conf	\
	buildd.conf

clean-local:
	$(RM) -rf profiles
	$(RM) -f profiles-stamp

EXTRA_DIST =			\
	wanna-build.conf	\
	$(exampleconf_DATA)	\
	$(COMPAT_SETUP)		\
	$(SETUP)		\
	apt-keys		\
	genprofile		\
	profile-templates

.PHONY: profiles
