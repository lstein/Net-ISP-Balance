#-*-Perl-*-

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.t'

use strict;
use FindBin '$Bin';
use IO::String;
use lib $Bin,"$Bin/../lib";

use Test::More tests=>33;

my $ifconfig_eth0=<<'EOF';
eth0      Link encap:Ethernet  HWaddr 00:02:cb:88:4f:11  
          inet addr:191.3.88.152  Bcast:255.255.255.255  Mask:255.255.255.224
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:15112298 errors:0 dropped:0 overruns:0 frame:0
          TX packets:14837376 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:11487635977 (11.4 GB)  TX bytes:7073254884 (7.0 GB)
EOF
my $ifconfig_ppp0=<<'EOF';
ppp0      Link encap:Point-to-Point Protocol  
          inet addr:11.120.199.108  P-t-P:112.211.154.198  Mask:255.255.255.255
          UP POINTOPOINT RUNNING NOARP MULTICAST  MTU:1492  Metric:1
          RX packets:8804785 errors:0 dropped:0 overruns:0 frame:0
          TX packets:6320295 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:3 
          RX bytes:4657479012 (4.6 GB)  TX bytes:3419043901 (3.4 GB)
EOF
my $ifconfig_eth1=<<'EOF';
eth1      Link encap:Ethernet  HWaddr 00:02:8f:91:11:11  
          inet addr:192.168.10.1  Bcast:192.168.10.255  Mask:255.255.255.0
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:24780338 errors:0 dropped:0 overruns:0 frame:0
          TX packets:25389079 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:10860168129 (10.8 GB)  TX bytes:19336447379 (19.3 GB)
EOF
my $ifconfig_eth2=<<'EOF';
eth2      Link encap:Ethernet  HWaddr 00:02:8f:91:11:12  
          inet addr:192.168.11.11  Bcast:192.168.11.255  Mask:255.255.255.0
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:24780338 errors:0 dropped:0 overruns:0 frame:0
          TX packets:25389079 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:10860168129 (10.8 GB)  TX bytes:19336447379 (19.3 GB)
EOF
my $ifconfig_eth3=<<'EOF';
eth3      Link encap:Ethernet  HWaddr 00:02:8f:91:11:13  
          inet addr:192.168.12.1  Bcast:192.168.12.255  Mask:255.255.255.0
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:24780338 errors:0 dropped:0 overruns:0 frame:0
          TX packets:25389079 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:10860168129 (10.8 GB)  TX bytes:19336447379 (19.3 GB)
EOF
my $leases_eth0=<<'EOF';
lease {
  interface "eth0";
  fixed-address 191.3.88.152;
  option subnet-mask 255.255.255.224;
  option dhcp-lease-time 2626;
  option routers 191.3.88.1;
  option dhcp-message-type 5;
  option broadcast-address 255.255.255.255;
}
EOF

use_ok('Net::ISP::Balance');
my $bal = Net::ISP::Balance->new("$Bin/etc/balance.conf",
			         "$Bin/etc/interfaces",
				 {
				 ifconfig_eth0 => $ifconfig_eth0,
				 ifconfig_eth1 => $ifconfig_eth1,
				 ifconfig_eth2 => $ifconfig_eth2,
				 ifconfig_eth3 => $ifconfig_eth3,
				 ifconfig_ppp0 => $ifconfig_ppp0,
				 leases_eth0   => $leases_eth0,
				 }	       
    );
ok($bal,"balancer object created");

my $i = $bal->services;
my @s = sort keys %$i;
is("@s",'CABLE DSL LAN SUBNET',"four services created");

is($i->{DSL}{dev},'ppp0','correct mapping of service to ppp device');
is($i->{CABLE}{dev},'eth0','correct mapping of service to eth device');
is($i->{DSL}{ip},'11.120.199.108','correct mapping of ppp service to ip');
is($i->{CABLE}{ip},'191.3.88.152','correct mapping of dhcp service to ip');
is($i->{LAN}{ip},'192.168.10.1','correct mapping of static service to ip');
is($i->{DSL}{gw},'112.211.154.198','correct mapping of ppp service to gw');
is($i->{CABLE}{gw},'191.3.88.1','correct mapping of dhcp service to gw');
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
ok($output=~/ip route add default scope global nexthop via 112.211.154.198 dev ppp0 weight 1 nexthop via 191.3.88.1 dev eth0 weight 1/,
   'correct default route creation');
ok($output=~m!ip route add table 1 192.168.10.0/24 dev eth1 src 192.168.10.1!,'correct table addition');
ok($output=~m!echo "01 local routing rules go here"! &&
   $output=~m!echo "02 local routes go here"!,
   'local rule addition');
ok($output=~m!debug: DSL=>dev=ppp0\ndebug: CABLE=>dev=eth0!,'perl local rules working');

$output = capture(sub {$bal->balancing_fw_rules});
ok($output=~m/iptables -t mangle -A PREROUTING -i eth1 -m conntrack --ctstate NEW -m statistic --mode random --probability 0.5 -j MARK-CABLE/,'balancing firewall rules produce correct mangle');

$bal->up('CABLE');
$output = capture(sub {$bal->balancing_fw_rules});
ok($output=~m/iptables -t mangle -A PREROUTING -i eth1 -m conntrack --ctstate NEW -j MARK-CABLE/,'balancing firewall rules produce correct mangle');

$bal->up('CABLE','DSL');

$output = capture(sub {$bal->sanity_fw_rules});
ok($output =~ /iptables -t mangle -A POSTROUTING -o ppp0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu/,
   'clamp rules correct');
ok($output =~ m!iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT!,
   'icmp echo flood rules correct');
ok($output =~ m[iptables -A FORWARD  -i eth1 -o ppp0 -s 192.168.10.0/24 ! -d 192.168.10.0/24 -j ACCEPT],
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

exit 0;

sub capture {
    my $subroutine = shift;
    my $output = '';
    tie *FOO,'IO::String',$output;
    local *STDOUT = \*FOO;
    $subroutine->();
    untie *FOO;
    return $output;
}
