$B->iptables("-A INPUT -p tcp -s",$B->net($_),"--syn --dport ssh -j ACCEPT") foreach $B->lan_services;

$B->iptables(['-A INPUT -p tcp --syn --dport ssh -m limit --limit 1/s --limit-burst 10 -j ACCEPT',
	      '-A INPUT -p tcp --syn --dport ssh -j DROPFLOOD']);
