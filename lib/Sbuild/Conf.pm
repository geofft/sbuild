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

    @EXPORT = qw($dpkg $su
                 $schroot $schroot_options $fakeroot $apt_get
                 $apt_cache $dpkg_source $dcmd $md5sum $avg_time_db
                 $avg_space_db $stats_dir $package_checklist
                 $build_env_cmnd $pgp_options $log_dir $mailto
                 $mailfrom @no_auto_upgrade $check_depends_algorithm
                 $purge_build_directory @toolchain_regex
                 $stalled_pkg_timeout $srcdep_lock_dir
                 $srcdep_lock_wait $max_lock_trys $lock_interval
                 @ignore_watches_no_build_deps $build_dir $sbuild_mode
                 $debug $force_orig_source
                 %individual_stalled_pkg_timeout $path
                 $maintainer_name $uploader_name %watches $key_id);
}

INIT {
    init();
}

(our $HOME = $ENV{'HOME'})
    or die "HOME not defined in environment!\n";
our $cwd = cwd();

# Defaults.
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
our $stats_dir = "$HOME/stats";
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
our $max_lock_trys = 120;
our $lock_interval = 5;
our $apt_policy = 1;
our $check_watches = 1;
our @ignore_watches_no_build_deps = qw();
our %watches;
our $sbuild_mode = "user";
our $debug = 0;
our $force_orig_source = 0;
our %individual_stalled_pkg_timeout = ();
our $path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/X11R6/bin:/usr/games";
our $maintainer_name;
our $uploader_name;
our $key_id;
our $apt_update = 0;
our $apt_allow_unauthenticated = 0;
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
}

sub set_allowed_keys (\%);
sub is_allowed (\%$);
sub read_config (\%);
sub check_config (\%);
sub new ();
sub get (\%$);
sub set (\%$$);

sub set_allowed_keys (\%) {
    my $self = shift;

    my %allowed_keys = (
	'HOME'					=> "",
	'USERNAME'				=> "",
	'CWD'					=> "",
	'VERBOSE'				=> "",
	'NOLOG'					=> "",
	'SOURCE_DEPENDENCIES'			=> "",
	'MAILPROG'				=> "",
	'DPKG'					=> "",
	'SUDO'					=> "",
	'SU'					=> "",
	'SCHROOT'				=> "",
	'SCHROOT_OPTIONS'			=> "",
	'FAKEROOT'				=> "",
	'APT_GET'				=> "",
	'APT_CACHE'				=> "",
	'DPKG_SOURCE'				=> "",
	'MD5SUM'				=> "",
	'AVG_TIME_DB'				=> "",
	'AVG_SPACE_DB'				=> "",
	'PACKAGE_CHECKLIST'			=> "",
	'BUILD_ENV_CMND'			=> "",
	'PGP_OPTIONS'				=> "",
	'LOG_DIR'				=> "",
	'MAILTO'				=> "",
	'MAILFROM'				=> "",
	'PURGE_BUILD_DIRECTORY'			=> "",
	'TOOLCHAIN_REGEX'			=> "",
	'STALLED_PKG_TIMEOUT'			=> "",
	'SRCDEP_LOCK_DIR'			=> "",
	'SRCDEP_LOCK_WAIT'			=> "",
	'CHROOT_ONLY'				=> "",
	'CHROOT_MODE'				=> "",
	'APT_POLICY'				=> "",
	'CHECK_WATCHES'				=> "",
	'IGNORE_WATCHES_NO_BUILD_DEPS'		=> "",
	'WATCHES'				=> "",
	'BUILD_DIR'				=> "",
	'SBUILD_MODE'				=> "",
	'DEBUG'					=> "",
	'FORCE_ORIG_SOURCE'			=> "",
	'INDIVIDUAL_STALLED_PKG_TIMEOUT'	=> "",
	'PATH'					=> "",
	'MAINTAINER_NAME'			=> "",
	'UPLOADER_NAME'				=> "",
	'KEY_ID'				=> "",
	'APT_UPDATE'				=> "",
	'APT_ALLOW_UNAUTHENTICATED'		=> "",
	'ALTERNATIVES'				=> "",
	'NO_AUTO_UPGRADE'			=> "",
	'CHECK_DEPENDS_ALGORITHM'		=> "");

    $self->{'_allowed_keys'} = \%allowed_keys;
}

sub is_allowed (\%$) {
    my $self = shift;
    my $key = shift;

    return defined($self->{'_allowed_keys'}->{$key});
}

sub read_config (\%) {
    my $self = shift;

    ($self->set('HOME', $ENV{'HOME'}))
	or die "HOME not defined in environment!\n";
    $self->set('USERNAME',(getpwuid($<))[0] || $ENV{'LOGNAME'} || $ENV{'USER'});
    $self->set('CWD', cwd());
    $self->set('VERBOSE', 0);
    $self->set('NOLOG', 0);

# Insert globals here after transition

    $self->set('MAILPROG', $mailprog);
    $self->set('DPKG', $dpkg);
    $self->set('SUDO',  $sudo);
    $self->set('SU', $su);
    $self->set('SCHROOT', $schroot);
    $self->set('SCHROOT_OPTIONS', $schroot_options);
    $self->set('FAKEROOT', $fakeroot);
    $self->set('APT_GET', $apt_get);
    $self->set('APT_CACHE', $apt_cache);
    $self->set('DPKG_SOURCE', $dpkg_source);
    $self->set('MD5SUM', $md5sum);
    $self->set('AVG_TIME_DB', $avg_time_db);
    $self->set('AVG_SPACE_DB', $avg_space_db);
    $self->set('PACKAGE_CHECKLIST', $package_checklist);
    $self->set('BUILD_ENV_CMND', $build_env_cmnd);
    $self->set('PGP_OPTIONS', $pgp_options);
    $self->set('LOG_DIR', $log_dir);
    $self->set('MAILTO', $mailto);
    $self->set('MAILFROM', $mailfrom);
    $self->set('PURGE_BUILD_DIRECTORY', $purge_build_directory);
    $self->set('TOOLCHAIN_REGEX', \@toolchain_regex);
    $self->set('STALLED_PKG_TIMEOUT', $stalled_pkg_timeout);
    $self->set('SRCDEP_LOCK_DIR', $srcdep_lock_dir);
    $self->set('SRCDEP_LOCK_WAIT', $srcdep_lock_wait);
    $self->set('APT_POLICY', $apt_policy);
    $self->set('CHECK_WATCHES', $check_watches);
    $self->set('IGNORE_WATCHES_NO_BUILD_DEPS', \@ignore_watches_no_build_deps);
    $self->set('WATCHES', \%watches);
    $self->set('SBUILD_MODE', $sbuild_mode);
    $self->set('DEBUG', $debug);
    $self->set('FORCE_ORIG_SOURCE', $force_orig_source);
    $self->set('INDIVIDUAL_STALLED_PKG_TIMEOUT', \%individual_stalled_pkg_timeout);
    $self->set('PATH', $path);
    $self->set('MAINTAINER_NAME', $maintainer_name);
    $self->set('UPLOADER_NAME', $uploader_name);
    $self->set('KEY_ID', $key_id);
    $self->set('APT_UPDATE', $apt_update);
    $self->set('APT_ALLOW_UNAUTHENTICATED', $apt_allow_unauthenticated);
    $self->set('ALTERNATIVES', \%alternatives);
    $self->set('NO_AUTO_UPGRADE', @no_auto_upgrade);
    $self->set('CHECK_DEPENDS_ALGORITHM', $check_depends_algorithm);
}

sub check_config (\%) {
    my $self = shift;

    die "mailprog binary " . $self->get('MAILPROG') . " does not exist or isn't executable\n"
	if !-x $self->get('MAILPROG');
    die "schroot binary " . $self->get('SCHROOT') . " does not exist or isn't executable\n"
	if !-x $self->get('SCHROOT');
    die "apt-get binary " . $self->get('APT_GET') . " does not exist or isn't executable\n"
	if !-x $self->get('APT_GET');
    die "apt-cache binary " . $self->get('APT_CACHE') . " does not exist or isn't executable\n"
	if !-x $self->get('APT_CACHE');
    die "dpkg-source binary " . $self->get('DPKG_SOURCE') . " does not exist or isn't executable\n"
	if !-x $self->get('DPKG_SOURCE');
    die $self->get('SRCDEP_LOCK_DIR') . " is not a directory\n"
	if ! -d $self->get('SRCDEP_LOCK_DIR');

    die "mailto not set\n" if !$self->get('MAILTO');

    if (!defined($self->get('BUILD_DIR'))) {
	$self->set('BUILD_DIR', $self->get('CWD'));
    }
    if (! -d $self->get('BUILD_DIR')) {
	die "Build directory " . $self->get('BUILD_DIR') . " does not exist";
    }
}

sub new () {
    my $self  = {};
    $self->{'config'} = {};
    bless($self);

    $self->set_allowed_keys();
    $self->read_config();
    $self->check_config();

    return $self;
}

sub get (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->{$key};
}

sub set (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    if ($self->is_allowed($key)) {
	return $self->{$key} = $value;
    } else {
	warn "W: key \"$key\" is not allowed in sbuild configuration";
	return undef;
    }
}

1;
