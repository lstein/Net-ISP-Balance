#-*-Perl-*-

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.t'

use strict;
use FindBin '$Bin';
use lib $Bin,"$Bin/../lib";

use Test::More tests=>36;

my $dummy_data = {
    ip_addr_show =><<'EOF',
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN 
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 00:01:c0:08:3e:38 brd ff:ff:ff:ff:ff:ff
    inet 191.3.88.152/27 brd 255.255.255.255 scope global eth0
    inet6 fe80::201:c0ff:fe08:3e38/64 scope link 
       valid_lft forever preferred_lft forever
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 00:01:c0:08:3e:39 brd ff:ff:ff:ff:ff:ff
    inet 192.168.10.1/24 brd 192.168.10.255 scope global eth1
    inet6 fe80::201:c0ff:fe08:3e39/64 scope link 
       valid_lft forever preferred_lft forever
4: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 48:f8:b3:2e:f6:b2 brd ff:ff:ff:ff:ff:ff
    inet 192.168.11.11/24 brd 192.168.11.255 scope global eth2
    inet6 fe80::4af8:b3ff:fe2e:f6b2/64 scope link 
       valid_lft forever preferred_lft forever
5: wlan0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN qlen 1000
    link/ether 00:0d:f0:63:95:61 brd ff:ff:ff:ff:ff:ff
6: eth3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 48:f8:b3:2e:f6:b2 brd ff:ff:ff:ff:ff:ff
    inet 192.168.12.1/24 brd 192.168.12.255 scope global eth3
    inet6 fe80::4af8:b3ff:fe2e:f6b2/64 scope link 
       valid_lft forever preferred_lft forever
7: ppp0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1492 qdisc pfifo_fast state UNKNOWN qlen 3
    link/ppp 
    inet 11.120.199.108 peer 112.211.154.198/32 scope global ppp0
31: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UNKNOWN qlen 100
    link/none 
    inet 10.8.0.1 peer 10.8.0.2/32 scope global tun0
EOF

    ip_route_show =><<'EOF',
default
	nexthop via 112.211.154.198  dev ppp0 weight 1
	nexthop via 191.3.88.1 dev eth0 weight 1
10.8.0.0/24 via 10.8.0.2 dev tun0 
10.8.0.2 dev tun0  proto kernel  scope link  src 10.8.0.1 
192.168.1.0/24 dev eth2  scope link 
192.168.2.0/24 dev eth1  scope link  src 192.168.2.1 
191.3.88.152 dev eth0  scope link 
191.3.88.150/27 dev eth0  scope link  src 191.3.88.152
112.211.154.198 dev ppp0  scope link  src 11.120.199.108
EOF
};


use_ok('Net::ISP::Balance');
my $bal = Net::ISP::Balance->new("$Bin/etc/balance.conf",
				 $dummy_data);
ok($bal,"balancer object created");

my $i = $bal->services;
my @s = sort keys %$i;
is("@s",'CABLE DSL LAN SUBNET VPN',"five services created");

is($i->{DSL}{dev},'ppp0','correct mapping of service to ppp device');
is($i->{CABLE}{dev},'eth0','correct mapping of service to eth device');
is($i->{DSL}{ip},'11.120.199.108','correct mapping of ppp service to ip');
is($i->{CABLE}{ip},'191.3.88.152','correct mapping of dhcp service to ip');
is($i->{LAN}{ip},'192.168.10.1','correct mapping of static service to ip');
is($i->{DSL}{gw},'112.211.154.198','correct mapping of ppp service to gw');
is($i->{CABLE}{gw},'191.3.88.1','correct mapping of dhcp service to gw');
is($i->{VPN}{net},'10.8.0.0/24','correct network for VPN device derived from routing table');
ok(defined($i->{CABLE}{fwmark}),'balanced fwmark defined');
ok(!defined($i->{LAN}{fwmark}),'non-balanced fwmark undefined');
is($bal->dev('DSL'),'ppp0','shortcut working');
is($bal->role('DSL'),'isp','isp role working');
is($bal->role('LAN'),'lan','lan role working');

my $lsm_conf = $bal->lsm_config_text(-warn_email  => 'admin@dummy_host.om');
ok($lsm_conf =~ /warn_email=admin/,'lsm email option correct');
ok($lsm_conf =~ /connection {\n name=DSL\n device=ppp0/,'lsm device option correct');

$bal->echo_only(1);
$bal->rules_directory("$Bin/etc/balance");
my $output = capture(sub {$bal->enable_forwarding(0);
			  $bal->routing_rules;
			  $bal->local_routing_rules}
    );

ok($output =~ m!echo 0 > /proc/sys/net/ipv4/ip_forward!,'correct forwarding setting');
ok($output=~/ip route add default scope global nexthop via 191.3.88.1 dev eth0 weight 1 nexthop via 112.211.154.198 dev ppp0 weight 1/,
   'correct default route creation');
ok($output=~m!ip route add table 1 192.168.10.0/24 dev eth1 src 192.168.10.1!,'correct table addition');
ok($output=~m!echo "01 local routing rules go here"! &&
   $output=~m!echo "02 local routes go here"!,
   'local rule addition');
ok($output=~m!debug: CABLE=>dev=eth0\ndebug: DSL=>dev=ppp0!,'perl local rules working');

$output = capture(sub {$bal->balancing_fw_rules});
ok($output=~m/iptables -t mangle -A PREROUTING -i eth1 -m conntrack --ctstate NEW -m statistic --mode random --probability 0.5 -j MARK-DSL/,'balancing firewall rules produce correct mangle');

$bal->up('CABLE');
$output = capture(sub {$bal->balancing_fw_rules});
ok($output=~m/iptables -t mangle -A PREROUTING -i eth1 -m conntrack --ctstate NEW -j MARK-CABLE/,'balancing firewall rules produce correct mangle');

$bal->up('CABLE','DSL');

$output = capture(sub {$bal->sanity_fw_rules});
ok($output =~ /iptables -t mangle -A POSTROUTING -o ppp0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu/,
   'clamp rules correct');
ok($output =~ m!iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT!,
   'icmp echo flood rules correct');
ok($output =~ m[iptables -A FORWARD -i eth1 -o ppp0 -s 192.168.10.0/24 -j ACCEPT],
   'forwarding rules correct');

$output = capture(
    sub {
	$bal->forward(80 => '192.168.10.35');
	$bal->forward(81 => '192.168.10.35:8080','tcp','udp');
    });
ok($output=~/iptables -t nat -A PREROUTING -i ppp0 -p tcp --dport 80 -j DNAT --to-destination 192.168.10.35/,
   'DNAT rule works');
ok($output=~/iptables -t nat -A PREROUTING -i ppp0 -p tcp --dport 81 -j DNAT --to-destination 192.168.10.35:8080/,
   'host:port syntax works');

$output = capture(sub { $bal->local_fw_rules() });
ok($output =~ /iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 23 -j DNAT --to-destination 192.168.10.35:22/,
   'local forward rules working PREROUTING');
ok($output =~ m!iptables -A INPUT -p tcp -s 192.168.12.0/24 --syn --dport ssh -j ACCEPT!,
   'local accept rules working');

$output = capture(sub {
    $bal->force_route('CABLE',-syn,-p=>'tcp',-dport=>25);
		  });
is($output,"iptables -t mangle -A PREROUTING --syn -p tcp --dport 25 -j MARK-CABLE\n",'force_route()');

$output = capture(
    sub {
	{
	    local $bal->{firewall_op} = 'delete';
	    $bal->force_route('CABLE',-syn,-p=>'tcp',-dport=>25);
	}
    }
);
is($output,"iptables -t mangle -D PREROUTING --syn -p tcp --dport 25 -j MARK-CABLE\n",'delete force_route()');

$output = capture(sub {$bal->add_route('10.10.10.10/8' => 'wlan0',1)});
ok($output =~ m!ip route add 10.10.10.10/8 dev wlan0 table 1!,
   'add_route routing table');
ok($output =~ m!iptables -I FORWARD -i eth1 -s 192.168.10.0/24 -o wlan0 -d 10.10.10.10/8 -j ACCEPT!,
   'add_route firewall');
1;

exit 0;

sub capture {
    my $subroutine = shift;
    my $output = '';
    open my $fh,'>',\$output or die $!;
    local *STDOUT = $fh;
    $subroutine->();
    close $fh;
    return $output;
}
