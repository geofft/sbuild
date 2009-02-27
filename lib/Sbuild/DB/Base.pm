#
# Base.pm: Base class for database abstraction
# Copyright © 1998      Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::DB::Base;

use strict;
use warnings;

use Sbuild qw(debug isin);
use Sbuild::Base;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub dump {
    my $self = shift;
    my $file = shift;

    my $db = $self->get('DB');

    my($name,$pkg,$key);

    print "Writing ASCII database to $file..." if $self->get_conf('VERBOSE') >= 1;
    CORE::open( F, ">$file" ) or
	die "Can't open database $file: $!\n";

    foreach $name ($self->list_packages()) {
	my $pkg = $self->get_package($name);
	foreach $key (keys %{$pkg}) {
	    my $val = $pkg->{$key};
	    chomp( $val );
	    $val =~ s/\n/\n /g;
	    print F "$key: $val\n";
	}
	print F "\n";
    }

    foreach my $user ($self->list_users()) {
	my $ui = $self->get_user($user);
	print F "User: $user\n"
	    if (!defined($ui->{'User'}));
	foreach $key (keys %{$ui}) {
	    my $val = $ui->{$key};
	    chomp($val);
	    $val =~ s/\n/\n /g;
	    print F "$key: $val\n";
	}
	print F "\n";
    }

    CORE::close(F);
    print "done\n" if $self->get_conf('VERBOSE') >= 1;
}

sub restore {
    my $self = shift;
    my $file = shift;

    my $db = $self->get('DB');

    print "Reading ASCII database from $file..." if $self->get_conf('VERBOSE') >= 1;
    CORE::open( F, "<$file" ) or
	die "Can't open database $file: $!\n";

    local($/) = ""; # read in paragraph mode
    while( <F> ) {
	my( %thispkg, $name );
	s/[\s\n]+$//;
	s/\n[ \t]+/\376\377/g;  # fix continuation lines
	s/\376\377\s*\376\377/\376\377/og;

	while( /^(\S+):[ \t]*(.*)[ \t]*$/mg ) {
	    my ($key, $val) = ($1, $2);
	    $val =~ s/\376\377/\n/g;
	    $thispkg{$key} = $val;
	}
	$self->check_entry( \%thispkg );
	# add to db
	if (exists($thispkg{'Package'})) {
	    $self->set_package(\%thispkg);
	} elsif(exists($thispkg{'User'})) {
	    $self->set_user(\%thispkg);
	}
    }
    CORE::close( F );
    print "done\n" if $self->get_conf('VERBOSE') >= 1;
}

sub check_entry {
    my $self = shift;
    my $pkg = shift;
    my $field;

    # TODO: Why should manual editing disable sanity checking?
    return if $self->get_conf('DB_OPERATION') eq "manual-edit"; # no checks then

    # check for required fields
    if (!exists $pkg->{'Package'} && !exists $pkg->{'User'}) {
	print STDERR "Bad entry: ",
	join( "\n", map { "$_: $pkg->{$_}" } keys %$pkg ), "\n";
	die "Database entry lacks Package or User: field\n";
    }

    if (exists $pkg->{'Package'}) {
	if (!exists $pkg->{'Version'}) {
	    die "Database entry for package $pkg->{'Package'} lacks Version: field\n";
	}
	# if no State: field, generate one (for old db compat)
	if (!exists($pkg->{'State'})) {
	    $pkg->{'State'} =
		exists $pkg->{'Failed'} ? 'Failed' : 'Building';
	}
	# check state field
	die "Bad state $pkg->{'State'} of package $pkg->{Package}\n"
	    if !isin($pkg->{'State'},
		     qw(Needs-Build Building Built Build-Attempted
			Uploaded Installed Dep-Wait Failed
			Failed-Removed Not-For-Us) );
    }
    if (exists $pkg->{'User'}) {
	if (!exists $pkg->{'Last-Seen'}) {
	    die "Database entry for user $pkg->{'User'} lacks Last-Seen: field\n";
	}
    }
}

1;
