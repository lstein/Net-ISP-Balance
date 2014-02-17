#!/usr/bin/perl

use strict;
use Net::ISP::Balance;

# command line arguments correspond to the ISP services (defined in the config file)
# that are "up". LAN services are assumed to be always up.

@ARGV = qw(CABLE DSL) unless @ARGV;
my %up_services = map {uc($_) => 1} @ARGV;
my @up          = keys %up_services;

my $bal = Net::ISP::Balance->new();
$bal->up(@up);
$bal->echo_only(1);

# start lsm process if it is not running
start_lsm_if_needed($bal);

$bal->set_routes_and_firewall();
exit 0;

sub start_lsm_if_needed {
    my $bal = shift;

    my $lsm_running = -e /var/run/lsm.pid && kill 0=>`cat /var/run/lsm.pid`;
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
