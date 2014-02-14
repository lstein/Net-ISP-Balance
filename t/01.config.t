#-*-Perl-*-

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.t'

use strict;
use FindBin '$Bin';
use lib $Bin,"$Bin/../lib";

use Test::More tests=>13;  

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
eth1      Link encap:Ethernet  HWaddr 00:02:8f:91:11:12  
          inet addr:192.168.11.11  Bcast:192.168.11.255  Mask:255.255.255.0
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
my $bal = Net::ISP::Balance->new("$Bin/etc/balancer.conf",
			         "$Bin/etc/interfaces",
				 {
				 ifconfig_eth0 => $ifconfig_eth0,
				 ifconfig_eth1 => $ifconfig_eth1,
				 ifconfig_eth2 => $ifconfig_eth2,
				 ifconfig_ppp0 => $ifconfig_ppp0,
				 leases_eth0   => $leases_eth0,
				 }	       
    );
ok($bal,"balancer object created");

my $i = $bal->services;
my @s = sort keys %$i;
is("@s",'CABLE DSL LAN',"three services created");

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

