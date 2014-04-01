# The next line enables ssh logins from the LAN to the router
$B->iptables("-A INPUT -p tcp -s",$B->net($_),"--syn --dport ssh -j ACCEPT") foreach $B->lan_services;

# To enable ssh logins from other sources, including the Internet, uncomment the following statement
#$B->iptables(['-A INPUT -p tcp --syn --dport ssh -m limit --limit 1/s --limit-burst 10 -j ACCEPT',
#	      '-A INPUT -p tcp --syn --dport ssh -j DROPFLOOD']);
