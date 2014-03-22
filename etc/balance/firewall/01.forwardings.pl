# allow incoming domain and time services to be forwarded to connected LAN(s)
$B->iptables(["-A FORWARD -p udp --source-port domain -d $_ -j ACCEPT",
	      "-A FORWARD -p udp --source-port ntp    -d $_ -j ACCEPT"]
    ) foreach map {$B->net($_)} $B->lan_services;

# enter forwardings of incoming connections like this:
# $B->forward(23=>'192.168.10.35:22');

