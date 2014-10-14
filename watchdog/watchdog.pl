#!/usr/bin/env perl 
#
# Description: Monitor running processes
# Author: Johnny Morano <jmorano@moretrix.com>
# $Id$
#
use strict; use warnings;
use utf8;
 
use Proc::ProcessTable;
use YAML qw/LoadFile/;
use File::Slurp;
 
# Default set of processes to watch
my %default_services = (
    'NRPE' => {
        'cmd'     => '/etc/init.d/nagios-nrpe-server restart',
        're'      => '/usr/sbin/nrpe -c /etc/nagios/nrpe.cfg -d',
        'pidfile' => '/var/tmp/nagios-nrpe-server.pid',
    },
    'Freshclam' => {
        'cmd'     => '/etc/init.d/clamav-freshclam restart',
        're'      => '/usr/bin/freshclam -d --quiet',
        'pidfile' => '/var/tmp/clamav-freshclam.pid',
    },
    'Syslog-NG' => {
        'cmd'     => '/etc/init.d/syslog-ng restart',
        're'      => '/usr/sbin/syslog-ng -p /var/run/syslog-ng.pid',
        'pidfile' => '/var/run/syslog-ng.pid',     
    },
    'VMToolsD' => {
        'cmd'     => '/etc/init.d/vmware-tools restart',
        're'      => '/usr/sbin/vmtoolsd',
        'pidfile' => '/var/tmp/vmtoolsd.pid',
    },
    'Munin-Node' => {
        'cmd'     => '/etc/init.d/munin-node restart',
        're'      => '/usr/sbin/munin-node',
        'pidfile' => '/var/tmp/munin-node.pid',
    },
);
 
my (%services) = (%default_services);

# Check if there is a local config file and if yes, load them in the services hash
if(  -f '/etc/default/watchdog.yaml' ){
    my $local_config = LoadFile '/etc/default/watchdog.yaml';
 
    %services = (%default_services, %{ $local_config->{services} });
}

# Get current process table
my $processes = Proc::ProcessTable->new;
my %procs; 
my %matched_procs;
foreach my $p (@{ $processes->table }){
    $procs{ $p->{pid} } = $p->{cmndline};
    foreach my $s (keys %services){
        if($p->{cmndline} =~ m#$services{$s}->{re}#){
            push @{ $matched_procs{$s} }, $p->{pid};
            last;
        }
    }
}
 
# Search the process table for not running services
foreach my $service ( keys %services ) {
    my ($pidfile) = ( glob($services{"$service"}->{pidfile}) )[0];

    if( -f $pidfile ) {
        my $pid = read_file( $pidfile );
 	    chomp($pid);
 
        # found a PID in PID file
        if($pid){
            # The found PID exists in the process list
            if( exists($procs{$pid}) ){
                # If we get a pid ensure that it is running, and that we can signal it
                kill(0, $pid) && next;
            }
            else {
                # Service was found in the process list but the PID in the PID file doesnt match
                if(defined $matched_procs{$service} &&  scalar @{ $matched_procs{$service} } ) {
                    print "- Process '$service' not running with PID '$pid' (PID_file: "
                          . $pidfile . "), killing process(es)...\n";
                    # Kill the processes so that it can be restarted
                    kill(15, $_)  foreach @{ $matched_procs{$service} };
                }
            }
        }
        # No PID in file, let's search for processes that match the regular expression
        elsif(defined $matched_procs{$service} && scalar @{ $matched_procs{$service} }){
            # kill the found processes, we will restart it lateron
            print "- Process '$service' running, no PID in PID_file: "
                  . $pidfile . ", killing process(es)...\n";
            kill(15, $_)  foreach @{ $matched_procs{$service} };
        }
    }
    # No PID file, let's search for processes that match the regular expression
    else {
        # check if the configured process regex matches
        if(defined $matched_procs{$service} &&  scalar @{ $matched_procs{$service} } ){
            print "- Process '$service' running, no PID_file: "
                  . $pidfile . " found, killing process(es)...\n";
            # kill the found processes, we will restart it lateron
            kill(15, $_)  foreach @{ $matched_procs{$service} };
        }
    }

    # Remove the stale PID file because no running process for this PID file
    unlink( $pidfile );
    print "- Removed PID file '". $pidfile ."'\n";
    
    # Execute the service command
    system( $services{$service}->{'cmd'} );

    # Check the exit code of the service command
    if ($? == -1) {
        print "Failed to restart '$service' with '$services{$service}->{cmd}': $!\n";
    }
    elsif ($? & 127) {
        printf "Restart of '$service' died with signal %d, %s coredump\n", ($? & 127),  ($? & 128) ? 'with':'without';
    }
    else {
        printf "Process '$service' successfully restarted, exit status:  %d\n", $? >> 8;
    }
}


