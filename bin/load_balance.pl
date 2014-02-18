#!/usr/bin/perl

use strict;
use Net::ISP::Balance;
use Getopt::Long;

my $DEBUG;
my $result = GetOptions('debug' => \$DEBUG);
$result or die <<END;
Usage: $0 [-d] ISP1 ISP2 ISP3...

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

END

# command line arguments correspond to the ISP services (defined in the config file)
# that are "up". LAN services are assumed to be always up.

my $bal = Net::ISP::Balance->new();

my @up = @ARGV ? @ARGV : $bal->isp_services;
my %up_services = map {uc($_) => 1} @up;
@up             = keys %up_services; # uniqueify

$bal->up(@up);
$bal->echo_only($DEBUG);

# start lsm process if it is not running
start_lsm_if_needed($bal) unless @ARGV || $DEBUG;

$bal->set_routes_and_firewall();
exit 0;

sub start_lsm_if_needed {
    my $bal = shift;

    my $lsm_running = -e '/var/run/lsm.pid' && kill(0=>`cat /var/run/lsm.pid`);
    return if $lsm_running;

    # need to create config file
    if (! -e '/etc/network/lsm.conf' || 
	(-M '/etc/network/balance.conf' < -M '/etc/network/lsm.conf')) {
	open my $fh,'>','/etc/network/lsm.conf' or die "/etc/network/lsm.conf: $!";
	print $fh $bal->lsm_config_text();
	close $fh or die "/etc/network/lsm.conf: $!";
    }

    # now start the process
    system "lsm /etc/network/lsm.conf /var/run/lsm.pid";
}
