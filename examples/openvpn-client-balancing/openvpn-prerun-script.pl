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
foreach (@lines) {  # this is amateurish, but made for readability
    my ($service,$physical,$tunnel) = split /\s+/;
    push @vpn,     $service;
    push @physical,$physical;
    push @tunnel,  $tunnel;
}

my $interfaces = $B->interface_info();

# route the lan interfaces or we'll be cut off during this step.
my $table = 101;
for (my $i=0;$i<@physical;$i++) {
    my $dev = $physical[$i];
    my $vpn = $vpn[$i];
    my $eth = $interfaces->{$dev} or next;

    rewrite_vpn_config_file($vpn,$eth->{ip});

    $B->ip_route('flush table',$table);
    $B->ip_route('add',                           $eth->{net},'dev', $eth->{dev},'src',$eth->{ip});
    $B->ip_route('add table',$table,'default dev',$eth->{dev},'via', $eth->{gw});
    $B->ip_route('add table',$table,              $eth->{net},'dev', $eth->{dev},'src',$eth->{ip});
    $B->ip_rule ('add from',                      $eth->{ip},'table',$table);

    # allow outgoing connections to openvpn
    $B->iptables('-A OUTPUT','-o', $eth->{dev}, '-j ACCEPT');
    # accept incoming connections that are continuations of previous connections
    $B->iptables('-A INPUT', '-i', $eth->{dev}, '-m state','--state ESTABLISHED,RELATED','-j ACCEPT');
    $table++;
}

# This bit is just to keep the lan open so that we can watch the progress and the router doesn't
# get cut off if something goes awry.
my @lan   = map {$B->dev($_)} $B->lan_services;
foreach (@lan) {
    my $eth = $interfaces->{$_} or next;
    $B->ip_route('add',                           $eth->{net},'dev', $eth->{dev},'src',$eth->{ip});
    $B->iptables('-A INPUT', '-i', $eth->{dev}, '-j ACCEPT');
    $B->iptables('-A OUTPUT','-o', $eth->{dev}, '-j ACCEPT');
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

# This scary bit of code is needed in order to get the VPN client to
# bind to the correct interface. Otherwise the bind will happen randomly
# and we might get two vpn clients tunneling through the same interface,
# which kinda' defaults the purpose!
sub rewrite_vpn_config_file {
    my ($vpn,$ip) = @_;
    my $old = "/etc/openvpn/$vpn.conf";  # very Ubuntu-specific
    my $new = "/etc/openvpn/$vpn.conf.new";
    open my $n,'>',$new or return;
    print $n "local $ip\n";

    open my $o,'<',$old or return;
    while (<$o>) {
	next if /^(local|nobind)/;
	print $n $_;
    }
    close $o;
    close $n;

    rename($old,"$old.bak");
    rename($new,$old);
}



