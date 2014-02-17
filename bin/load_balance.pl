#!/usr/bin/perl

use strict;
use Net::ISP::Balance;
use Getopt::Long;

my $DEBUG;
my $result = GetOptions('debug' => \$DEBUG);

# command line arguments correspond to the ISP services (defined in the config file)
# that are "up". LAN services are assumed to be always up.

my $bal = Net::ISP::Balance->new();

@ARGV = $bal->isp_services unless @ARGV;
my %up_services = map {uc($_) => 1} @ARGV;
my @up          = keys %up_services;

$bal->up(@up);
$bal->echo_only($DEBUG);

# start lsm process if it is not running
start_lsm_if_needed($bal) unless $DEBUG;

$bal->set_routes_and_firewall();
exit 0;

sub start_lsm_if_needed {
    my $bal = shift;

    my $lsm_running = -e '/var/run/lsm.pid' and kill 0=>`cat /var/run/lsm.pid`;
    return if $lsm_running;

    # need to create config file
    if (! -e '/etc/network/lsm.conf') {
	open my $fh,'>','/etc/network/lsm.conf' or die "/etc/network/lsm.conf: $!";
	print $fh $bal->lsm_config_text();
	close $fh or die "/etc/network/lsm.conf: $!";
    }

    # now start the process
    system "lsm /etc/network/lsm.conf /var/run/lsm.pid";
}
