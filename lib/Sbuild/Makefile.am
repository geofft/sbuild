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

perlmodsbuilddir = $(perlmoddir)/Sbuild

MODULES =			\
	Base.pm			\
	Build.pm		\
	Chroot.pm		\
	ChrootPlain.pm		\
	ChrootRoot.pm		\
	ChrootSchroot.pm	\
	ChrootSudo.pm		\
	ChrootSetup.pm		\
	ChrootInfo.pm		\
	ChrootInfoSchroot.pm	\
	ChrootInfoSudo.pm	\
	Exception.pm		\
	ResolverBase.pm		\
	AptitudeResolver.pm	\
	AptResolver.pm		\
	XaptResolver.pm		\
	InternalResolver.pm	\
	Resolver.pm		\
	Conf.pm			\
	ConfBase.pm		\
	Log.pm			\
	LogBase.pm		\
	Options.pm		\
	OptionsBase.pm		\
	Utility.pm

perlmodsbuild_DATA =	\
	$(MODULES)	\
	Sysconfig.pm

EXTRA_DIST =		\
	$(MODULES)
