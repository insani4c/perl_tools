#!/usr/bin/env perl 
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
foreach my $p (@{ $processes }){
    $procs{ $p->{pid} } = $p->{cmndline};
    foreach my $s (keys %services){
        if($p->{cmndline} =~ m#$services{$s}->{re}#){
            $matched_procs{$s}++;
			last;
        }
    }
}
 
# Search the process table for not running services
foreach my $service ( keys %services ) {
    if( -f $services{$service}->{pidfile} ) {
        my $pid = read_file( glob($services{$service}->{pidfile}) );
 
        # If we get a pid ensure that it is running, and that we can signal it
        $pid && exists($procs{$pid}) && kill(0, $pid) && next;  
        
        # Remove the stale PID file because no running process for this PID file
        unlink( $services{$service}->{pidfile} );
    }
    else {
        # check if the configured process regex matches
        if( exists($matched_procs{$service}) ){
            # process is running but has no PID file
            next;
        }
    }
    
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

