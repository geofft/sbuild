#
# Conf.pm: configuration library for sbuild
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
# Copyright © 2006 Roger Leigh <rleigh@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Sbuild::Conf;

use strict;
use warnings;
use Cwd qw(cwd);

sub init ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw($HOME %alternatives $apt_policy $apt_update
		 $check_watches $cwd $username $verbose $nolog
		 $mailprog $dpkg $su $schroot $schroot_options
		 $fakeroot $apt_get $apt_cache $dpkg_source $dcmd
		 $md5sum $avg_time_db $avg_space_db $package_checklist
		 $build_env_cmnd $pgp_options $log_dir $mailto
		 $mailfrom @no_auto_upgrade $check_depends_algorithm
		 $purge_build_directory @toolchain_regex
		 $stalled_pkg_timeout $srcdep_lock_dir
		 $srcdep_lock_wait @ignore_watches_no_build_deps
		 $build_dir $sbuild_mode $debug $force_orig_source
		 %individual_stalled_pkg_timeout $path
		 $maintainer_name $uploader_name %watches $key_id);
}

# Originally from the main namespace.
(our $HOME = $ENV{'HOME'})
    or die "HOME not defined in environment!\n";
our $username = (getpwuid($<))[0] || $ENV{'LOGNAME'} || $ENV{'USER'};
our $cwd = cwd();
our $verbose = 0;
our $nolog = 0;

# Defaults.
# TODO: Remove $source_dependencies after Lenny.
our $source_dependencies;
our $mailprog = "/usr/sbin/sendmail";
our $dpkg = "/usr/bin/dpkg";
our $sudo;
our $su = "/bin/su";
our $schroot = "/usr/bin/schroot";
our $schroot_options = "-q";
our $fakeroot = "/usr/bin/fakeroot";
our $apt_get = "/usr/bin/apt-get";
our $apt_cache = "/usr/bin/apt-cache";
our $dpkg_source = "/usr/bin/dpkg-source";
our $dcmd = "/usr/bin/dcmd";
our $md5sum = "/usr/bin/md5sum";
our $avg_time_db = "/var/lib/sbuild/avg-build-times";
our $avg_space_db = "/var/lib/sbuild/avg-build-space";
our $package_checklist = "/var/lib/sbuild/package-checklist";
our $build_env_cmnd = "";
our $pgp_options = "-us -uc";
our $log_dir = "$HOME/logs";
our $mailto = "";
our $mailfrom = "Source Builder <sbuild>";
our $purge_build_directory = "successful";
our @toolchain_regex = ( 'binutils$', 'gcc-[\d.]+$', 'g\+\+-[\d.]+$', 'libstdc\+\+', 'libc[\d.]+-dev$', 'linux-kernel-headers$', 'linux-libc-dev$', 'gnumach-dev$', 'hurd-dev$', 'kfreebsd-kernel-headers$');
our $stalled_pkg_timeout = 150; # minutes
our $srcdep_lock_dir = "/var/lib/sbuild/srcdep-lock";
our $srcdep_lock_wait = 1; # minutes
# TODO: Remove $chroot_only after Lenny
our $chroot_only;
# TODO: Remove $chroot_mode after Lenny
our $chroot_mode;
our $apt_policy = 1;
our $check_watches = 1;
our @ignore_watches_no_build_deps = qw();
our %watches;
# TODO: Remove $build_dir after Lenny
our $build_dir = undef;
our $sbuild_mode = "user";
our $debug = 0;
our $force_orig_source = 0;
our %individual_stalled_pkg_timeout = ();
our $path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/X11R6/bin:/usr/games";
our $maintainer_name;
our $uploader_name;
our $key_id;
our $apt_update = 0;
our %alternatives = ("info-browser"		=> "info",
		     "httpd"			=> "apache",
		     "postscript-viewer"	=> "ghostview",
		     "postscript-preview"	=> "psutils",
		     "www-browser"		=> "lynx",
		     "awk"			=> "gawk",
		     "c-shell"			=> "tcsh",
		     "wordlist"			=> "wenglish",
		     "tclsh"			=> "tcl8.4",
		     "wish"			=> "tk8.4",
		     "c-compiler"		=> "gcc",
		     "fortran77-compiler"	=> "g77",
		     "java-compiler"		=> "jikes",
		     "libc-dev"			=> "libc6-dev",
		     "libgl-dev"		=> "xlibmesa-gl-dev",
		     "libglu-dev"		=> "xlibmesa-glu-dev",
		     "libncurses-dev"		=> "libncurses5-dev",
		     "libz-dev"			=> "zlib1g-dev",
		     "libg++-dev"		=> "libstdc++6-4.0-dev",
		     "emacsen"			=> "emacs21",
		     "mail-transport-agent"	=> "ssmtp",
		     "mail-reader"		=> "mailx",
		     "news-transport-system"	=> "inn",
		     "news-reader"		=> "nn",
		     "xserver"			=> "xvfb",
		     "mysql-dev"		=> "libmysqlclient-dev",
		     "giflib-dev"		=> "libungif4-dev",
		     "freetype2-dev"		=> "libttf-dev");

our @no_auto_upgrade = qw(dpkg apt bash libc6 libc6-dev dpkg-dev);
our $check_depends_algorithm = "first-only";

# read conf files
require "/etc/sbuild/sbuild.conf" if -r "/etc/sbuild/sbuild.conf";
require "$HOME/.sbuildrc" if -r "$HOME/.sbuildrc";

sub init () {
    # some checks
    die "mailprog binary $Sbuild::Conf::mailprog does not exist or isn't executable\n"
	if !-x $Sbuild::Conf::mailprog;
    die "schroot binary $Sbuild::Conf::schroot does not exist or isn't executable\n"
	if !-x $Sbuild::Conf::schroot;
    die "apt-get binary $Sbuild::Conf::apt_get does not exist or isn't executable\n"
	if !-x $Sbuild::Conf::apt_get;
    die "apt-cache binary $Sbuild::Conf::apt_cache does not exist or isn't executable\n"
	if !-x $Sbuild::Conf::apt_cache;
    die "dpkg-source binary $Sbuild::Conf::dpkg_source does not exist or isn't executable\n"
	if !-x $Sbuild::Conf::dpkg_source;
    die "$Sbuild::Conf::srcdep_lock_dir is not a directory\n"
	if ! -d $Sbuild::Conf::srcdep_lock_dir;

    die "mailto not set\n" if !$Sbuild::Conf::mailto && $sbuild_mode eq "buildd";

    if (!defined($Sbuild::Conf::build_dir)) {
	$Sbuild::Conf::build_dir = $Sbuild::Conf::cwd;
    }
    if (! -d "$Sbuild::Conf::build_dir") {
	die "Build directory $Sbuild::Conf::build_dir does not exist";
    }

    # TODO: Remove chroot_mode, chroot_only, sudo and
    # source_dependencies after Lenny.

    if (defined($chroot_mode)) {
	die "chroot_mode is obsolete";
    }

    if (defined($chroot_only)) {
	die "chroot_only is obsolete";
    }

    if (defined($sudo)) {
	die "sudo is obsolete";
    }

    if (defined($source_dependencies)) {
	die "Source dependencies are obsolete";
    }

}

1;
