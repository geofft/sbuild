#
# Utility.pm: library for sbuild utility programs
# Copyright © 2006 Roger Leigh <rleigh@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
#
############################################################################

# Import default modules into main
package main;
use Sbuild qw($devnull);
use Sbuild::Conf;
use Sbuild::ChrootInfoSchroot;
use Sbuild::ChrootInfoSudo;
use Sbuild::Sysconfig;

$ENV{'LC_ALL'} = "POSIX";
$ENV{'SHELL'} = $Sbuild::Sysconfig::programs{'SHELL'};

# avoid intermixing of stdout and stderr
$| = 1;

package Sbuild::Utility;

use strict;
use warnings;

use Sbuild::Conf;
use Sbuild::Chroot;
use File::Temp qw(tempfile);
use Module::Load::Conditional qw(can_load); # Used to check for LWP::UserAgent
use Time::HiRes qw ( time ); # Needed for high resolution timers

sub get_dist ($);
sub setup ($$);
sub cleanup ($);
sub shutdown ($);
sub parse_file ($);
sub dsc_files ($);

my $current_session;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(setup cleanup shutdown check_url download parse_file dsc_files);

    $SIG{'INT'} = \&shutdown;
    $SIG{'TERM'} = \&shutdown;
    $SIG{'ALRM'} = \&shutdown;
    $SIG{'PIPE'} = \&shutdown;
}

sub get_dist ($) {
    my $dist = shift;

    $dist = "unstable" if ($dist eq "-u" || $dist eq "u");
    $dist = "testing" if ($dist eq "-t" || $dist eq "t");
    $dist = "stable" if ($dist eq "-s" || $dist eq "s");
    $dist = "oldstable" if ($dist eq "-o" || $dist eq "o");
    $dist = "experimental" if ($dist eq "-e" || $dist eq "e");

    return $dist;
}

sub setup ($$) {
    my $chroot = shift;
    my $conf = shift;


    $conf->set('VERBOSE', 1);
    $conf->set('NOLOG', 1);

    $chroot = get_dist($chroot);

    # TODO: Allow user to specify arch.
    my $chroot_info;
    if ($conf->get('CHROOT_MODE') eq 'schroot') {
	$chroot_info = Sbuild::ChrootInfoSchroot->new($conf);
    } else {
	$chroot_info = Sbuild::ChrootInfoSudo->new($conf);
    }

    my $session;

    $session = $chroot_info->create($chroot,
				    undef, # TODO: Add --chroot option
				    $conf->get('ARCH'));

    $session->set('Log Stream', \*STDOUT);

    my $chroot_defaults = $session->get('Defaults');
    $chroot_defaults->{'DIR'} = '/';
    $chroot_defaults->{'STREAMIN'} = $Sbuild::devnull;
    $chroot_defaults->{'STREAMOUT'} = \*STDOUT;
    $chroot_defaults->{'STREAMERR'} =\*STDOUT;

    $Sbuild::Utility::current_session = $session;

    if (!$session->begin_session()) {
	print STDERR "Error setting up $chroot chroot\n";
	return undef;
    }

    if (defined(&main::local_setup)) {
	return main::local_setup($session);
    }
    return $session;
}

sub cleanup ($) {
    my $conf = shift;

    if (defined(&main::local_cleanup)) {
	main::local_cleanup($Sbuild::Utility::current_session);
    }
    $Sbuild::Utility::current_session->end_session();
}

sub shutdown ($) {
    cleanup($main::conf); # FIXME: don't use global
    exit 1;
}

# This method simply checks if a URL is valid.
sub check_url {
    my ($url) = @_;

    # If $url is a readable plain file on the local system, just return true.
    return 1 if (-f $url && -r $url);

    # Load LWP::UserAgent if possible, else return 0.
    if (! can_load( modules => { 'LWP::UserAgent' => undef, } )) {
	return 0;
    }

    # Setup the user agent.
    my $ua = LWP::UserAgent->new;

    # Determine if we need to specify any proxy settings.
    $ua->env_proxy;
    my $proxy = _get_proxy();
    if ($proxy) {
        $ua->proxy(['http', 'ftp'], $proxy);
    }

    # Dispatch a HEAD request, grab the response, and check the response for
    # success.
    my $res = $ua->head($url);
    return 1 if ($res->is_success);

    # URL wasn't valid.
    return 0;
}

# This method is used to retrieve a file, usually from a location on the
# Internet, but it can also be used for files in the local system.
# $url is location of file, $file is path to write $url into.
sub download {
    # The parameters will be any URL and a location to save the file to.
    my($url, $file) = @_;

    # Print output from this subroutine to saved stdout stream of sbuild.
    my $stdout = $Sbuild::LogBase::saved_stdout;

    # If $url is a readable plain file on the local system, just return the
    # $url.
    return $url if (-f $url && -r $url);

    # Load LWP::UserAgent if possible, else return 0.
    if (! can_load( modules => { 'LWP::UserAgent' => undef, } )) {
	return 0;
    }

    # Filehandle we'll be writing to.
    my $fh;

    # If $file isn't defined, a temporary file will be used instead.
    ($fh, $file) = tempfile( UNLINK => 0 ) if (! $file);

    # Setup the user agent.
    my $ua = LWP::UserAgent->new;

    # Determine if we need to specify any proxy settings.
    $ua->env_proxy;
    my $proxy = _get_proxy();
    if ($proxy) {
        $ua->proxy(['http', 'ftp'], $proxy);
    }

    # Download the file.
    print $stdout "Downloading $url to $file.\n";
    my $expected_length; # Total size we expect of content
    my $bytes_received = 0; # Size of content as it is received
    my $percent; # The percentage downloaded
    my $tick; # Used for counting.
    my $start_time = time; # Record of the start time
    open($fh, '>', $file); # Destination file to download content to
    my $request = HTTP::Request->new(GET => $url);
    my $response = $ua->request($request,
        sub {
	    # Our own content callback subroutine
            my ($chunk, $response) = @_;

            $bytes_received += length($chunk);
            unless (defined $expected_length) {
                $expected_length = $response->content_length or undef;
            }
            if ($expected_length) {
                # Here we calculate the speed of the download to print out later
                my $speed;
                my $duration = time - $start_time;
                if ($bytes_received/$duration >= 1024 * 1024) {
                    $speed = sprintf("%.4g MB",
                        ($bytes_received/$duration) / (1024.0 * 1024)) . "/s";
                } elsif ($bytes_received/$duration >= 1024) {
                    $speed = sprintf("%.4g KB",
                        ($bytes_received/$duration) / 1024.0) . "/s";
                } else {
                    $speed = sprintf("%.4g B",
			($bytes_received/$duration)) . "/s";
                }
                # Calculate the percentage downloaded
                $percent = sprintf("%d",
                    100 * $bytes_received / $expected_length);
                $tick++; # Keep count
                # Here we print out a progress of the download. We start by
                # printing out the amount of data retrieved so far, and then
                # show a progress bar. After 50 ticks, the percentage is printed
                # and the speed of the download is printed. A new line is
                # started and the process repeats until the download is
                # complete.
                if (($tick == 250) or ($percent == 100)) {
		    if ($tick == 1) {
			# In case we reach 100% from tick 1.
			printf $stdout "%8s", sprintf("%d",
			    $bytes_received / 1024) . "KB";
			print $stdout " [.";
		    }
		    while ($tick != 250) {
			# In case we reach 100% before reaching 250 ticks
			print $stdout "." if ($tick % 5 == 0);
			$tick++;
		    }
                    print $stdout ".]";
                    printf $stdout "%5s", "$percent%";
                    printf $stdout "%12s", "$speed\n";
                    $tick = 0;
                } elsif ($tick == 1) {
                    printf $stdout "%8s", sprintf("%d",
                        $bytes_received / 1024) . "KB";
                    print $stdout " [.";
                } elsif ($tick % 5 == 0) {
                    print $stdout ".";
                }
            }
            # Write the contents of the download to our specified file
            if ($response->is_success) {
                print $fh $chunk; # Print content to file
            } else {
                # Print message upon failure during download
                print $stdout "\n" . $response->status_line . "\n";
                return 0;
            }
	    $stdout->flush();
        }
    ); # End of our content callback subroutine
    close $fh; # Close the destination file

    # Print error message in case we couldn't get a response at all.
    if (!$response->is_success) {
        print $response->status_line . "\n";
        return 0;
    }

    # Print out amount of content received before returning the path of the
    # file.
    print $stdout "Download of $url sucessful.\n";
    print $stdout "Size of content downloaded: ";
    if ($bytes_received >= 1024 * 1024) {
	print $stdout sprintf("%.4g MB",
	    $bytes_received / (1024.0 * 1024)) . "\n";
    } elsif ($bytes_received >= 1024) {
	print $stdout sprintf("%.4g KB", $bytes_received / 1024.0) . "\n";
    } else {
	print $stdout sprintf("%.4g B", $bytes_received) . "\n";
    }

    return $file;
}

# This method is used to determine the proxy settings used on the local system.
# It will return the proxy URL if a proxy setting is found.
sub _get_proxy {
    my $proxy;

    # Attempt to acquire a proxy URL from apt-config.
    if (open(my $apt_config_output, '-|', '/usr/bin/apt-config dump')) {
        foreach my $tmp (<$apt_config_output>) {
            if ($tmp =~ m/^.*Acquire::http::Proxy\s+/) {
                $proxy = $tmp;
                chomp($proxy);
                # Trim the line to only the proxy URL
                $proxy =~ s/^.*Acquire::http::Proxy\s+"|";$//g;
                return $proxy;
            }
        }
        close $apt_config_output;
    }

    # Attempt to acquire a proxy URL from the user's or system's wgetrc
    # configuration.
    # First try the user's wgetrc
    if (open(my $wgetrc, '<', "$ENV{'HOME'}/.wgetrc")) {
        foreach my $tmp (<$wgetrc>) {
            if ($tmp =~ m/^[^#]*http_proxy/) {
                $proxy = $tmp;
                chomp($proxy);
                # Trim the line to only the proxy URL
                $proxy =~ s/^.*http_proxy\s*=\s*|\s+$//g;
                return $proxy;
            }
        }
        close($wgetrc);
    }
    # Now try the system's wgetrc
    if (open(my $wgetrc, '<', '/etc/wgetrc')) {
        foreach my $tmp (<$wgetrc>) {
            if ($tmp =~ m/^[^#]*http_proxy/) {
                $proxy = $tmp;
                chomp($proxy);
                # Trim the line to only the proxy URL
                $proxy =~ s/^.*http_proxy\s*=\s*|\s+$//g;
                return $proxy;
            }
        }
        close($wgetrc);
    }

    # At this point there should be no proxy settings. Return undefined.
    return 0;
}

# Method to parse a rfc822 type file, like Debian changes or control files.
# It can also be used on files like Packages or Sources files in a Debian
# archive.
# This subroutine returns an array of hashes. Each hash is a stanza.
sub parse_file ($) {
    # Takes one parameter, the file to parse.
    my ($file) = @_;

    # Variable we'll be returning from this subroutine.
    my @array_of_fields;

    # All our regex used in this method
    # Regex to split each field and it's contents
    my $split_pattern = qr{
        ^\b   # Match the beginning of a line followed by the word boundary
              # before a new field
        }msx;
    # Regex for detecting the beginning PGP block
    my $beginning_pgp_block = qr{
        ^\Q-----BEGIN PGP SIGNED MESSAGE-----\E
        .*?   # Any block starting with the text above followed by some other
              # text
        }msx;
    # Regex for detecting the ending PGP block
    my $ending_pgp_block = qr{
        ^\Q-----BEGIN PGP SIGNATURE-----\E
        .*   # Any block starting with the text above followed by some other
             # text
        }msx;

    # Enclose this in it's own block, since we change $/
    {
        # Attempt to open and read the file
        my $fh;
        open $fh, '<', $file or die "Could not read $file: $!";

        # Read paragraph by paragraph
        local $/ = "";
        while (<$fh>) {
            # Skip the beginning PGP block, stop at the ending PGP block
            next if ($_ =~ $beginning_pgp_block);
            last if ($_ =~ $ending_pgp_block);

            # Chomp the paragraph and split by each field
            chomp;
            my @matches = split /$split_pattern/, "$_\n";

            # Loop through the fields, placing them into a hash
            my %fields;
            foreach my $match (@matches) {
                my ($field, $field_contents);
                $field = $1 if ($match =~ /([^:]+?):/msx);
                $field_contents = $1 if ($match =~ /[^:]+?:(.*)/msx);
                $fields{$field} = $field_contents;
            }

            # Push each hash of fields as a ref onto our array
            push @array_of_fields, \%fields;
        }
        close $fh or die "Problem encountered closing file $file: $!";
    }

    # Return a reference to the array
    return \@array_of_fields;
}

sub dsc_files ($) {
    my $dsc = shift;

    my @files;

    # The parse_file() subroutine returns a ref to an array of hashrefs.
    my $stanzas = parse_file($dsc);

    # A dsc file would only ever contain one stanza, so we only deal with
    # the first entry which is a ref to a hash of fields for the stanza.
    my $stanza = @{$stanzas}[0];

    # We're only interested in the name of the files in the Files field.
    my $entry = ${$stanza}{'Files'};

    foreach my $line (split("\n", $entry)) {
	push @files, $1 if $line =~ /(\S+)\s*$/;
    }

    return @files;
}

1;
