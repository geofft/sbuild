# Resolver.pm: build library for sbuild
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

package Sbuild::ResolverBase;

use strict;
use warnings;
use POSIX;
use Fcntl;
use Errno qw(:POSIX);

use Dpkg::Deps;
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
    $self->set('Changes', {});
    $self->set('AptDependencies', {});

    return $self;
}

sub add_dependencies {
    my $self = shift;
    my $pkg = shift;
    my $build_depends = shift;
    my $build_depends_indep = shift;
    my $build_conflicts = shift;
    my $build_conflicts_indep = shift;

    my $builder = $self->get('Builder');

    debug("Build-Depends: $build_depends\n") if $build_depends;
    debug("Build-Depends-Indep: $build_depends_indep\n") if $build_depends_indep;
    debug("Build-Conflicts: $build_conflicts\n") if $build_conflicts;
    debug("Build-Conflicts-Indep: $build_conflicts_indep\n") if $build_conflicts_indep;

    my $deps = {
	'Build Depends' => $build_depends,
	'Build Depends Indep' => $build_depends_indep,
	'Build Conflicts' => $build_conflicts,
	'Build Conflicts Indep' => $build_conflicts_indep
    };

    $self->get('AptDependencies')->{$pkg} = $deps;
}

sub uninstall_deps {
    my $self = shift;
    my $builder = $self->get('Builder');

    my( @pkgs, @instd, @rmvd );

    @pkgs = keys %{$self->get('Changes')->{'removed'}};
    debug("Reinstalling removed packages: @pkgs\n");
    $builder->log("Failed to reinstall removed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'install', @pkgs);
    debug("Installed were: @instd\n");
    debug("Removed were: @rmvd\n");
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->get('Changes')->{'installed'}};
    debug("Removing installed packages: @pkgs\n");
    $builder->log("Failed to remove installed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'remove', @pkgs);
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);
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

sub dump_build_environment {
    my $self = shift;
    my $builder = $self->get('Builder');

    my $status = $self->get_dpkg_status();

    my $arch = $builder->get('Arch');
    my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
    $builder->log("Kernel: $sysname $release $arch ($machine)\n");

    $builder->log("Toolchain package versions:");
    foreach my $name (sort keys %{$status}) {
        foreach my $regex (@{$self->get_conf('TOOLCHAIN_REGEX')}) {
	    if ($name =~ m,^$regex, && defined($status->{$name}->{'Version'})) {
		$builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    }
	}
    }
    $builder->log("\n");

    $builder->log("Package versions:");
    foreach my $name (sort keys %{$status}) {
	if (defined($status->{$name}->{'Version'})) {
	    $builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	}
    }
    $builder->log("\n");

}

sub run_apt {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my $action = shift;
    my @packages = @_;
    my( $msgs, $status, $pkgs, $rpkgs );

    my $builder = $self->get('Builder');

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my $pipe =
	$builder->get('Session')->pipe_apt_command(
	{ COMMAND => [$builder->get_conf('APT_GET'), '--purge',
		      '-o', 'DPkg::Options::=--force-confold',
		      '-q', "$mode", $action, @packages],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  PRIORITY => 0,
	  DIR => '/' });
    if (!$pipe) {
	$builder->log("Can't open pipe to apt-get: $!\n");
	return 0;
    }

    while(<$pipe>) {
	$msgs .= $_;
	$builder->log($_) if $mode ne "-s" || debug($_);
    }
    close($pipe);
    $status = $?;

    $pkgs = $rpkgs = "";
    if ($msgs =~ /NEW packages will be installed:\n((^[ 	].*\n)*)/mi) {
	($pkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$pkgs =~ s/\*//g;
    }
    if ($msgs =~ /packages will be REMOVED:\n((^[ 	].*\n)*)/mi) {
	($rpkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$rpkgs =~ s/\*//g;
    }
    @$inst_ret = split( /\s+/, $pkgs );
    @$rem_ret = split( /\s+/, $rpkgs );

    $builder->log("apt-get failed.\n") if $status && $mode ne "-s";
    return $mode eq "-s" || $status == 0;
}

sub format_deps {
    my $self = shift;

    return join( ", ",
		 map { join( "|",
			     map { ($_->{'Neg'} ? "!" : "") .
				       $_->{'Package'} .
				       ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"")}
			     scalar($_), @{$_->{'Alternatives'}}) } @_ );
}

sub get_dpkg_status {
    my $self = shift;
    my $builder = $self->get('Builder');
    my @interest = @_;
    my %result;
    local( *STATUS );

    debug("Requesting dpkg status for packages: @interest\n");
    my $dpkg_status_file = $builder->{'Chroot Dir'} . '/var/lib/dpkg/status';
    if (!open( STATUS, '<', $dpkg_status_file)) {
	$builder->log("Can't open $dpkg_status_file: $!\n");
	return ();
    }
    local( $/ ) = "";
    while( <STATUS> ) {
	my( $pkg, $status, $version, $provides );
	/^Package:\s*(.*)\s*$/mi and $pkg = $1;
	/^Status:\s*(.*)\s*$/mi and $status = $1;
	/^Version:\s*(.*)\s*$/mi and $version = $1;
	/^Provides:\s*(.*)\s*$/mi and $provides = $1;
	if (!$pkg) {
	    $builder->log_error("parse error in $dpkg_status_file: no Package: field\n");
	    next;
	}
	if (defined($version)) {
	    debug("$pkg ($version) status: $status\n") if $self->get_conf('DEBUG') >= 2;
	} else {
	    debug("$pkg status: $status\n") if $self->get_conf('DEBUG') >= 2;
	}
	if (!$status) {
	    $builder->log_error("parse error in $dpkg_status_file: no Status: field for package $pkg\n");
	    next;
	}
	if ($status !~ /\sinstalled$/) {
	    $result{$pkg}->{'Installed'} = 0
		if !(exists($result{$pkg}) &&
		     $result{$pkg}->{'Version'} eq '~*=PROVIDED=*=');
	    next;
	}
	if (!defined $version || $version eq "") {
	    $builder->log_error("parse error in $dpkg_status_file: no Version: field for package $pkg\n");
	    next;
	}
	$result{$pkg} = { Installed => 1, Version => $version }
	    if (isin( $pkg, @interest ) || !@interest);
	if ($provides) {
	    foreach (split( /\s*,\s*/, $provides )) {
		$result{$_} = { Installed => 1, Version => '~*=PROVIDED=*=' }
		if isin( $_, @interest ) and (not exists($result{$_}) or
					      ($result{$_}->{'Installed'} == 0));
	    }
	}
    }
    close( STATUS );
    return \%result;
}

1;
