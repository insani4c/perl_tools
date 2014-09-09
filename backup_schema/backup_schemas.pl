#!/usr/bin/env perl 
# $Id$
use strict;
use warnings;
use utf8;

use Getopt::Long;
use DateTime;
use Pod::Usage;
use YAML qw/LoadFile/;
use File::Path qw/make_path/;
use File::Copy;
use Data::Dumper;
use POSIX qw/setuid/;
use File::Basename;


my ($help, $cfg_file, $schema, $verbose, $debug) = @_;
# Check command line arguments
GetOptions(
    "help"     => \$help,
    "verbose"  => \$verbose,
    "debug"    => \$debug,
    "cfg=s"    => \$cfg_file,
    "schema=s" => \$schema,
);
pod2usage(1) if $help;

# What's the time, Watson?
my $today = DateTime->now();

# check if we're postgres user, otherwise do something like
# 'su - postgres' in Perl
my ($user) = ( split /\c/, getpwuid( $< ) )[0];
unless ($user eq 'postgres') {
    p_info("Script $0 needs to run as 'postgres', switching user...");
    setuid(scalar getpwnam 'postgres');
}

# default config file
$cfg_file //= '/etc/perl_tools/backup_schemas.yaml';
my $cfg ;
# check if config file exists and then load it
# otherwise die
if(defined $cfg_file){
    if( -f $cfg_file ){
        p_info("Loading configuration file '$cfg_file'");
        $cfg = LoadFile($cfg_file);
    }
    else {
        die "No such configuration file '$cfg_file'\n";
    }
}

# if a schema name was specified on the command line,
# only backup that one
$cfg->{schemas} = [$schema] if defined $schema;

# backup defined schemas
foreach my $s (@{ $cfg->{schemas} }){
    check_current_backups($s);
    create_backup($s);
}

#
# End of main program
#

# subroutine to check if
# - required directory structure is present (otherwise create)
# - check if there are backup files that need to be rotated
sub check_current_backups {
    my($schema) = @_;

    check_directory_structure($schema);
    check_backups('daily', $schema);
    check_backups('weekly', $schema);
}

sub check_directory_structure {
    my($schema) = @_;

    foreach my $period (qw/daily weekly/){
        my $_path = return_backup_path($period, $schema);;
        p_info("Checking path '$_path'");
        unless(-d $_path){
            make_path($_path);
            p_info("Created path '$_path'");
        }
    }
}

# check if older backups need rotation / deletion
sub check_backups {
    my($period, $schema) = @_;

    my $path = return_backup_path($period, $schema);

    my @files = glob("$path/*");
    my @sorted = sort { get_date($b) <=> get_date($a) } @files;

    if(scalar @sorted >= $cfg->{thresholds}{$period}){
        p_info("Rotating backups for period '$period'");
        rotate_backups($period, $schema, \@sorted);
    }
}

# subroutine used for sorting
sub get_date {
   my($file) = @_; 
   my ($date) = ($file =~ /(\d{14})_/);
   return $date;
}

# I got bored writing the full path over and over again
sub return_backup_path {
    my ($period, $schema) = @_;
    return $cfg->{backup_path} . '/' . $period . '/' . $schema;
}

# daily backups are rotated if the exceed a configured threshold
#
sub rotate_backups {
    my($period, $schema, $files) = @_;

    p_debug("All Files: ".Dumper($files));
    p_debug("$period threshold: ".$cfg->{thresholds}{$period});

    # make a true copy
    my (@to_move_files) = (@{ $files });
    # The @files contains all backup files, with the youngest as element 0, the oldest 
    # backup as last element.
    # @to_move_files is a slice of @files, starting from the position threshold - 1, 
    # until the end of the array. Those files will be either rotated or removed
    @to_move_files = @to_move_files[ $cfg->{thresholds}{$period} -1 .. $#to_move_files ];
    p_debug("TO MOVE FILES: ".Dumper(\@to_move_files));

    if($period eq 'daily'){
        foreach my $file (@to_move_files){
            # move backups to weekly
            if($file =~ /$cfg->{daily_to_weekly_pattern}/){
                my $weekly = return_backup_path('weekly', $schema) . '/';
                p_info("Moving daily backup '$file' to $weekly");
                move($file, $weekly) or warn "Could not move '$file' to '$weekly': $!\n";
            }
            else {
                p_info("Removing backup '$file'");
                unlink($file);
            }
        }
    }

    if($period eq 'weekly'){
        foreach my $file (@to_move_files){
            # remove files
            p_info("Removing backup '$file'");
            unlink($file);
        }
    }
}

# the actual backup
# - pg_dump -n <schema_name> is used to produce a default sql formatted file,
# which will be gzip'ed afterwards
sub create_backup {
    my($schema) =@_;

    p_info("Creating backup for schema '$schema', database:" . $cfg->{database});
    my $now = DateTime->now;
    my $path = return_backup_path('daily', $schema) 
                . '/' . $now->ymd('') . $now->hms('')
                . '_' .lc($now->day_name) 
                . '.dump.sql';

    # Create the dump file
    my $dump_output = do{
        local $/;
        open my $c, '-|', "pg_dump -v -n $schema -f $path $cfg->{database} 2>&1" 
            or die "pg_dump for '$schema' failed: $!";
        <$c>;
    };
    p_debug('pg_dump output: ', $dump_output);

    # GZIP the dump file
    my $gzip_output = do{
        local $/;
        open my $c, '-|', "gzip $path 2>&1" 
            or die "gzip for '$path' failed: $!";
        <$c>;
    };
    p_debug('gzip output: ', $gzip_output);

    # change the permissions
    chmod 0660, "$path.gz";

    p_info("Created backup for schema '$schema' in '$path.gz'");
}

#
# The following two subroutines are just there for output
#
sub p_info {
    return unless defined $verbose;
    foreach my $line (@_) {
        my $now = DateTime->now();
        print $now->ymd('-') 
              . ' ' . $now->hms(':') 
              . ' > ' . $line . "\n";
    }
}

sub p_debug {
    return unless defined $debug;
    foreach my $line (@_) {
        my $now = DateTime->now();
        print $now->ymd('-') 
              . ' ' . $now->hms(':') 
              . ' [DEBUG] ' . $line . "\n";
    }
}

__END__

=head1 NAME

backup_schemas.pl - Create and rotate backups of PostgreSQL schemas

=head1 SYNOPSIS

backup_schemas.pl [options]

 Options
  --verbose        Print verbose messages
  --debug          Print debugging messages
  --help           Print documentation
  --schema         Override the schemas defined in the configuration file
  --cfg            Path to configuration file

=head1 OPTIONS

=over 8

=item B<--verbose>

Print verbose messages. By default, the script doesn't print any messages at all.
So turn on this option if you want to see what is going on.

=item B<-debug->

Print debugging messages, the script will create a lot more output (including a list 
of all backup files, thresholds, list of to delete or rotate backup files, ...

=item B<--help>

Print the documentation

=item B<--schema>

Schemas are configuration in the configuration file. However, this option allows to 
override the configured schemas and backup only the one which was specified at the 
command line.

=item B<--cfg>

The default configuration should be located at /etc/perl_tools/backup_schemas.yaml. This script
needs a configuration file in order to run.
This option allows to override the default configuration file path.

=back

=head1 DESCRIPTION

This script creates gzip'ed backups of configured schemas. It is designed to create daily backups
and will rotate one daily backup to a weekly backup, based on a pattern. This pattern is configured
in the configuration file under the parameter B<daily_to_weekly_pattern>.
Since all backup files contain the day name, the B<daily_to_weekly_pattern> should be set to the day on
which a daily backup should be moved into the weekly folder.

=cut
