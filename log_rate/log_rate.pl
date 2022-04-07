#!/usr/bin/perl
use strict;
use warnings;
use IO::Async::Timer::Periodic;
use IO::Async::Loop;
use Time::HiRes qw/time/;
use Term::ANSIColor qw(:constants);
use Getopt::Long;

my $last_poll_time = time;

my $poll_rate = 2;
GetOptions (
    'p|pollrate=i' => \$poll_rate,
);

my $loop = IO::Async::Loop->new;
my $timer = IO::Async::Timer::Periodic->new(
   interval => $poll_rate,
   on_tick  => \&log_rate
);

$timer->start;
$loop->add( $timer );
$loop->run;

sub log_rate {
    local $SIG{ALRM} = sub { die time, " time exceeded to read STDIN\n" };

    alarm($poll_rate);
    my $h;
    eval {
        local $| = 1;
        while (my $line = <>) {
            chomp($line);
            $h->{$line}++;
        }
    };
    alarm(0);

    return unless keys %$h;

    my $delta_time = time - $last_poll_time;
    print DARK WHITE . sprintf("%d: ", time) . RESET;
    print( BOLD WHITE . $_ ." [" . GREEN . sprintf("%.2f/s", $h->{$_}/$delta_time) . BOLD WHITE "] | " . RESET) foreach keys %$h; 
    print "\n";

    $last_poll_time = time;
}