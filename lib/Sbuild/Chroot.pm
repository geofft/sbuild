#
# Chroot.pm: chroot library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
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

package Sbuild::Chroot;

use Sbuild qw(copy debug);
use Sbuild::Base;
use Sbuild::Conf;
use Sbuild::ChrootInfo;
use Sbuild::ChrootSetup qw(basesetup);

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Session ID', "");
    $self->set('Chroot ID', $chroot_id);
    $self->set('Split', $self->get_conf('CHROOT_SPLIT'));
    $self->set('Defaults', {
	'COMMAND' => [],
	'INTCOMMAND' => [], # Private
	'EXPCOMMAND' => [], # Private
	'ENV' => {},
	'USER' => 'root',
	'CHROOT' => 1,
	'PRIORITY' => 0,
	'DIR' => '/',
	'SETSID' => 0,
	'STREAMIN' => undef,
	'STREAMOUT' => undef,
	'STREAMERR' => undef});

    if (!defined($self->get('Chroot ID'))) {
	return undef;
    }

    return $self;
}

sub _setup_aptconf {
    my $self = shift;
    my $aptconf = shift;

    if ($self->get_conf('APT_ALLOW_UNAUTHENTICATED')) {
	print $aptconf "APT::Get::AllowUnauthenticated true;\n";
    }
    print $aptconf "APT::Install-Recommends false;\n";

    if ($self->get('Split')) {
	my $chroot_dir = $self->get('Location');
	print $aptconf "Dir \"$chroot_dir\";\n";
    }
}

sub _setup_options {
    my $self = shift;

    $self->set('Build Location', $self->get('Location') . "/build");
    $self->set('Srcdep Lock Dir', $self->get('Location') . '/' . $self->get_conf('SRCDEP_LOCK_DIR'));
    $self->set('Install Lock', $self->get('Srcdep Lock Dir') . "/install");

    if (basesetup($self, $self->get('Config'))) {
	print STDERR "Failed to set up chroot\n";
	return 0;
    }
    my $aptconf = "/var/lib/sbuild/apt.conf";
    $self->set('APT Conf', $aptconf);

    my $chroot_aptconf = $self->get('Location') . "/$aptconf";
    $self->set('Chroot APT Conf', $chroot_aptconf);

    # Always write out apt.conf, because it may become outdated.
    if (my $F = new File::Temp( TEMPLATE => "$aptconf.XXXXXX",
				DIR => $self->get('Location'),
				UNLINK => 0) ) {
	$self->_setup_aptconf($F);

	if (! rename $F->filename, $chroot_aptconf) {
	    print STDERR "Can't rename $F->filename to $chroot_aptconf: $!\n";
	    return 0;
	}
    } else {
	print STDERR "Can't create $chroot_aptconf: $!";
	return 0;
    }

    # unsplit mode uses an absolute path inside the chroot, rather
    # than on the host system.
    if ($self->get('Split')) {
	my $chroot_dir = $self->get('Location');

	$self->set('APT Options',
		   ['-o', "Dir::State::status=$chroot_dir/var/lib/dpkg/status",
		    '-o', "DPkg::Options::=--root=$chroot_dir",
		    '-o', "DPkg::Run-Directory=$chroot_dir"]);

	# sudo uses an absolute path on the host system.
	$self->get('Defaults')->{'ENV'}->{'APT_CONFIG'} =
	    $self->get('Chroot APT Conf');
    } else { # no split
	$self->set('APT Options', []);
	$self->get('Defaults')->{'ENV'}->{'APT_CONFIG'} =
	    $self->get('APT Conf');
    }

    return 1;
}

sub strip_chroot_path {
    my $self = shift;
    my $path = shift;

    my $location = $self->get('Location');
    $path =~ s/^\Q$location\E//;

    return $path;
}

sub log_command {
    my $self = shift;
    my $options = shift;

    my $priority = $options->{'PRIORITY'};

    if ((defined($priority) && $priority >= 1) || $self->get_conf('DEBUG')) {
	my $command;
	if ($self->get_conf('DEBUG')) {
	    $command = $options->{'EXPCOMMAND'};
	} else {
	    $command = $options->{'COMMAND'};
	}

	$self->log_info(join(" ", @$command), "\n");
    }
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub pipe_command_internal {
    my $self = shift;
    my $options = shift;

    my $pipetype = "-|";
    $pipetype = "|-" if (defined $options->{'PIPE'} &&
			 $options->{'PIPE'} eq 'out');

    my $pipe = undef;
    my $pid = open($pipe, $pipetype);
    if (!defined $pid) {
	warn "Cannot open pipe: $!\n";
    } elsif ($pid == 0) { # child
	if (!defined $options->{'PIPE'} ||
	    $options->{'PIPE'} ne 'out') { # redirect stdin
	    my $in = undef;
	    $in = $self->get('Defaults')->{'STREAMIN'} if
		(defined($self->get('Defaults')) &&
		 defined($self->get('Defaults')->{'STREAMIN'}));
	    $in = $options->{'STREAMIN'} if defined($options->{'STREAMIN'});
	    if (defined($in) && $in && \*STDIN != $in) {
		open(STDIN, '<&', $in)
		    or warn "Can't redirect stdin\n";
	    }
	} else { # redirect stdout
	    my $out = undef;
	    $out = $self->get('Defaults')->{'STREAMOUT'} if
		(defined($self->get('Defaults')) &&
		 defined($self->get('Defaults')->{'STREAMOUT'}));
	    $out = $options->{'STREAMOUT'} if defined($options->{'STREAMOUT'});
	    if (defined($out) && $out && \*STDOUT != $out) {
		open(STDOUT, '>&', $out)
		    or warn "Can't redirect stdout\n";
	    }
	}
	# redirect stderr
	my $err = undef;
	$err = $self->get('Defaults')->{'STREAMERR'} if
	    (defined($self->get('Defaults')) &&
	     defined($self->get('Defaults')->{'STREAMERR'}));
	$err = $options->{'STREAMERR'} if defined($options->{'STREAMERR'});
	if (defined($err) && $err && \*STDERR != $err) {
	    open(STDERR, '>&', $err)
		or warn "Can't redirect stderr\n";
	}

	my $setsid = undef;
	$setsid = $self->get('Defaults')->{'SETSID'} if
	    (defined($self->get('Defaults')) &&
	     defined($self->get('Defaults')->{'SETSID'}));
	$setsid = $options->{'SETSID'} if defined($options->{'SETSID'});
	setsid() if defined($setsid) && $setsid;

	$self->exec_command($options);
    }

    debug("Pipe (PID $pid, $pipe) created for: ",
	  join(" ", @{$options->{'COMMAND'}}),
	  "\n");

    $options->{'PID'} = $pid;

    return $pipe;
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command_internal {
    my $self = shift;
    my $options = shift;

    my $pid = fork();

    if (!defined $pid) {
	warn "Cannot fork: $!\n";
    } elsif ($pid == 0) { # child
	# redirect stdout
	my $in = undef;
	$in = $self->get('Defaults')->{'STREAMIN'} if
	    (defined($self->get('Defaults')) &&
	     defined($self->get('Defaults')->{'STREAMIN'}));
	$in = $options->{'STREAMIN'} if defined($options->{'STREAMIN'});
	if (defined($in) && $in && \*STDIN != $in) {
	    open(STDIN, '<&', $in)
		or warn "Can't redirect stdin\n";
	}
	# redirect stdout
	my $out = undef;
	$out = $self->get('Defaults')->{'STREAMOUT'} if
	    (defined($self->get('Defaults')) &&
	     defined($self->get('Defaults')->{'STREAMOUT'}));
	$out = $options->{'STREAMOUT'} if defined($options->{'STREAMOUT'});
	if (defined($out) && $out && \*STDOUT != $out) {
	    open(STDOUT, '>&', $out)
		or warn "Can't redirect stdout\n";
	}
	# redirect stderr
	my $err = undef;
	$err = $self->get('Defaults')->{'STREAMERR'} if
	    (defined($self->get('Defaults')) &&
	     defined($self->get('Defaults')->{'STREAMERR'}));
	$err = $options->{'STREAMERR'} if defined($options->{'STREAMERR'});
	if (defined($err) && $err && \*STDERR != $err) {
	    open(STDERR, '>&', $err)
		or warn "Can't redirect stderr\n";
	}

	my $setsid = undef;
	$setsid = $self->get('Defaults')->{'SETSID'} if
	    (defined($self->get('Defaults')) &&
	     defined($self->get('Defaults')->{'SETSID'}));
	$setsid = $options->{'SETSID'} if defined($options->{'SETSID'});
	setsid() if defined($setsid) && $setsid;

	$self->exec_command($options);
    }

    debug("Pipe (PID $pid) created for: ",
	  join(" ", @{$options->{'COMMAND'}}),
	  "\n");

    waitpid($pid, 0);
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});

    return $self->run_command_internal($options);
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub pipe_command {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});

    return $self->pipe_command_internal($options);
}

sub exec_command {
    my $self = shift;
    my $options = shift;

    $self->get_command_internal($options);

    debug("COMMAND: ", join(" ", @{$options->{'COMMAND'}}), "\n");
    debug("INTCOMMAND: ", join(" ", @{$options->{'INTCOMMAND'}}), "\n");
    debug("EXPCOMMAND: ", join(" ", @{$options->{'EXPCOMMAND'}}), "\n");

    $self->log_command($options);

    my $dir = $options->{'CHDIR'};
    my $command = $options->{'EXPCOMMAND'};

    my $chrootenv = $self->get('Defaults')->{'ENV'};
    foreach (keys %$chrootenv) {
	$ENV{$_} = $chrootenv->{$_};
    }

    my $commandenv = $options->{'ENV'};
    foreach (keys %$commandenv) {
	$ENV{$_} = $commandenv->{$_};
    }

    debug("Environment set:\n");
    foreach (sort keys %ENV) {
	debug("  $_=$ENV{$_}\n");
    }

    if (defined($dir) && $dir) {
	debug("Changing to directory: $dir\n");
	chdir($dir) or die "Can't change directory to $dir: $!";
    }

    debug("Running command: ", join(" ", @$command), "\n");
    exec @$command;
    die "Failed to exec: $command->[0]: $!";
}

sub get_apt_command_internal {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'COMMAND'};
    my $apt_options = $self->get('APT Options');

    debug("APT Options: ", join(" ", @$apt_options), "\n")
	if defined($apt_options);

    my @aptcommand = ();
    if (defined($apt_options)) {
	push(@aptcommand, @{$command}[0]);
	push(@aptcommand, @$apt_options);
	if ($#$command > 0) {
	    push(@aptcommand, @{$command}[1 .. $#$command]);
	}
    } else {
	@aptcommand = @$command;
    }

    debug("APT Command: ", join(" ", @aptcommand), "\n");

    $options->{'CHROOT'} = $self->apt_chroot();
    $options->{'CHDIR_CHROOT'} = !$options->{'CHROOT'};

    $options->{'INTCOMMAND'} = \@aptcommand;
}

sub run_apt_command {
    my $self = shift;
    my $options = shift;

    # Set modfied command
    $self->get_apt_command_internal($options);

    return $self->run_command_internal($options);
}

sub pipe_apt_command {
    my $self = shift;
    my $options = shift;

    # Set modfied command
    $self->get_apt_command_internal($options);

    return $self->pipe_command_internal($options);
}

sub apt_chroot {
    my $self = shift;

    my $chroot =  $self->get('Split') ? 0 : 1;

    return $chroot
}

1;
