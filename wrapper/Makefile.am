# sbuild Makefile template
#
#
# Copyright © 2004-2011  Roger Leigh <rleigh@debian.org>
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

DEFS=-DSBUILD_LIBEXEC_DIR=\"$(SBUILD_LIBEXEC_DIR)\"

sbuildlibexec_PROGRAMS = sbuild-schroot

sbuild_schroot_SOURCES = 	\
	wrapper.cc		\
	util.h			\
	util.cc
