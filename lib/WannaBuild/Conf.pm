#
# Conf.pm: configuration library for sbuild
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2008 Roger Leigh <rleigh@debian.org>
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

package WannaBuild::Conf;

use strict;
use warnings;
use Cwd qw(cwd);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw($basedir $dbbase $transactlog @distributions
    %dist_order @sections $pkgs_source $quinn_source @admin_users
    $mailprog $db_maint $notforus_maint $log_mail $stat_mail
    $web_stats);
}


# Defaults.
our $basedir = "/var/lib/wanna-build";

our $dbbase = "build-db";

our $transactlog = "transactions.log";

our @distributions = qw(oldstable-security stable testing unstable
                        stable-security testing-security);

our %dist_order = ('oldstable-security' => 0,
		   'stable' => 1,
		   'stable-security' => 1,
		   'testing' => 2,
		   'testing-security' => 2,
		   'unstable' => 3);

our @sections = qw(main contrib non-free);

our $pkgs_source = "ftp://ftp.debian.org/debian";

our $quinn_source = "http://buildd.debian.org/quinn-diff/output";

our @admin_users = qw(buildd);

our $mailprog = "/usr/sbin/sendmail";

our $db_maint = "buildd";

our $notforus_maint = "buildd";

our $log_mail = undef;

our $stat_mail = undef;

our $web_stats = undef;

# read conf files
require "/etc/buildd/wanna-build.conf" if -r "/etc/buildd/wanna-build.conf";
require "$HOME/.wanna-buildrc" if -r "$HOME/.wanna-buildrc";

sub init {
    # some checks

    die "$conf::basedir is not a directory\n" if ! -d $conf::basedir;
    die "dbbase is empty\n" if ! $dbbase;
    die "transactlog is empty\n" if ! $transactlog;
    die "mailprog binary $conf::mailprog does not exist or isn't executable\n"
	if !-x $conf::mailprog;
}

1;
