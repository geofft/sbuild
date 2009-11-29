# BuildDepSatisfier.pm: build library for sbuild
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

package Sbuild::BuildDepSatisfierBase;

use strict;
use warnings;
use Errno qw(:POSIX);

use Sbuild::Base;
use Sbuild qw(isin debug);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $builder = shift;

    my $self = $class->SUPER::new($builder->get('Config'));
    bless($self, $class);

    $self->set('Builder', $builder);
    $self->set('Log Stream', $builder->get('Config')->get('Log Stream'));
    $self->set('Changes', {});

    return $self;
}

sub uninstall_deps {
    my $self = shift;
    my $builder = $self->get('Builder');

    my( @pkgs, @instd, @rmvd );

    $builder->lock_file($builder->get('Session')->get('Install Lock'), 1);

    @pkgs = keys %{$self->get('Changes')->{'removed'}};
    debug("Reinstalling removed packages: @pkgs\n");
    $self->log("Failed to reinstall removed packages!\n")
	if !$builder->run_apt("-y", \@instd, \@rmvd, @pkgs);
    debug("Installed were: @instd\n");
    debug("Removed were: @rmvd\n");
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->get('Changes')->{'installed'}};
    debug("Removing installed packages: @pkgs\n");
    $self->log("Failed to remove installed packages!\n")
	if !$self->uninstall_debs("purge", @pkgs);
    $self->unset_installed(@pkgs);

    $builder->unlock_file($builder->get('Session')->get('Install Lock'));
}

sub check_srcdep_conflicts {
    my $self = shift;
    my $to_inst = shift;
    my $to_remove = shift;
    my $builder = $self->get('Builder');
    local( *F, *DIR );
    my $mypid = $$;
    my %conflict_builds;

    if (!opendir( DIR, $builder->get('Session')->{'Srcdep Lock Dir'} )) {
	$self->log("Cannot opendir $builder->{'Session'}->{'Srcdep Lock Dir'}: $!\n");
	return 1;
    }
    my @files = grep { !/^\.\.?$/ && !/^install\.lock/ && !/^$mypid-\d+$/ }
    readdir(DIR);
    closedir(DIR);

    my $file;
    foreach $file (@files) {
	if (!open( F, "<$builder->{'Session'}->{'Srcdep Lock Dir'}/$file" )) {
	    $self->log("Cannot open $builder->{'Session'}->{'Srcdep Lock Dir'}/$file: $!\n");
	    next;
	}
	<F> =~ /^(\S+)\s+(\S+)\s+(\S+)/;
	my ($job, $pid, $user) = ($1, $2, $3);

	# ignore (and remove) a lock file if associated process
	# doesn't exist anymore
	if (kill( 0, $pid ) == 0 && $! == ESRCH) {
	    close( F );
	    $self->log("Found stale srcdep lock file $file -- removing it\n");
	    $self->log("Cannot remove: $!\n")
		if !unlink( "$builder->{'Session'}->{'Srcdep Lock Dir'}/$file" );
	    next;
	}

	debug("Reading srclock file $file by job $job user $user\n");

	while( <F> ) {
	    my ($neg, $pkg) = /^(!?)(\S+)/;
	    debug("Found ", ($neg ? "neg " : ""), "entry $pkg\n");

	    if (isin( $pkg, @$to_inst, @$to_remove )) {
		$self->log("Source dependency conflict with build of " .
		           "$job by $user (pid $pid):\n");
		$self->log("  $job " . ($neg ? "conflicts with" : "needs") .
		           " $pkg\n");
		$self->log("  " . $builder->get('Package_SVersion') .
			   " wants to " .
		           (isin( $pkg, @$to_inst ) ? "update" : "remove") .
		           " $pkg\n");
		$conflict_builds{$file} = 1;
	    }
	}
	close( F );
    }

    my @conflict_builds = keys %conflict_builds;
    if (@conflict_builds) {
	debug("Srcdep conflicts with: @conflict_builds\n");
    }
    else {
	debug("No srcdep conflicts\n");
    }
    return @conflict_builds;
}

sub wait_for_srcdep_conflicts {
    my $self = shift;
    my $builder = $self->get('Builder');
    my @confl = @_;

    for(;;) {
	sleep($self->get_conf('SRCDEP_LOCK_WAIT') * 60);
	my $allgone = 1;
	for (@confl) {
	    /^(\d+)-(\d+)$/;
	    my $pid = $1;
	    if (-f "$builder->{'Session'}->{'Srcdep Lock Dir'}/$_") {
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    $self->log("Ignoring stale src-dep lock $_\n");
		    unlink( "$builder->{'Session'}->{'Srcdep Lock Dir'}/$_" ) or
			$self->log("Cannot remove $builder->{'Session'}->{'Srcdep Lock Dir'}/$_: $!\n");
		}
		else {
		    $allgone = 0;
		    last;
		}
	    }
	}
	last if $allgone;
    }
}

sub write_srcdep_lock_file {
    my $self = shift;
    my $deps = shift;
    my $builder = $self->get('Builder');
    local( *F );

    ++$builder->{'Srcdep Lock Count'};
    my $f = "$builder->{'Session'}->{'Srcdep Lock Dir'}/$$-$builder->{'Srcdep Lock Count'}";
    if (!open( F, ">$f" )) {
	$self->log_warning("cannot create srcdep lock file $f: $!\n");
	return;
    }
    debug("Writing srcdep lock file $f:\n");

    my $user = getpwuid($<);
    print F $builder->get('Package_SVersion') . " $$ $user\n";
    debug("Job " . $builder->get('Package_SVersion') . " pid $$ user $user\n");
    foreach (@$deps) {
	my $name = $_->{'Package'};
	print F ($_->{'Neg'} ? "!" : ""), "$name\n";
	debug("  ", ($_->{'Neg'} ? "!" : ""), "$name\n");
    }
    close( F );
}

sub remove_srcdep_lock_file {
    my $self = shift;
    my $builder = $self->get('Builder');

    my $f = $builder->{'Session'}->{'Srcdep Lock Dir'} . '/' . $$ . '-' . $builder->{'Srcdep Lock Count'};

    debug("Removing srcdep lock file $f\n");
    if (!unlink( $f )) {
	$self->log_warning("cannot remove srcdep lock file $f: $!\n")
	    if $! != ENOENT;
    }
}

sub set_installed {
    my $self = shift;

    foreach (@_) {
	$self->get('Changes')->{'installed'}->{$_} = 1;
    }
    debug("Added to installed list: @_\n");
}

sub set_removed {
    my $self = shift;
    foreach (@_) {
	$self->get('Changes')->{'removed'}->{$_} = 1;
	if (exists $self->get('Changes')->{'installed'}->{$_}) {
	    delete $self->get('Changes')->{'installed'}->{$_};
	    $self->get('Changes')->{'auto-removed'}->{$_} = 1;
	    debug("Note: $_ was installed\n");
	}
    }
    debug("Added to removed list: @_\n");
}

sub unset_installed {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'installed'}->{$_};
    }
    debug("Removed from installed list: @_\n");
}

sub unset_removed {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'removed'}->{$_};
	if (exists $self->get('Changes')->{'auto-removed'}->{$_}) {
	    delete $self->get('Changes')->{'auto-removed'}->{$_};
	    $self->get('Changes')->{'installed'}->{$_} = 1;
	    debug("Note: revived $_ to installed list\n");
	}
    }
    debug("Removed from removed list: @_\n");
}

sub uninstall_debs {
    my $self = shift;
    my $mode = shift;
    my $builder = $self->get('Builder');
    my $status;

    return 1 if !@_;
    debug("Uninstalling packages: @_\n");

  repeat:
    my $output;
    my $remove_start_time = time;

    my $pipe = $builder->get('Session')->pipe_command(
	{ COMMAND => [$self->get_conf('DPKG'), '--force-depends', "--$mode", @_],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0,
	  DIR => '/' });

    if (!$pipe) {
	$self->log("Can't open pipe to dpkg: $!\n");
	return 0;
    }

    while (<$pipe>) {
	$output .= $_;
	$self->log($_);
    }
    close($pipe);
    $status = $?;

    if (defined($output) && $output =~ /status database area is locked/mi) {
	$self->log("Another dpkg is running -- retrying later\n");
	$output = "";
	sleep( 2*60 );
	goto repeat;
    }
    my $remove_end_time = time;
    $builder->write_stats('remove-time',
		       $remove_end_time - $remove_start_time);
    $self->log("dpkg run to remove packages (@_) failed!\n") if $?;
    return $status == 0;
}

1;
