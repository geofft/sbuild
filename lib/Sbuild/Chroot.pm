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

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

my $devnull;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();

    # A file representing /dev/null
    if (!open($devnull, '+<', '/dev/null')) {
	die "Cannot open /dev/null: $!\n";;
    }

}

sub new ($$$);
sub _setup_options (\$\$);
sub strip_chroot_path (\$$);
sub log_command (\$$$);
sub get_command (\$$$$$$);
sub run_command (\$$$$$$);
sub exec_command (\$$$$$$);
sub get_apt_command_internal (\$$$);
sub get_apt_command (\$$$$$$);
sub run_apt_command (\$$$$$$);

sub new ($$$) {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Session ID', "");
    $self->set('Chroot ID', $chroot_id);
    $self->set('Split', $self->get_conf('CHROOT_SPLIT'));
    $self->set('Environment', copy(\%ENV));

    if (!defined($self->get('Chroot ID'))) {
	return undef;
    }

    return $self;
}

sub _setup_aptconf (\$$) {
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

sub _setup_options (\$\$) {
    my $self = shift;

    $self->set('Build Location', $self->get('Location') . "/build");
    $self->set('Srcdep Lock Dir', $self->get('Location') . '/' . $self->get_conf('SRCDEP_LOCK_DIR'));
    $self->set('Install Lock', $self->get('Srcdep Lock Dir') . "/install");

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
	    die "Can't rename $F->filename to $chroot_aptconf: $!\n";
	}
    } else {
	die "Can't create $chroot_aptconf: $!";
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
	$self->get('Environment')->{'APT_CONFIG'} =
	    $self->get('Chroot APT Conf');
    } else { # no split
	$self->set('APT Options', []);
	$self->get('Environment')->{'APT_CONFIG'} =
	    $self->get('APT Conf');
    }
}

sub strip_chroot_path (\$$) {
    my $self = shift;
    my $path = shift;

    my $location = $self->get('Location');
    $path =~ s/^\Q$location\E//;

    return $path;
}

sub log_command (\$$$) {
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

sub get_command (\$$$$$$) {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});
    $self->get_command_internal($options);

    $self->log_command($options);
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command (\$$$$$$) {
    my $self = shift;
    my $options = shift;

    $options->{PIPE} = 'in';
    my $pipe = $self->pipe_command($options);

    if (defined($pipe)) {
	while (<$pipe>) {
	    $self->log("$_");
	}
	return close($pipe);
    } else {
	return 1;
    }
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub pipe_command (\$$$$$$) {
    my $self = shift;
    my $options = shift;

    my $pipetype = "-|";
    $pipetype = "|-" if (defined $options->{PIPE} &&
			 $options->{PIPE} eq 'out');

    my $pipe = undef;
    my $pid = open($pipe, $pipetype);
    if (!defined $pid) {
	warn "Cannot open pipe: $!\n";
    } elsif ($pid == 0) { # child
	if (!defined $options->{PIPE} ||
	    $options->{PIPE} ne 'out') { # redirect stdin
	    my $in = $devnull;
	    $in = $options->{STREAMIN} if defined($options->{STREAMIN});
	open(STDIN, '<&', $devnull)
	    or warn "Can't redirect stdin\n";
	} else { # redirect stdout
	    my $out = $self->get('Log Stream');
	    $out = $options->{STREAMOUT} if defined($options->{STREAMOUT});
	    open(STDOUT, '>&', $out)
		or warn "Can't redirect stdout\n";
	}
	# redirect stderr
	my $err = $self->get('Log Stream');
	$err = $options->{STREAMERR} if defined($options->{STREAMERR});
	open(STDERR, '>&', $err)
	    or warn "Can't redirect stderr\n";
	if ($err) {
	    open(STDERR, '>&', $err)
		or warn "Can't redirect stderr\n";
	}

	$self->exec_command($options);
    }

    debug("Pipe (PID $pid, $pipe) created for: ",
	  join(" ", @{$options->{'COMMAND'}}),
	  "\n");

    $options->{'PID'} = $pid;

    return $pipe;
}

sub exec_command (\$$$$$$) {
    my $self = shift;
    my $options = shift;

    $options->{'INTCOMMAND'} = copy($options->{'COMMAND'});
    $self->get_command_internal($options);

    $self->log_command($options);

    my $dir = $options->{'CHDIR'};
    my $command = $options->{'EXPCOMMAND'};

    # Set environment.
    local (%ENV);

    my $chrootenv = $self->get('Environment');
    foreach (keys %$chrootenv) {
	$ENV->{$_} = $chrootenv->{$_};
    }

    my $commandenv = $options->{'ENV'};
    foreach (keys %$commandenv) {
	$ENV->{$_} = $commandenv->{$_};
    }

    if (defined($dir) && $dir) {
	debug("Changing to directory: $dir\n");
	chdir($dir) or die "Can't change directory to $dir: $!";
    }

    debug("Running command: ", join(" ", @$command), "\n");
    exec @$command;
    die "Failed to exec: $command->[0]: $!";
}

sub get_apt_command_internal (\$$$) {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'COMMAND'};
    my $apt_options = $self->get('APT Options');

    my @aptcommand = ();
    if (defined($apt_options)) {
	push(@aptcommand, $command->[0]);
	push(@aptcommand, @$apt_options);
	if ($#$command > 0) {
	    push(@aptcommand, @{$command}[1 .. $#$command]);
	}
    } else {
	@aptcommand = @$command;
    }

    $options->{'INTCOMMAND'} = \@aptcommand;
}

sub get_apt_command (\$$$$$$) {
    my $self = shift;
    my $options = shift;

    $options->{'CHROOT'} = $self->apt_chroot();

    $self->get_apt_command_internal($options);

    $self->get_command_internal($options);

    $self->log_command($options);

    return $options;
}

sub run_apt_command (\$$$$$$) {
    my $self = shift;
    my $options = shift;

# Set modfied command
    $self->get_apt_command_internal($options);

    $options->{'CHROOT'} = $self->apt_chroot();

    return $self->run_command($options);
}

sub pipe_apt_command (\$$$$$$) {
    my $self = shift;
    my $options = shift;

# Set modfied command
    my $aptcommand = $self->get_apt_command_internal($options);

    $options->{'CHROOT'} = $self->apt_chroot();

    return $self->pipe_command($options);
}

sub apt_chroot (\$) {
    my $self = shift;

    my $chroot =  $self->get('Split') ? 0 : 1;

    return $chroot
}

1;
