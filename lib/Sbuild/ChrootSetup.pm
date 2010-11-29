#
# ChrootSetup.pm: chroot maintenance operations
# Copyright © 2005-2009 Roger Leigh <rleigh@debian.org
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

package Sbuild::ChrootSetup;

use strict;
use warnings;

use File::Temp qw(tempfile);
use Sbuild qw($devnull);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(basesetup shell hold_packages unhold_packages
                 list_packages set_package_status generate_keys);
}

sub basesetup ($$);
sub shell ($$);
sub hold_packages ($$@);
sub unhold_packages ($$@);
sub list_packages ($$@);
sub set_package_status ($$$@);
sub generate_keys ($$);

sub basesetup ($$) {
    my $session = shift;
    my $conf = shift;

    # Add sbuild group
    $session->run_command(
	{ COMMAND => ['getent', 'group', 'sbuild'],
	  USER => 'root',
	  STREAMIN => $devnull,
	  STREAMOUT => $devnull,
	  DIR => '/' });
    if ($?) {
	# This will require root privileges.  However, this should
	# only get run at initial chroot setup time.
	my $groupfile = $session->get('Location') . "/etc/group";
	system '/bin/sh', '-c', "getent group sbuild >> $groupfile";
	if ($?) {
	    print STDERR "E: Failed to create group sbuild\n";
	    return $?
	}
    }

    $session->run_command(
	{ COMMAND => ['/bin/sh', '-c',
		      'set -e; if [ ! -d /build ] ; then mkdir -m 0775 /build; fi'],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	print STDERR "E: Failed to create build directory /build\n";
	return $?
    }

    $session->run_command(
	{ COMMAND => ['chown', 'root:sbuild', '/build'],
	  USER => 'root',
	  DIR => '/' });
    return $? if $?;
    if ($?) {
	print STDERR "E: Failed to set root:sbuild ownership on /build\n";
	return $?
    }

    $session->run_command(
	{ COMMAND => ['chmod', '0770', '/build'],
	  USER => 'root',
	  DIR => '/' });
    return $? if $?;
    if ($?) {
	print STDERR "E: Failed to set 0750 permissions on /build\n";
	return $?
    }

    $session->run_command(
	{ COMMAND => ['/bin/sh', '-c',
		      'set -e; if [ ! -d /var/lib/sbuild ] ; then mkdir -m 2770 /var/lib/sbuild; fi'],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	print STDERR "E: Failed to create build directory /var/lib/sbuild\n";
	return $?
    }

    $session->run_command(
	{ COMMAND => ['/bin/sh', '-c',
		      'set -e; if [ ! -d /var/lib/sbuild/srcdep-lock ] ; then mkdir -m 2770 /var/lib/sbuild/srcdep-lock; fi'],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	print STDERR "E: Failed to create sbuild directory /var/lib/sbuild/srcdep-lock\n";
	return $?
    }

    $session->run_command(
	{ COMMAND => ['chown', '-R', 'root:sbuild', '/var/lib/sbuild'],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	print STDERR "E: Failed to set root:sbuild ownership on /var/lib/sbuild/\n";
	return $?
    }

    $session->run_command(
	{ COMMAND => ['chmod', '02770', '/var/lib/sbuild'],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	print STDERR "E: Failed to set 02770 permissions on /var/lib/sbuild/\n";
	return $?
    }

    # Set up debconf selections.
    my $pipe = $session->pipe_command(
	{ COMMAND => ['/usr/bin/debconf-set-selections'],
	  PIPE => 'out',
	  USER => 'root',
	  PRIORITY => 0,
	  DIR => '/' });

    if (!$pipe) {
	warn "Cannot open pipe: $!\n";
    } else {
	foreach my $selection ('man-db man-db/auto-update boolean false') {
	    print $pipe "$selection\n";
	}
	close($pipe);
	if ($?) {
	    print STDERR "E: debconf-set-selections failed\n";
	    return $?
	}
    }

    return 0;
}

sub shell ($$) {
    my $session = shift;
    my $conf = shift;

    $session->run_command(
	{ COMMAND => ['/bin/sh'],
	  PRIORITY => 1,
	  USER => $conf->get('USERNAME'),
	  STREAMIN => \*STDIN,
	  STREAMOUT => \*STDOUT,
	  STREAMERR => \*STDERR });
    return $?
}

sub hold_packages ($$@) {
    my $session = shift;
    my $conf = shift;

    my $status = set_package_status($session, $conf, "hold", @_);

    return $status;
}

sub unhold_packages ($$@) {
    my $session = shift;
    my $conf = shift;

    my $status = set_package_status($session, $conf, "install", @_);

    return $status;
}

sub list_packages ($$@) {
    my $session = shift;
    my $conf = shift;

    $session->run_command(
	{COMMAND => ['dpkg', '--list', @_],
	 USER => 'root',
	 PRIORITY => 0});
    return $?;
}

sub set_package_status ($$$@) {
    my $session = shift;
    my $conf = shift;
    my $status = shift;

    my $pipe = $session->pipe_command(
	{COMMAND => ['dpkg', '--set-selections'],
	 PIPE => 'out',
	 USER => 'root',
	 PRIORITY => 0});

    if (!$pipe) {
	print STDERR "Can't run dpkg --set-selections in chroot\n";
	return 1;
    }

    foreach (@_) {
	print $pipe "$_        $status\n";
    }

    if (!close $pipe) {
	print STDERR "Can't run dpkg --set-selections in chroot\n";
    }

    return $?;
}

sub generate_keys ($$) {
    my $host = shift;
    my $conf = shift;

    my ($tmpfh, $tmpfilename) = tempfile();
    print $tmpfh <<"EOF";
Key-Type: RSA
Key-Length: 1024
Name-Real: Sbuild Signer
Name-Comment: Sbuild Build Dependency Archive Key
Name-Email: buildd-tools-devel\@lists.alioth.debian.org
Expire-Date: 0
EOF
    print $tmpfh '%secring ' . $conf->get('SBUILD_BUILD_DEPENDS_SECRET_KEY') . "\n";
    print $tmpfh '%pubring ' . $conf->get('SBUILD_BUILD_DEPENDS_PUBLIC_KEY') . "\n";
    print $tmpfh '%commit' . "\n";
    close($tmpfh);

    my @command = ('gpg', '--no-default-keyring', '--batch', '--gen-key',
                   $tmpfilename);
    $host->run_command(
        { COMMAND => \@command,
	  USER => $conf->get('USERNAME'),
          PRIORITY => 0,
          DIR => '/'});
    if ($?) {
        return $?;
    }

    # Secret keyring needs to be readable by 'sbuild' group.
    @command = ('chmod', '640',
                $conf->get('SBUILD_BUILD_DEPENDS_SECRET_KEY'));
    $host->run_command(
        { COMMAND => \@command,
	  USER => $conf->get('USERNAME'),
          PRIORITY => 0,
          DIR => '/'});

    return $?;
}

1;
