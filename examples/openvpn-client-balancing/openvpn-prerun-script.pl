#!/usr/bin/perl

# This example script shows how to set up a couple of OpenVPN tunnels
# and load balance across them. To use, you will need to edit the
# following table:

my $CONFIG = <<END;
# service    physical_interface   tunnel_interface
pia1         eth0                 tun0
pia2         eth1                 tun1
END
    ;
# this is the number of seconds we will wait for each OpenVPN interface to come up.
use constant TRIES=> 20;

#################################################################################
# don't edit anything below this line
#################################################################################
    ;
my @lines = grep {/\S/ && !/^#/} split "\n",$CONFIG;
my (@vpn,@physical,@tunnel);
foreach (@lines) {
    my ($service,$physical,$tunnel) = split /\s+/;
    push @vpn,     $service;
    push @physical,$physical;
    push @tunnel,  $tunnel;
}

my $interfaces = $B->interface_info();

my $table = 101;
foreach ('eth3',@physical) {
    my $eth = $interfaces->{$_} or next;
    $B->ip_route('flush table',$table);
    $B->ip_route('add',                           $eth->{net},'dev', $eth->{dev},'src',$eth->{ip});
    $B->ip_route('add table',$table,'default dev',$eth->{dev},'via', $eth->{gw});
    $B->ip_route('add table',$table,              $eth->{net},'dev', $eth->{dev},'src',$eth->{ip});
    $B->ip_rule ('add from',                      $eth->{ip},'table',$table);

    $B->iptables('-A INPUT', '-i', $eth->{dev}, '-j ACCEPT');
    $B->iptables('-A OUTPUT','-o', $eth->{dev}, '-j ACCEPT');
    $table++;
}

for (my $i=0;$i<@vpn;$i++) {
    next if `service openvpn status $vpn[$i]`  =~ /is running/
	&&  `ifconfig $tunnel[$i] 2>/dev/null` =~ /UP/;

    print STDERR "starting $vpn[$i]\n";

    my $phys = $physical[$i];

    my $route  = "default via $interfaces->{$phys}{gw} dev $interfaces->{$phys}{dev}";
    $B->ip_route('add',$route);  # so that we can do name resolution! 
    system "service openvpn start $vpn[$i]";

    for (my $try=1;$try<=TRIES;$try++) {
	print STDERR "waiting for $vpn[$i] to come up: try $try/",TRIES,"...\n";
	if (`service openvpn status $_`       =~ /is running/
	    && `ifconfig $tunnel[$i] 2>/dev/null` =~ /UP/) {
	    print STDERR "Succcess!\n";
	    last;
	}
	sleep 1;
    }

    $B->ip_route('del',$route);  # so that we can do name resolution! 
}





