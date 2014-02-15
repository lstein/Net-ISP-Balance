#!/usr/bin/perl

use strict;
use lib '/etc/network/';
use BalancingNetwork;
$BalancingNetwork::DEBUG_ONLY=0;
$BalancingNetwork::VERBOSE=0;

use constant DISABLE_RP_FILTER => 1;
use constant DEBUG_SYSLOG      => 0;

use constant CABLE_DEVICE     => 'eth0';
use constant   DSL_DEVICE     => 'ppp0';
use constant LAN_DEVICE       => 'eth1';
use constant DSL_MODEM_DEVICE => 'eth2';
use constant CABLE_MODEM      => '192.168.100.1/32';

# get parameters
# can be called with up to two parameters
# "DSL" and "CABLE". If no arguments present,
# then assume both are up.

@ARGV = qw(CABLE DSL) unless @ARGV;
my %up_services = map {uc($_) => 1} @ARGV;


my $D     = get_devices(
    LAN    => [LAN_DEVICE()         => 'lan' ],
    DMODEM => [DSL_MODEM_DEVICE()   => 'ctrl'],
    CABLE  => [CABLE_DEVICE()       => 'wan' ],
    DSL    => [DSL_DEVICE()         => 'wan' ]);

print "#!/bin/sh\n";

            routing($D,\%up_services);
      base_fw_rules($D,\%up_services);
 balancing_fw_rules($D,\%up_services);
       nat_fw_rules($D,\%up_services);
allowed_service_rules($D,\%up_services);
      forward_rules($D,\%up_services);
additional_fw_rules($D,\%up_services);
       flush_and_go($D,\%up_services);

exit 0;

sub routing {
    my ($D,$up) = @_;
    initialize_routes($D);
    create_default_route($D,$up);
    create_service_routing_tables($D,$up);
    extra_routing_rules($D,$up);
}

sub base_fw_rules {
    my ($D,$up) = @_;
    my $landev       = $D->{LAN}{dev};
    my $lan          = $D->{LAN}{net};
    my $dslmodem     = $D->{DMODEM}{net};
    my $dslmodem_dev = $D->{DMODEM}{dev};

    sh <<END;
iptables -F
iptables -t nat    -F
iptables -t mangle -F
iptables -X
iptables -P INPUT    DROP
iptables -P OUTPUT   DROP
iptables -P FORWARD  DROP
END
;

    if (DEBUG_SYSLOG) {
	print STDERR "#Setting up debugging logging\n";
	sh <<END;	
iptables -A INPUT    -j LOG  --log-prefix "INPUT: "
iptables -A OUTPUT   -j LOG  --log-prefix "OUTPUT: "
iptables -A FORWARD  -j LOG  --log-prefix "FORWARD: "
iptables -t nat -A INPUT  -j LOG  --log-prefix "nat INPUT: "
iptables -t nat -A OUTPUT -j LOG  --log-prefix "nat OUTPUT: "
iptables -t nat -A FORWARD -j LOG  --log-prefix "nat FORWARD: "
iptables -t nat -A PREROUTING  -j LOG  --log-prefix "nat PREROUTING: "
iptables -t nat -A POSTROUTING -j LOG  --log-prefix "nat POSTROUTING: "
iptables -t mangle -A INPUT       -j LOG  --log-prefix "mangle INPUT: "
iptables -t mangle -A OUTPUT      -j LOG  --log-prefix "mangle OUTPUT: "
iptables -t mangle -A FORWARD     -j LOG  --log-prefix "mangle FORWARD: "
iptables -t mangle -A PREROUTING  -j LOG  --log-prefix "mangle PRE: "
END
;
    }

# logging rules
    sh <<END;
iptables -N DROPGEN
iptables -A DROPGEN -j LOG -m limit --limit 1/minute --log-level 4 --log-prefix "GENERAL: "
iptables -A DROPGEN -j DROP

iptables -N DROPINVAL
iptables -A DROPINVAL -j LOG -m limit --limit 1/minute --log-level 5 --log-prefix "INVALID: "
iptables -A DROPINVAL -j DROP

iptables -N DROPPERM
iptables -A DROPPERM -j LOG -m limit --limit 1/minute --log-level 4 --log-prefix "ACCESS-DENIED: "
iptables -A DROPPERM -j DROP

iptables -N DROPSPOOF
iptables -A DROPSPOOF -j LOG -m limit --limit 1/minute --log-level 3 --log-prefix "DROP-SPOOF: "
iptables -A DROPSPOOF -j DROP

iptables -N DROPFLOOD
iptables -A DROPFLOOD -m limit --limit 1/minute  -j LOG --log-level 3 --log-prefix "DROP-FLOOD: "
iptables -A DROPFLOOD -j DROP
END

    sh <<END;
# lo is ok
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# kill connections to the local interface from the outside world
iptables -A INPUT -d 127.0.0.0/8 -j DROPPERM

# allow unlimited traffic from internal network using legit address
iptables -A INPUT   -i $landev -s $lan -j ACCEPT

# allow locally-generated output to the LAN on the LANDEV
iptables -A OUTPUT  -o $landev -d $lan  -j ACCEPT
iptables -A OUTPUT  -o $landev -d 255.255.255.255/32  -j ACCEPT

# allow free forwarding to and from the DSL modem 
iptables -A INPUT   -i $dslmodem_dev -s $dslmodem -j ACCEPT
iptables -A OUTPUT  -o $dslmodem_dev -d $dslmodem -j ACCEPT
iptables -A FORWARD -o $dslmodem_dev              -j ACCEPT
iptables -t nat -A POSTROUTING -o $dslmodem_dev   -j MASQUERADE

# accept continuing foreign traffic
iptables -A INPUT   -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT   -p tcp --tcp-flags SYN,ACK ACK -j ACCEPT
iptables -A FORWARD -p tcp --tcp-flags SYN,ACK ACK -j ACCEPT
iptables -A FORWARD -p tcp --tcp-flags SYN,ACK,FIN,RST RST -j ACCEPT

# ICMP rules -- we allow ICMP, but establish flood limits
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j DROPFLOOD

# deny icmp responses to our broadcast addresses
# ??
# iptables -A INPUT -p icmp -d \$BCAST -j DROPINVAL

# allow other icmp in & out (is this a good idea?)
#iptables -A INPUT  -p icmp -j ACCEPT
#iptables -A OUTPUT -p icmp -j ACCEPT

# any outgoing udp packet is fine with me
iptables -A OUTPUT  -p udp -s $lan -j ACCEPT

# domain
iptables -A INPUT   -p udp --source-port domain -j ACCEPT
iptables -A FORWARD -p udp --source-port domain -d $lan -j ACCEPT

# time
iptables -A INPUT   -p udp --source-port ntp -j ACCEPT
iptables -A FORWARD -p udp --source-port ntp -d $lan -j ACCEPT
END
;

    # allow lan/wan forwarding
    for my $svc (keys %$D) {
	next unless $D->{$svc}{table};
	sh "iptables -A FORWARD  -i $landev -o $D->{$svc}{dev} -s $lan ! -d $lan -j ACCEPT";
	sh "iptables -A OUTPUT   -o $D->{$svc}{dev}                    ! -d $lan -j ACCEPT";
    }

    # anything else is bizarre and should be dropped
    sh "iptables -A OUTPUT  -j DROPSPOOF";
}

# Here are allowed incoming connections

sub allowed_service_rules {
    my ($D,$up) = @_;
    print STDERR "#defining allowed services\n";
    my $lan    = $D->{LAN}{net};
    my $landev = $D->{LAN}{dev};
    
    # accept secure shell, to ourselves...
    sh "iptables -A INPUT   -p tcp -s $lan --syn --dport ssh -j ACCEPT";
    sh "iptables -A INPUT   -p tcp --syn --dport ssh -m limit --limit 1/s --limit-burst 10 -j ACCEPT";
    sh "iptables -A INPUT   -p tcp --syn --dport ssh -j DROPFLOOD";

    # accept snmp requests from lan
    # sh "iptables -A INPUT   -p udp -s $lan --dport snmp -j ACCEPT";

    sh <<END;
# accept DHCP requests on LAN device
iptables -A INPUT -p udp -i $landev \\
    --source-port      bootpc   -d  255.255.255.255 \\
    --destination-port bootps -j ACCEPT
END
;

    for my $svc (keys %$up) {
	sh <<END;
# silently reject DHCP requests from WAN devices
iptables -A INPUT -p udp -i $D->{$svc}{dev} \\
    --source-port      bootps -d 255.255.255.255 \\
    --destination-port bootpc -j DROP
END
;
    }
}

sub balancing_fw_rules {
    my ($D,$up) = @_;
    print STDERR "#balancing FW rules\n";
    for my $svc (keys %$D) {
	my $table = "MARK-${svc}";
	my $mark  = $D->{$svc}{fwmark};
	next unless defined $mark && defined $table;
	sh <<END;
iptables -t mangle -N $table
iptables -t mangle -A $table -j MARK     --set-mark $mark
iptables -t mangle -A $table -j CONNMARK --save-mark
END
    }
 
    # packets from LAN
    my $landev = $D->{LAN}{dev};
    sh "iptables -t mangle -A PREROUTING -i $landev -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark";

    if (keys %$up > 1) {
	print STDERR "#Creating balanced mangling rules\n";
	my $count = keys %$up;
	my $i = 1;
	for my $svc (keys %$up) {
	    my $table = "MARK-${svc}";
	    my $probability = 1/$i++; # 1, 1/2, 1/3, 1/4...
	    sh "iptables -t mangle -A PREROUTING -i $landev -m conntrack --ctstate NEW -m statistic --mode random --probability $probability -j $table";
	}
    }

    else {
	my ($svc) = keys %$up;
	print STDERR "#forcing all traffic through $svc\n";
	sh "iptables -t mangle -A PREROUTING -i $landev -m conntrack --ctstate NEW -j MARK-${svc}";
    }
}

sub nat_fw_rules {
    my ($D,$up) = @_;
    print STDERR "#creating NAT rules\n";
    for my $svc (keys %$up) {
	sh "iptables -t nat -A POSTROUTING -o $D->{$svc}{dev} -j MASQUERADE";
    }
}

# here where we put forwardings
sub forward_rules {
    my ($D,$up) = @_;
    forward(51414=>'192.168.2.35','tcp','udp');
}

# extra stuff
sub additional_fw_rules {
    my ($D,$up) = @_;
    # traffic to the cable modem always goes out through the cable modem device
    sh "iptables -t mangle -A PREROUTING -p tcp -d 192.168.100.1/32 -j MARK-CABLE";
}

sub forward {
    my ($port,$host,@protocols) = @_;
    @protocols = ('tcp') unless @protocols;
    my @dev = map {$D->{$_}{dev}} keys %up_services;  # uses globals
    for my $protocol (@protocols) {
	for my $d (@dev) {
	    sh <<END;
iptables -A INPUT   -p $protocol --dport $port -j ACCEPT
iptables -A FORWARD -p $protocol --dport $port -j ACCEPT
iptables -t nat -A PREROUTING -i $d -p $protocol --dport $port -j DNAT --to-destination $host
END
	}
    }
}

sub flush_and_go {
    my ($D,$up) = @_;

    print STDERR "#activating forwarding\n";
    sh "echo 1 > /proc/sys/net/ipv4/ip_forward";

    print STDERR "#Flushing caches\n";
    sh "ip route flush cache";
    for my $svc (keys %$D) {
	next unless $up->{$svc};
	sh "ip route flush cache table $D->{$svc}{table}";
    }
}


######## lower level ######
sub initialize_routes {
    my $D = shift;
    sh <<END;
ip route flush all
ip rule flush
ip rule add from all lookup main pref 32766
ip rule add from all lookup default pref 32767
END
    ;

    sh "ip route flush table $D->{$_}{table}" foreach grep {$D->{$_}{table}} keys %$D;

    # main table
    for my $svc (keys %$D) {
	# EG: ip route add 192.168.10.0/24 dev eth0 src 192.168.10.2
	sh "ip route add $D->{$svc}{net} dev $D->{$svc}{dev} src $D->{$svc}{ip}";
    }
}

sub create_default_route {
    my ($D,$up) = @_;

    # create multipath route
    if (keys %$up > 1) { # multipath
	print STDERR "# Setting multipath default gw\n";
	# EG
	# ip route add default scope global nexthop via 192.168.10.1 dev eth0 weight 1 \
	#                                   nexthop via 192.168.11.1 dev eth1 weight 1
	my $hops = '';
	for my $svc (keys %$up) {
	    my $d  = $D->{$svc} or next;
	    my $gw = $d->{gw}   or next;
	    $hops  .= "nexthop via $gw dev $d->{dev} weight 1 ";
	}
	die "no valid gateways!" unless $hops;
	sh "ip route add default scope global $hops";
    } 

    else {
	my ($dev) = keys %$up; # select one at random
	print STDERR "#Setting single default route via $dev\n";
	sh "ip route add default via $D->{$dev}{gw} dev $D->{$dev}{dev}";
    }
}

# create service-specific routing tables
sub create_service_routing_tables {
    my ($D,$up) = @_;
    
    for my $svc (keys %$D) {
	next unless defined $D->{$svc}{fwmark};
	print STDERR "#Creating routing table for $svc\n";
	sh "ip route add table $D->{$svc}{table} default dev $D->{$svc}{dev} via $D->{$svc}{gw}";
	for my $s (keys %$D) {
	    sh "ip route add table $D->{$svc}{table} $D->{$s}{net} dev $D->{$s}{dev} src $D->{$s}{ip}";
	}
	sh "ip rule add from $D->{$svc}{ip} table $D->{$svc}{table}";
	sh "ip rule add fwmark $D->{$svc}{fwmark} table $D->{$svc}{table}";
    }
}

sub extra_routing_rules {
    my ($D,$up) = @_;
    my $cable_modem     = CABLE_MODEM();
    my $cable_modem_dev = CABLE_DEVICE;
    sh "ip route add $cable_modem dev $cable_modem_dev src $D->{CABLE}{ip}";
}
