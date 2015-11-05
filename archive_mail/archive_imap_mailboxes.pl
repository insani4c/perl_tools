#!/usr/bin/env perl 
#===============================================================================
#         FILE: archive_imap_mailboxes.pl
#        USAGE: ./archive_imap_mailboxes.pl  
# REQUIREMENTS: 
#       AUTHOR: Johnny Morano <insaniac@shihai-corp.at>, 
# ORGANIZATION: Shihai Corp.
#      CREATED: 11/03/2015 12:18:15 PM
#===============================================================================

use strict;
use warnings;
use utf8;

use Net::IMAP::Simple::SSL;
use Email::Simple;
use Getopt::Long qw/:config bundling/;
use DateTime;
use YAML qw/LoadFile/;
use Log::Log4perl;
use Pod::Usage;
use Data::Dumper;

Log::Log4perl::init_and_watch('./log4perl.conf');
my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

my %months = (
        Jan => 1,
        Feb => 2,
        Mar => 3,
        Apr => 4,
        May => 5,
        Jun => 6,
        Jul => 7,
        Aug => 8,
        Sep => 9,
        Oct => 10,
        Nov => 11,
        Dec => 12,
);

my($help, $man, $cfg_file);
GetOptions(
        "c|cfg=s"      => \$cfg_file,
        "h|help"       => \$help,
        "m|man"        => \$man,
) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-exitval => 0, -verbose => 2) if $man;

my $config = load_config($cfg_file);

# Define the dates based on the thresholds
my $archive_date = DateTime->now;
$archive_date->subtract(%{ $config->{threshold}{archive} });

my $delete_date = DateTime->now;
$delete_date->subtract(%{ $config->{threshold}{delete} });

# Connect to the IMAP server
my $imap = connect_imap( $config->{imap} );

# get all mailboxes and loop through them
my @mailboxes = get_mailboxes($imap);
foreach my $mailbox_name (@mailboxes){

    # Skip all Archive boxes 
    next if $mailbox_name =~ /Archive/;

    # select the mailbox and get the number of messages
    my $mb = $imap->select($mailbox_name);
    unless(defined $mb){
        $logger->error("Mailbox [$mailbox_name] doesn't exist: ", $imap->errstr());
        next;
    }

    $logger->info("Scanning $mailbox_name");

    # loop through the messages
    foreach my $i (1 .. $mb){
        my ($from, $subject, $date, $year) = get_mail_header($imap, $i);

        if(defined $date){
            if($date < $delete_date ){
                delete_mail($imap, $i);
            }
            elsif($date < $archive_date){
                $logger->info("Archiving [$i][$from][$subject][$date]");
                my $archive_box = get_archive_box($imap, $mailbox_name);
                move_mail($imap, $i, $archive_box)
            }
        }
    }

    $imap->expunge_mailbox($mailbox_name);
}

$imap->quit;

#
# Subroutines
#

sub get_mailboxes {
    my ($imap) = @_;
    my @mailboxes = $imap->mailboxes;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    return @mailboxes;
}

sub get_mail_header {
    my ($imap, $i) = @_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    my $header = $imap->top($i);
    unless( $header ){
        $logger->error("No header found for message $i in ", $imap->current_box);
    }
    
    my $email = Email::Simple->new(join '', @{ $header });
    unless( $email ){
        $logger->error("No Email::Simple object, skipping...");
        return
    }

    my ($subject) = $email->header('Subject');
    my ($date)    = $email->header('Date');
    my ($from)    = $email->header('From');

    # $logger->debug("Got e-mail [$from] [$subject] [$date]");

    unless(defined $date){
        $logger->error("No date found: ", $email->header_obj->as_string);
        delete_mail($imap, $i);
        return;
    }
    
    my($junk, $day, $month, $year) = ( $date =~ m/(...,\s+)?([0-9]{1,2})\s+(...)\s+(\d{4})/ );

    my $date_obj;
    if(defined $year && defined $month && defined $day){
        $date_obj = DateTime->new(
            year  => $year,
            month => $months{$month},
            day   => $day,
        );
    }    

    return ($from, $subject, $date_obj, $year, $month, $day);
}

sub get_archive_box{
    my($imap, $mailbox_name) = @_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    my ($archive_box) = ($mailbox_name);
    $archive_box =~ s/INBOX/INBOX.Archive/;

    if( not grep /^$archive_box$/, @mailboxes) {
        create_mailbox($imap, $archive_box);
        subscribe($imap, $archive_box);
    }

    return $archive_box;       
}

sub create_mailbox {
    my($imap, $mb) = @_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    $imap->create_mailbox($mb) or $logger->logdie("Mailbox creation '$mb' failed: ", $imap->errstr());
    $logger->info("Created mailbox $mb");
}

sub subscribe {
    my($imap, $box) =@_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    $imap->folder_subscribe($box);
    $logger->info("Subscribed to mailbox $box");
}

sub move_mail {
    my($imap, $i, $new_box) = @_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    if( $imap->copy($i, $new_box) ){
        $logger->info("Copied message number [$i] from ", $imap->current_box ," to [$new_box]");
        delete_mail($imap, $i);
    }
}

sub delete_mail {
    my($imap, $i) = @_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    if( $imap->delete($i) ){
        $logger->info("Deleted message number $i from ", $imap->current_box);
    }
}

sub load_config {
    my($cfg_file) = @_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    $cfg_file //= '/etc/shihai/archive_imap_mailboxes.yaml';
    $logger->debug("Loading configuration file '$cfg_file'");
    my $config = LoadFile($cfg_file);
    $logger->debug("config:", Dumper($config));
    
    # check if values are configured or use defaults
    $config->{threshold}{archive} //= {years => 3};
    $config->{threshold}{delete}  //= {years => 8};

    $config->{imap}{host} //= '127.0.0.1';

    return $config;
}


sub connect_imap {
    my ($cfg) = @_;
    my $logger = Log::Log4perl->get_logger('shihai.archive_mail');

    my $imap = Net::IMAP::Simple::SSL->new($cfg->{host})
        or $logger->logdie("Unable to connect to IMAP server: $Net::IMAP::Simple::errstr");
    $logger->info("Connected to IMAP host $cfg->{host}");

    unless( $imap->login($cfg->{user}, $cfg->{pass}) ){
        $logger->logdie("Login failed: ", $imap->errstr);

    }
    $logger->info("Logged to IMAP host $cfg->{host} as user '$cfg->{user}'");

    return $imap;
}

__END__

=head1 NAME

archive_imap_mailboxes.pl - Archive IMAP mailboxes 

=head1 SYNOPSIS

archive_imap_mailboxes.pl [options] [file ...]

 Options:
   --help            brief help message
   --man             full documentation
   --cfg  <file>     path to configuration file

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<--cfg> <path to file>

Path to the configuration file. Should be YAML based and should have at least:

  imap:
      host: 'hostname'
      user: 'IMAP user'
      pass: 'Password'
  
  threshold:
      archive:
          years: 3
      delete:
          years: 8


=back

=head1 DESCRIPTION

B<This program> will connect to an IMAP account and will either
archive or delete e-mails based on configured thresholds.

=cut
