#!/usr/bin/perl

use strict;
use Net::ISP::Balance;
use Sys::Syslog;
use Getopt::Long;

my ($DEBUG,$VERBOSE,$STATUS,$KILL);
my $result = GetOptions('debug' => \$DEBUG,
			'verbose'=>\$VERBOSE,
			'status' => \$STATUS,
			'kill'   => \$KILL,
    );
$result or die <<END;
Usage: $0 [-options] ISP1 ISP2 ISP3...

This script will mark the Internet Service Providers (ISPs) listed on
the command line as "up" and will then load balance your network
connections among them. The ISPs are defined in the configuration file
/etc/network/balance.conf.

If called without any ISP arguments, the script will mark all known
ISPs as being up and launch the "lsm" link monitor to test each one
periodically for connectivity.

Options:

 --debug, -d     Turn on debugging. In this mode, no firewall or
                 routing commands will be executed, but instead
                 will be printed to standard output for inspection.

 --verbose, -v   Verbose output. Echo all route and iptables commands
                 to STDERR before executing them.

 --status,-s     Print current status of each monitored ISP interface
                 to STDOUT.

 --kill,-k       Kill any running lsm process.

If the script is invoked with a first argument of "up", "down",
"long_down" or "long_down_to_up" followed by more than 3 arguments,
then the script will decide that it has been called by the lsm link
monitor as the result of a change in state in one or more of the
monitored interfaces. It will then institute an appropriate routing
change.

END

# command line arguments correspond to the ISP services (defined in the config file)
# that are "up". LAN services are assumed to be always up.

my $bal = Net::ISP::Balance->new();
$bal->echo_only($DEBUG);
$bal->verbose($VERBOSE);

# these two subroutines exit
do_status()   if $STATUS;
do_kill_lsm() if $KILL;

openlog('load_balance.pl','ndelay,pid','local0');
unless ($bal->isp_services) {
    syslog('crit',"No ISP services appear to be configured. Make sure that balance.conf is correctly set up and that the ISP and LAN-connected interfaces are configured via system configuration files rather than NetworkManager (or similar)");
    exit 0;
}

my %LSM_STATE = (up              => 'up',
		 down            => 'up',
		 long_down       => 'down',
		 long_down_to_up => 'up');

if ($LSM_STATE{$ARGV[0]} && @ARGV >= 5) {
    my ($state,$name,$checkip,$device,$email) = @ARGV;
    syslog('warning',"$name ($device) is now $state. Fixing routing tables");
    $bal->event($name => $LSM_STATE{$state});
    my @up = $bal->up;
    syslog('info',"ISP services currently marked up: @up");    
}

else {
    my @up = @ARGV ? @ARGV : $bal->isp_services;
    my %up_services = map {uc($_) => 1} @up;
    @up             = keys %up_services; # uniqueify
    $bal->up(@up);
}

# start lsm process if it is not running
start_lsm_if_needed($bal) unless @ARGV || $DEBUG;

$bal->set_routes_and_firewall();
exit 0;

sub do_status {
    my $state = $bal->event();
    for my $svc (sort $bal->isp_services) {
	printf("%-15s %8s\n",$svc,$state->{$svc}||'unknown');
    }
    exit 0;
}

sub do_kill_lsm {
    my $lsm_running = -e '/var/run/lsm.pid' && kill(0=>`cat /var/run/lsm.pid`);
    if ($lsm_running) {
	kill(TERM => `cat /var/run/lsm.pid`);
	print STDERR "lsm process killed\n";
    } else {
	print STDERR "lsm does not seem to be running\n";
    }
    exit 0;
}

sub start_lsm_if_needed {
    my $bal = shift;

    my $lsm_conf = $bal->lsm_conf_file;
    my $bal_conf = $bal->bal_conf_file;

    my $lsm_running = -e '/var/run/lsm.pid' && kill(0=>`cat /var/run/lsm.pid`);
    if ($lsm_running) {  # check whether the configuration file needs changing

	open my $fh,'<',$lsm_conf or return;
	my $old_text = '';
	$old_text .= $_ while <$fh>;
	close $fh;

	my $new_text = $bal->lsm_config_text();
	return if $new_text eq $old_text;

	kill TERM=>`cat /var/run/lsm.pid`;  # kill lsm and restart
    }

    # Create config file
    open my $fh,'>',$lsm_conf or die "$lsm_conf: $!";
    print $fh $bal->lsm_config_text();
    close $fh or die "$lsm_conf: $!";

    # now start the process
    $ENV{PATH} .= ":/usr/local/bin" unless $ENV{PATH} =~ m!/usr/local/bin!;
    system "lsm $lsm_conf /var/run/lsm.pid";
}
