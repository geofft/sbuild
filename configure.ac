#                                                              -*- Autoconf -*-
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
#
# Process this file with autoconf to produce a configure script.
#
#####################################################################
pushdef([SBUILD_NAME],              [sbuild])
pushdef([SBUILD_MAJOR_VERSION],     [0])
pushdef([SBUILD_MINOR_VERSION],     [57])
pushdef([SBUILD_MICRO_VERSION],     [3])
pushdef([SBUILD_EXTRA_VERSION],     [])
pushdef([SBUILD_VERSION], SBUILD_MAJOR_VERSION.SBUILD_MINOR_VERSION.SBUILD_MICRO_VERSION[]SBUILD_EXTRA_VERSION)
dnl
dnl The minimum version of autoconf required.
AC_PREREQ(2.59)
dnl Initialise autoconf with the package name, version and
dnl bug-reporting address.
AC_INIT(SBUILD_NAME, SBUILD_VERSION, [buildd-tools-devel@lists.alioth.debian.org])
dnl For safety, check we are in the right directory by
dnl checking for a known unique file.
AC_CONFIG_SRCDIR([bin/sbuild-createchroot])
dnl Place auxilliary scripts here.
AC_CONFIG_AUX_DIR([scripts])
dnl Put macro definitions here.
AC_CONFIG_HEADER([config.h])

AC_COPYRIGHT(
[
Copyright © 2004-2008  Roger Leigh <rleigh@debian.org>

Parts of this configure script come from the 'configure.ac' file, and
are not based on freely-redistributable m4 macros; you can
redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This software is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
])

[SBUILD_MAJOR_VERSION]=SBUILD_MAJOR_VERSION
[SBUILD_MINOR_VERSION]=SBUILD_MINOR_VERSION
[SBUILD_MICRO_VERSION]=SBUILD_MICRO_VERSION
[SBUILD_EXTRA_VERSION]=SBUILD_EXTRA_VERSION
[SBUILD_VERSION]=SBUILD_VERSION
popdef([SBUILD_MAJOR_VERSION])
popdef([SBUILD_MINOR_VERSION])
popdef([SBUILD_MICRO_VERSION])
popdef([SBUILD_EXTRA_VERSION])
popdef([SBUILD_NAME])
popdef([SBUILD_VERSION])

AC_SUBST([SBUILD_MAJOR_VERSION])
AC_SUBST([SBUILD_MINOR_VERSION])
AC_SUBST([SBUILD_MICRO_VERSION])
AC_SUBST([SBUILD_VERSION])

dnl Initialise automake stuff.
AM_INIT_AUTOMAKE([1.9 gnu check-news tar-pax])
AM_MAINTAINER_MODE
SBUILD_RELEASE_DATE

AC_MSG_CHECKING([whether to enable debugging messages])
enable_debug="no"
AC_ARG_ENABLE([debug], [AS_HELP_STRING([--enable-debug], [Enable debugging messages])],
              [ case "${enableval}" in
                yes) enable_debug="yes" ;;
                no)  enable_debug="no" ;;
                unset)  enable_debug="no" ;;
                *) AC_MSG_RESULT([unknown])
                   AC_MSG_ERROR([bad value ${enableval} for --enable-debug]) ;;
                esac])
AC_MSG_RESULT([$enable_debug])
if test "$enable_debug" = "yes"; then
  AC_DEFINE_UNQUOTED([SBUILD_DEBUG], [1], [Enable debugging])
fi

# Checks for programs.
AC_PATH_PROG([FIND], [find])
AC_PATH_PROG([XARGS], [xargs])
AC_PROG_CC_C99

dnl Set PACKAGE_LOCALE_DIR in config.h
AH_TEMPLATE(PACKAGE_LOCALE_DIR, [Package locale directory])
if test "x${prefix}" = "xNONE"; then
  AC_DEFINE_UNQUOTED(PACKAGE_LOCALE_DIR, ["${ac_default_prefix}/share/locale"])
else
  AC_DEFINE_UNQUOTED(PACKAGE_LOCALE_DIR, ["${prefix}/share/locale"])
fi

dnl Set PACKAGE_DATA_DIR in config.h.
AH_TEMPLATE(PACKAGE_DATA_DIR, [Package data directory])
if test "x${datadir}" = 'x${prefix}/share' || test "x${datadir}" = 'x${datarootdir}'; then
  if test "x${prefix}" = "xNONE"; then
    PACKAGE_DATA_DIR="${ac_default_prefix}/share/${PACKAGE}"
  else
    PACKAGE_DATA_DIR="${prefix}/share/${PACKAGE}"
  fi
else
  PACKAGE_DATA_DIR="${datadir}/${PACKAGE}"
fi

AC_DEFINE_UNQUOTED(PACKAGE_DATA_DIR, "${PACKAGE_DATA_DIR}")

PERL_MODULE_DIR="${datadir}/perl5"
AC_SUBST(PERL_MODULE_DIR)

dnl Set PACKAGE_LIB_DIR in config.h.
AH_TEMPLATE(PACKAGE_LIB_DIR, [Package lib directory])
if test "x${libdir}" = 'x${exec_prefix}/lib'; then
  if test "x${exec_prefix}" = "xNONE"; then
    if test "x${prefix}" = "xNONE"; then
      PACKAGE_LIB_DIR="${ac_default_prefix}/lib/${PACKAGE}"
    else
      PACKAGE_LIB_DIR="${prefix}/lib/${PACKAGE}"
    fi
  else
    PACKAGE_LIB_DIR="${exec_prefix}/lib/${PACKAGE}"
  fi
else
  PACKAGE_LIB_DIR="${libdir}/${PACKAGE}"
fi

dnl Set PACKAGE_LIBEXEC_DIR in config.h.
AH_TEMPLATE(PACKAGE_LIBEXEC_DIR, [Package libexec directory])
if test "x${libexecdir}" = 'x${exec_prefix}/libexec'; then
  if test "x${exec_prefix}" = "xNONE"; then
    if test "x${prefix}" = "xNONE"; then
      PACKAGE_LIBEXEC_DIR="${ac_default_prefix}/libexec"
    else
      PACKAGE_LIBEXEC_DIR="${prefix}/libexec"
    fi
  else
    PACKAGE_LIBEXEC_DIR="${exec_prefix}/libexec"
  fi
else
  PACKAGE_LIBEXEC_DIR="${libexecdir}"
fi

SBUILD_LIBEXEC_DIR="${PACKAGE_LIBEXEC_DIR}/sbuild"
AC_SUBST(SBUILD_LIBEXEC_DIR)
AH_TEMPLATE(SBUILD_LIBEXEC_DIR, [Package libexec directory])
AC_DEFINE_UNQUOTED(SBUILD_LIBEXEC_DIR, ["$SBUILD_LIBEXEC_DIR"])

WANNABUILD_LIBEXEC_DIR="${PACKAGE_LIBEXEC_DIR}/wanna-build"
AC_SUBST(WANNABUILD_LIBEXEC_DIR)
AH_TEMPLATE(WANNABUILD_LIBEXEC_DIR, [Package libexec directory])
AC_DEFINE_UNQUOTED(WANNABUILD_LIBEXEC_DIR, ["$WANNABUILD_LIBEXEC_DIR"])

dnl Set PACKAGE_LOCALSTATE_DIR in config.h.
AH_TEMPLATE(PACKAGE_LOCALSTATE_DIR, [Package localstate directory])
if test "x${localstatedir}" = 'x${prefix}/var'; then
  if test "x${prefix}" = "xNONE"; then
    if test "x${prefix}" = "xNONE"; then
      PACKAGE_LOCALSTATE_DIR="${ac_default_prefix}/var"
    else
      PACKAGE_LOCALSTATE_DIR="${prefix}/var"
    fi
  else
    PACKAGE_LOCALSTATE_DIR="${prefix}/var"
  fi
else
  PACKAGE_LOCALSTATE_DIR="${localstatedir}"
fi

dnl Set SBUILD_SYSCONF_DIR in config.h.
AH_TEMPLATE(SBUILD_SYSCONF_DIR, [Package system configuration directory])
if test "x${sysconfdir}" = 'x${prefix}/etc'; then
  if test "x${prefix}" = "xNONE"; then
    SBUILD_SYSCONF_DIR="${ac_default_prefix}/etc"
  else
    SBUILD_SYSCONF_DIR="${prefix}/etc"
  fi
else
  SBUILD_SYSCONF_DIR="${sysconfdir}"
fi
SBUILD_SYSCONF_DIR="${SBUILD_SYSCONF_DIR}/sbuild"
AC_DEFINE_UNQUOTED([SBUILD_SYSCONF_DIR], ["$SBUILD_SYSCONF_DIR"])
AC_SUBST([SBUILD_SYSCONF_DIR])

SBUILD_CONF="${SBUILD_SYSCONF_DIR}/sbuild.conf"
AC_SUBST([SBUILD_CONF])

AH_TEMPLATE(SBUILD_CONF, [sbuild config file path])
AC_DEFINE_UNQUOTED(SBUILD_CONF, ["$SBUILD_CONF"])

dnl Set BUILDD_SYSCONF_DIR in config.h.
AH_TEMPLATE(BUILDD_SYSCONF_DIR, [Package system configuration directory])
if test "x${sysconfdir}" = 'x${prefix}/etc'; then
  if test "x${prefix}" = "xNONE"; then
    BUILDD_SYSCONF_DIR="${ac_default_prefix}/etc"
  else
    BUILDD_SYSCONF_DIR="${prefix}/etc"
  fi
else
  BUILDD_SYSCONF_DIR="${sysconfdir}"
fi
BUILDD_SYSCONF_DIR="${BUILDD_SYSCONF_DIR}/buildd"
AC_DEFINE_UNQUOTED([BUILDD_SYSCONF_DIR], ["$BUILDD_SYSCONF_DIR"])
AC_SUBST([BUILDD_SYSCONF_DIR])

BUILDD_CONF="${BUILDD_SYSCONF_DIR}/buildd.conf"
AC_SUBST([BUILDD_CONF])

dnl Set SCHROOT_SYSCONF_DIR in config.h.
AH_TEMPLATE(SCHROOT_SYSCONF_DIR, [Package system configuration directory])
if test "x${sysconfdir}" = 'x${prefix}/etc'; then
  if test "x${prefix}" = "xNONE"; then
    SCHROOT_SYSCONF_DIR="${ac_default_prefix}/etc"
  else
    SCHROOT_SYSCONF_DIR="${prefix}/etc"
  fi
else
  SCHROOT_SYSCONF_DIR="${sysconfdir}"
fi
SCHROOT_SYSCONF_DIR="${SCHROOT_SYSCONF_DIR}/schroot"
AC_DEFINE_UNQUOTED([SCHROOT_SYSCONF_DIR], ["$SCHROOT_SYSCONF_DIR"])
AC_SUBST([SCHROOT_SYSCONF_DIR])

SCHROOT_CONF="${SCHROOT_SYSCONF_DIR}/schroot.conf"
AC_SUBST([SCHROOT_CONF])

AH_TEMPLATE(BUILDD_CONF, [buildd config file path])
AC_DEFINE_UNQUOTED(BUILDD_CONF, ["$BUILDD_CONF"])

WANNA_BUILD_CONF="${WANNA_BUILD_SYSCONF_DIR}/wanna-build.conf"
AC_SUBST([WANNA_BUILD_CONF])

AH_TEMPLATE(WANNA_BUILD_CONF, [wanna-build config file path])
AC_DEFINE_UNQUOTED(WANNA_BUILD_CONF, ["$WANNA_BUILD_CONF"])

AH_TEMPLATE(SBUILD_DATADIR, [Package data directory])
SBUILD_DATADIR="${PACKAGE_DATA_DIR}/${PACKAGE_VERSION}"
AC_DEFINE_UNQUOTED(SBUILD_DATADIR, ["$SBUILD_DATADIR"])

AH_TEMPLATE(SBUILD_MODULEDIR, [Package module directory])
SBUILD_MODULEDIR="${PACKAGE_LIB_DIR}/${PACKAGE_VERSION}/modules"
AC_DEFINE_UNQUOTED(SBUILD_MODULEDIR, ["$SBUILD_MODULEDIR"])

dnl Configure which files to generate.
AC_CONFIG_FILES([Makefile])
AC_CONFIG_FILES([bin/Makefile])
AC_CONFIG_FILES([configs/Makefile])
AC_CONFIG_FILES([etc/Makefile])
AC_CONFIG_FILES([lib/Makefile])
AC_CONFIG_FILES([lib/Buildd/Makefile])
AC_CONFIG_FILES([lib/Sbuild/Makefile])
AC_CONFIG_FILES([lib/WannaBuild/Makefile])
AC_CONFIG_FILES([lib/Sbuild/Sysconfig.pm])
AC_CONFIG_FILES([man/Makefile])
AC_CONFIG_FILES([man/sbuild.1])
AC_CONFIG_FILES([man/sbuild-abort.1])
AC_CONFIG_FILES([man/sbuild-adduser.8])
AC_CONFIG_FILES([man/sbuild-apt.1])
AC_CONFIG_FILES([man/sbuild-checkpackages.1])
AC_CONFIG_FILES([man/sbuild-createchroot.8])
AC_CONFIG_FILES([man/sbuild-hold.1])
AC_CONFIG_FILES([man/sbuild-setup.7])
AC_CONFIG_FILES([man/sbuild-shell.1])
AC_CONFIG_FILES([man/sbuild-stats.1])
AC_CONFIG_FILES([man/sbuild-update.1])
AC_CONFIG_FILES([man/sbuild-upgrade.1])
AC_CONFIG_FILES([man/wanna-build.1])
AC_CONFIG_FILES([src/Makefile])

dnl Output the generated config.status script.
AC_OUTPUT
