Net-ISP-Balance
===============

This is a set of scripts that enable you to load-balance a home or
small business Internet connection across two or more ISPs. You gain
additional bandwidth and reliability; if one ISP fails, the other(s)
will take over automatically.

These scripts are designed to run on top of a Linux system, and have
not been tested on Windows or Mac OSX. A typically network topology
looks like this:

<pre>


                                   Cable modem ------> ISP1
                                       ^
  home machine 1 ------>|              |
                        |              |
  home machine 2 ------>|------->router/firewall
                        |              |
  home machine 3 ------>|              |
                                       v
                                   DSL modem   ------> ISP2


   Local Area Network(LAN)             |     Wide Area Network (WAN)
      
</pre>

The scripts run on the Linux-based router/firewall machine. In order
to install, you must have the ability to run a shell on the router,
and compile and install software.

LIMITATIONS: To date (18 February 2014) these scripts have only been
tested on Ubuntu/Debian systems that configure their network
interfaces via a /etc/network/interfaces file. I am currently
generalizing the code to work with Red Hat-based systems that use
/etc/sysconfig/network-scripts.

Installation
============

1. Download the zip file of the source code from
https://github.com/lstein/Net-ISP-Balance, or use git to clone the
repository. 

2. Place the unpacked subdirectory in a home directory on the
router/firewall machine.

3. Check/install the following prerequisites on the router:

 a. C compiler and "make" tool. ("apt-get install build-essential" on
 Debian/Ubuntu systems will do this for you.)

 b. Perl version 5.8 or higher.

4. Enter the unpacked directory and run:

  perl ./Build.PL
  ./Build installdeps
  ./Build test
  sudo ./Build install

5. Edit the configuration file located in /etc/network/balance.conf
to meet your needs. The core of the file looks like this:

 #service    device   role     ping-ip
 CABLE	    eth0     isp      173.194.43.95
 DSL	    eth1     isp      173.194.43.95
 LAN	    eth2     lan      

Each line of the table defines a "service" that corresponds to an ISP
or a connected LAN. 

The first column is a service name that is used to
bring up or down the needed routes and firewall rules.

The second column is the name of the network interface device that
connects to that service.

The third column is either "isp" or "lan". There may be any number of
these. The script will firewall traffic passing through any of the
ISPs, and will load balance traffic among them. Traffic can flow
freely among any of the interfaces marked as belonging to a LAN.

The fourth and last column is the IP address of a host that can be
periodically pinged to test the integrity of each ISP connection. If
too many pings failed, the service will be brought down and all
traffic routed through the remaining ISP(s). The service will continue
to be monitored and will be brought up when it is once again
working. Choose a host that is not likely to go offline for reasons
unrelated to your network connectivity, such as google.com, or the
ISP's web site.

6. (optional) Make edits to the firewall and route rules.

This mechanism allows you to add additional entries to the routing
tables and/or firewall. See Further Configuration for more details.

7. (optional) Run load_balance.pl in debug mode to see the commands it
will execute.

If you wish to check how the balancing script will configure your
system when you execute it, then run (as a regular user) the following
command:

 /etc/network/load_balance.pl -d > commands.sh

The "-d" argument puts the script into debug mode. All commands that
it would run on your behalf are placed into 'commands.sh' for your
inspection. You may also execute commands.sh to start balanced routing
and firewalling:

 /bin/sh commands.sh

8. Start the script running. Become the superuser and run
load_balance.pl:

 sudo /etc/network/load_balance.pl

This will configure the system for load balancing, installing a
restrictive set of firewall rules, and launch the lsm daemon to
monitor each of the ISPs for activity.

9. Arrange for load_balance.pl to be run on system startup time.

You may do this by adding an entry in rc.local:

 if [ -x /etc/network/load_balance.pl ]; then
     /etc/network/load_balance.pl
 fi

However, my preference is to invoke the script when the LAN interface
comes up. Edit /etc/network/interfaces, find the reference to the LAN
interface, and edit it to add a "post-up" option as shown here:

 auto eth2
 iface eth2 inet static
 ... blah blah ...
 post-up /etc/network/load_balance.pl

Further Configuration
=====================

The default is to establish a reasonably restrictive firewall which
allows incoming ssh services to the router from the Internet and
rejects all other incoming services. You may modify this if you wish
by adding additional firewall rules and routes.

The routes and rules are located in these subdirectories:

 /etc/network/balance/firewall       # firewall rules
 /etc/network/balance/routes         # routes

Any files you put into these directories will be read in alphabetic
order and added to the routes and/or firewall rules emitted by the
load balancing script.

A typical routing rules file will look like the example shown
below.

(/etc/network/balance/routes/01.local_routes.conf)

 ip route add 192.168.100.1  dev eth0 src 198.162.1.14
 ip route add 192.168.1.0/24 dev eth2 src 10.0.0.4

Each line will be sent to the shell, and it is intended (but not
required) that these be calls to the "ip" command. General shell
scripting constructs are not allowed here.

A typical firewall rules file will look like the example shown here:

(/etc/network/balance/firewall/01.iptables_extras)

 # accept incoming telnet connections to the router
 iptable -A INPUT -p tcp --syn --dport telnet -j ACCEPT
 # masquerade connections to the DSL modem's control interface
 iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE

You may also insert routing and firewall rules via fragments of Perl
code, which is convenient because you don't have to hard-code any
network addresses and can make use of a variety of shortcuts. To do
this, simply end the file's name with .pl and make it executable.

Here's an example of a file named
/etc/network/balance/01.forwardings.pl that defines a series of port
forwarding rules for incoming connections:

 $B->forward(80 => '192.168.10.35'); # forward port 80 to internal web server
 $B->forward(443=> '192.168.10.35'); # forward port 443 to 
 $B->forward(23 => '192.168.10.35:22'); # forward port 23 to ssh on  web sever

The main thing to know is that on entry to the script the global
variable $B will contain an initialized instance of a
Net::ISP::Balance object. You may then make method calls on this
object to emit firewall and routing rules. Please read the manual page
for Net::ISP::Balance for further information ("man
Net::ISP::Balance").

Calling the Script by Hand
==========================

You can invoke load_balance.pl from the command line to manually bring
up and down ISP services. The format is simple:

 /etc/network/load_balance.pl ISP1 ISP2 ISP3 ...

ISP1, etc are service names defined in the configuration file. All
ISPs indicated on the command line will be maked as "up", others will
not be used for load balancing. If no services are indicated on the
command line, then ALL the ISP services will be marked up initially
and lsm will be launched to monitor their connectivity periodically.

Adding a -d option will print the routing and firewall commands to
standard output for inspection.

How it Works
============

The script uses two tricks to balance. The first is to set up a
multipath default routing destination as described at
http://lartc.org/howto/lartc.rpdb.multiple-links.html

 ip route add default \
	nexthop via 206.250.80.122  dev ppp0 weight 1 \
	nexthop via 198.5.13.201    dev eth0 weight 1

This balances network sessions originating from the router, but does
not work for forwarded (NAT-ed) sessions from the LAN. To accomplish
the latter, the script uses a combination of ip routing tables for
outgoing connections, the firewall mark (fwmark) mechanism to select
tables, and the iptables "mangle" chain to randomly select which
ISP to use for outgoing connections:

 iptables -t mangle -A PREROUTING -i eth2 -m conntrack --ctstate NEW \
          -m statistic --mode random --probability 1 -j MARK-ISP1
 iptables -t mangle -A PREROUTING -i eth2 -m conntrack --ctstate NEW \
          -m statistic --mode random --probability 0.5 -j MARK-ISP2

This strategy is described at
https://home.regit.org/netfilter-en/links-load-balancing/.

License
=======

Perl Artistic License version 2.0
(http://www.perlfoundation.org/artistic_license_2_0).

Credits
=======

This package contains a slightly-modified version of Mika Ilmaranta's
<ilmis at nullnet.fi> Link Status Monitor (lsm) package. The original
source code can be fond at http://lsm.foobar.fi/.


Author
======

Lincoln D. Stein <lincoln.stein@gmail.com>
Senior Principal Investigator, Ontario Institute for Cancer Research
