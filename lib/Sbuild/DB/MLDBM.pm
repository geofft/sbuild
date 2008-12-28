#
# DB.pm: MLDBM Database abstraction
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

package Sbuild::DB;

use strict;
use warnings;

use POSIX;
use GDBM_File;
use MLDBM qw(GDBM_File Storable);

use Sbuild qw(debug isin);
use Sbuild::Base;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);


    return $self;
}

sub open {
    my $self = shift;
    my $file = shift;

    my %db;

    tie %db, 'MLDBM', $file, GDBM_WRCREAT, 0664
	or die "FATAL: Cannot open database\n";

    $self->set('FILE', $file);
    $self->set('DB', \%db);
    $self->set('KEEP_LOCK', 0);
}

sub close {
    my $self = shift;

    my $db = $self->get('DB');
    untie %{$db} or die "FATAL: Cannot untie old database\n";
    $db = undef;

    $self->set('KEEP_LOCK', 0);
    $self->set('DB', undef);

    $self->unlock(); # After db is undefined
    $self->set('FILE', undef);
}

# TODO: Use fcntl locks?
sub lock  {
    my $self = shift;

    my $file = $self->get('FILE');

    my $try = 0;
    my $lockfile = "${file}.lock";
    local( *F );

    print "Locking $file database\n" if $self->get_conf('VERBOSE') >= 2;
  repeat:
    if (!sysopen( F, $lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if ($! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !CORE::open( F, "<$lockfile" );
	    my $line = <F>;
	    CORE::close(F);
	    if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
		warn "Bad lock file contents -- still trying\n";
	    }
	    else {
		my($pid, $usr) = ($1, $2);
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    # process doesn't exist anymore, remove stale lock
		    print "Removing stale lock file (pid $pid, user $usr)\n";
		    unlink( $lockfile );
		    goto repeat;
		}
		warn "Database locked by $usr -- please wait\n" if $try == 0;
	    }
	    if (++$try > 200) {
		# avoid the END routine removes the lock
		$self->set('KEEP_LOCK', 1);
		die "Lock still present after 200 * 5 seconds.\n";
	    }
	    sleep 5;
	    goto repeat;
	}
	die "Can't create lock file $lockfile: $!\n";
    }
    F->print("$$ " . $self->get_conf('USERNAME') . "\n");
    F->close();
}

sub unlock ($) {
    my $self = shift;

    my $file = $self->get('FILE');
    my $lockfile = "${file}.lock";

    if (!$self->get('KEEP_LOCK')) {
	print "Unlocking $file database\n" if $self->get_conf('VERBOSE') >= 2;
	unlink $lockfile;
    }
}

sub clear {
    my $self = shift;

    my $db = $self->get('DB');

    %{$db} = ();
}

sub list_packages {
    my $self = shift;

    my $db = $self->get('DB');

    my @packages;

    foreach my $name (sort keys %{$db}) {
	next if $name =~ /^_/;
	push(@packages, $name);
    }

    return @packages;
}

sub get_package {
    my $self = shift;
    my $pkg = shift;

    my $pkgobj = undef;

    if ($pkg !~ /^_/) {
	my $db = $self->get('DB');
	$pkgobj = $db->{$pkg};
    }

    return $pkgobj;
}

sub set_package {
    my $self = shift;
    my $pkg = shift;

    if ($pkg !~ /^_/) {
	my $db = $self->get('DB');

	my $name = $pkg->{'Package'};
	$db->{$name} = $pkg;
    } else {
	$pkg = undef;
    }

    return $pkg;
}

sub del_package {
    my $self = shift;
    my $pkg = shift;

    my $name = $pkg;
    $name = $pkg->{'Package'} if (ref($pkg) eq 'HASH');

    my $success = 0;

    if ($pkg !~ /^_/) {
	my $db = $self->get('DB');

	delete $db->{$name};

	$success = 1;
    }

    return $success;
}

sub list_users {
    my $self = shift;

    my $db = $self->get('DB');
    my $usertable = $db->{'_userinfo'};

    my @users = ();

    if (defined($usertable)) {
	foreach my $name (sort keys %{$usertable}) {
	    push(@users, $name);
	}
    }

    return @users;
}

sub get_user {
    my $self = shift;
    my $user = shift;

    my $db = $self->get('DB');
    my $usertable = $db->{'_userinfo'};

    my $userobj = undef;

    if (defined($usertable)) {
	$userobj = $usertable->{$user};
	$userobj->{'User'} = $user if !defined($userobj->{'User'});
    }

    return $userobj;
}

sub set_user {
    my $self = shift;
    my $user = shift;

    my $db = $self->get('DB');
    my $usertable = $db->{'_userinfo'};
    $usertable = {} if !defined($usertable);

    my $name = $user->{'User'};
    $usertable->{$name} = $user;

    $db->{'_userinfo'} = $usertable;

    return $user;
}

sub del_user {
    my $self = shift;
    my $user = shift;

    my $name = $user;
    $name = $user->{'User'} if (ref($user) eq 'HASH');

    my $db = $self->get('DB');
    my $usertable = $db->{'_userinfo'};
    $usertable = {} if !defined($usertable);

    my $success = 0;

    if (exists($usertable->{$name})) {
	delete $usertable->{$name};
	$db->{'_userinfo'} = $usertable;
	$success = 1;
    }

    return $success
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

sub clean {
    my $self = shift;

    my $db = $self->get('DB');
    my $file = $self->get('FILE');

    my %new_db;
    tie %new_db, 'MLDBM', "$file.new", GDBM_WRCREAT, 0664
	or die "FATAL: Cannot create new database\n";
    %new_db = %{$db};

    $self->close();
    $db = undef;

    system ("cp ${file}.new ${file}") == 0
	or die "FATAL: Cannot overwrite old database";
    unlink "${file}.new";

    $self->set('FILE', $file);
    $self->set('DB', \%new_db);
}

1;
