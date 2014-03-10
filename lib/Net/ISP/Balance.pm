package Net::ISP::Balance;

use strict;
use Net::Netmask;
use IO::String;
use Carp 'croak','carp';

our $VERSION    = '1.01';

=head1 NAME

Net::ISP::Balance - Support load balancing across multiple internet service providers

=head1 SYNOPSIS

 use Net::ISP::Balance;

 # initialize the module with its configuration file
 my $bal = Net::ISP::Balance->new('/etc/network/balance.conf');

 $bal->verbose(1);    # verbosely print routing and firewall 
                      #  commands to STDERR before running them.
 $bal->echo_only(1);  # echo commands to STDOUT; don't execute them.

 # mark the balanced services that are up
 $bal->up('CABLE','DSL','SATELLITE');

 # write out routing and firewall commands
 $bal->set_routes_and_firewall();

 # write out a forwarding rule
 $bal->forward(80 => '192.168.10.35');  # forward web requests to this host

 # write out an arbitrary routing rule
 $bal->ip_route('add 192.168.100.1  dev eth0 src 198.162.1.14');

 # write out an arbitrary iptables rule
 $bal->iptables('-A INCOMING -p tcp --dport 6000 -j REJECT');

 # get information about all services
 my @s = $bal->service_names;
 for my $s (@s) {
    print $bal->dev($s);
    print $bal->ip($s);
    print $bal->gw($s);
    print $bal->net($s);
    print $bal->fwmark($s);
    print $bal->table($s);
    print $bal->running($s);
 }

=cut

use Carp;

=head1 FREQUENTLY-USED METHODS

Here are the class methods for this module that can be called on the
class name.

=head2 $bal = Net::ISP::Balance->new('/path/to/config_file.conf','/path/to/interfaces');

Creates a new balancer object. 

The first optional argument is the balancer configuration file, which
defaults to /etc/network/balance.conf on Ubuntu/Debian-derived
systems, and /etc/sysconfig/network-scripts/balance.conf on
RedHat/CentOS-derived systems. From hereon, we'll refer to the base of
the various configuration files as $ETC_NETWORK.

The second optional argument is the system network interfaces file,
defaulting to $ETC_NETWORK/interfaces.

=cut

sub new {
    my $class = shift;
    my ($conf,$interfaces,$dummy_test_data)  = @_;
    $conf       ||= $class->default_conf_file;
    $interfaces ||= $class->default_interface_file;
    $conf       && -r $conf       || croak 'Must provide a readable configuration file path';
    $interfaces && -r $interfaces || croak 'Must provide a readable network interfaces path';
    my $self  = bless {
	verbose   => 0,
	echo_only => 0,
	services  => {},
	rules_directory => $class->default_rules_directory,
	lsm_conf_file   => $class->default_lsm_conf_file,
	lsm_scripts_dir => $class->default_lsm_scripts_dir,
	bal_conf_file   => $conf,
	dummy_data=>$dummy_test_data,
    },ref $class || $class;

    $self->_parse_configuration_file($conf);
    $self->_collect_interfaces($interfaces);

    return $self;
}

=head2 $bal->set_routes_and_firewall

Once the Balance objecty is created, call set_routes_and_firewall() to
configure the routing tables and firewall for load balancing. These
rules will either be executed on the system, or printed to standard
output as a series of shell script commands if echo_only() is set to
true.

The routing tables and firewall rules are based on the configuration
described in balance.conf (usually /etc/network/balance.conf or
/etc/sysconfig/network-scripts/balance.conf). You may add custom
routes and rules by creating files in /etc/network/balance/routes and
/etc/network/balance/firewall
(/etc/sysconfig/network-scripts/balance/{routes,firewalls} on
RedHat/CentOS systems). The former contains a series of files or perl
scripts that define additional routing rules. The latter contains
files or perl scripts that define additional firewall rules.

Any files you put into these directories will be read in alphabetic
order and added to the routes and/or firewall rules emitted by the
load balancing script.Contained in this directory are subdirectories named "routes" and
"firewall". The former contains a series of files or perl scripts that
define additional routing rules. The latter contains files or perl
scripts that define additional firewall rules.

Any files you put into these directories will be read in alphabetic
order and added to the routes and/or firewall rules emitted by the
load balancing script.

A typical routing rules file will look like the example shown
below.

 # file: /etc/network/balance/01.my_routes
 ip route add 192.168.100.1  dev eth0 src 198.162.1.14
 ip route add 192.168.1.0/24 dev eth2 src 10.0.0.4

Each line will be sent to the shell, and it is intended (but not
required) that these be calls to the "ip" command. General shell
scripting constructs are not allowed here.

A typical firewall rules file will look like the example shown here:

 # file: /etc/network/firewall/01.my_firewall_rules

 # accept incoming telnet connections to the router
 iptable -A INPUT -p tcp --syn --dport telnet -j ACCEPT

 # masquerade connections to the DSL modem's control interface
 iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE

You may also insert routing and firewall rules via fragments of Perl
code, which is convenient because you don't have to hard-code any
network addresses and can make use of a variety of shortcuts. To do
this, simply end the file's name with .pl and make it executable.

Here's an example that defines a series of port forwarding rules for
incoming connections:

 # file: /etc/network/firewall/02.forwardings.pl 

 $B->forward(80 => '192.168.10.35'); # forward port 80 to internal web server
 $B->forward(443=> '192.168.10.35'); # forward port 443 to 
 $B->forward(23 => '192.168.10.35:22'); # forward port 23 to ssh on  web sever

The main thing to know is that on entry to the script the global
variable $B will contain an initialized instance of a
Net::ISP::Balance object. You may then make method calls on this
object to emit firewall and routing rules.

A typical routing rules file will look like the example shown
below.

 # file: /etc/network/balance/01.my_routes
 ip route add 192.168.100.1  dev eth0 src 198.162.1.14
 ip route add 192.168.1.0/24 dev eth2 src 10.0.0.4

Each line will be sent to the shell, and it is intended (but not
required) that these be calls to the "ip" command. General shell
scripting constructs are not allowed here.

A typical firewall rules file will look like the example shown here:

 # file: /etc/network/firewall/01.my_firewall_rules

 # accept incoming telnet connections to the router
 iptable -A INPUT -p tcp --syn --dport telnet -j ACCEPT

 # masquerade connections to the DSL modem's control interface
 iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE

You may also insert routing and firewall rules via fragments of Perl
code, which is convenient because you don't have to hard-code any
network addresses and can make use of a variety of shortcuts. To do
this, simply end the file's name with .pl and make it executable.

Here's an example that defines a series of port forwarding rules for
incoming connections:

 # file: /etc/network/firewall/02.forwardings.pl 

 $B->forward(80 => '192.168.10.35'); # forward port 80 to internal web server
 $B->forward(443=> '192.168.10.35'); # forward port 443 to 
 $B->forward(23 => '192.168.10.35:22'); # forward port 23 to ssh on  web sever

The main thing to know is that on entry to the script the global
variable $B will contain an initialized instance of a
Net::ISP::Balance object. You may then make method calls on this
object to emit firewall and routing rules.

=cut

sub set_routes_and_firewall {
    my $self = shift;
    $self->enable_forwarding(0);
    $self->set_routes();
    $self->set_firewall();
    $self->enable_forwarding(1);
}

=head2 $verbose = $bal->verbose([boolean]);

sub bal_conf_file { my $self = shift; my $d = $self->{bal_conf_file};
$self->{bal_conf_file} = shift if @_; $d; } Get/set verbosity of
the module. If verbose is true, then firewall and routing rules
will be echoed to STDERR before being executed on the system.

=cut

sub verbose {
    my $self = shift;
    my $d    = $self->{verbose};
    $self->{verbose} = shift if @_;
    $d;
}

=head2 $echo = $bal->echo_only([boolean]);

Get/set the echo_only flag. If this is true (default false), then
routing and firewall rules will be printed to STDOUT rathar than being
executed.

=cut

sub echo_only {
    my $self = shift;
    my $d    = $self->{echo_only};
    $self->{echo_only} = shift if @_;
    $d;
}

=head2 $result_code = $bal->sh(@args)

Pass @args to the shell for execution. If echo_only() is set to true,
the command will not be executed, but instead be printed to standard
output.

Example:

 $bal->sh('ip rule flush');

The result code is the same as CORE::system().

=cut

sub sh {
    my $self = shift;
    my @args  = @_;
    my $arg   = join ' ',@args;
    chomp($arg);
    carp $arg   if $self->verbose;
    if ($self->echo_only) {
	$arg .= "\n";
	print $arg;
    } else {
	system $arg;
    }
}

=head2 $bal->iptables(@args), but not executed.

Invoke sh() to call "iptables @args". 

Example:

 $bal->iptables('-A OUTPUT -o eth0 -j DROP');

You may pass an array reference to iptables(), in which case iptables
is called on each member of the array in turn.

Example:

 $bal->iptables(['-P OUTPUT  DROP',
                 '-P INPUT   DROP',
                 '-P FORWARD DROP']);

Note that the method keeps track of rules; if you try to enter the
same iptables rule more than once the redundant ones will be ignored.

=cut

my %seen_rule;

sub iptables {
    my $self = shift;
    if (ref $_[0] eq 'ARRAY') {
	$seen_rule{$_}++ || $self->sh('iptables',$_) foreach @{$_[0]};
    } else {
	$seen_rule{"@_"} || $self->sh('iptables',@_)
    }
}

=head2 $bal->forward($incoming_port,$destination_host,@protocols)

This method emits appropriate port/host forwarding rules. Destination host can
accept any of these forms:

  192.168.100.1       # forward to same port as incoming
  192.168.100.1:8080  # forward to a different port on host

Protocols are one or more of 'tcp','udp'. If omitted  defaults to tcp.

Examples:
  
    $bal->forward(80 => '192.168.100.1');
    $bal->forward(80 => '192.168.100.1:8080','tcp');

=cut

sub forward {
    my $self = shift;
    my ($port,$host,@protocols) = @_;
    @protocols = ('tcp') unless @protocols;

    my ($dhost,$dport)   = split ':',$host;
    $dhost         ||= $host;
    $dport         ||= $port;

    my @dev = map {$self->dev($_)} $self->isp_services;

    for my $dev (@dev) {
	for my $protocol (@protocols) {
	    $self->iptables("-t nat -A PREROUTING -i $dev -p $protocol --dport $port -j DNAT --to-destination $host");
	    for my $lan ($self->lan_services) {
		my $landev = $self->dev($lan);
		my $lannet = $self->net($lan);
		my $lanip  = $self->ip($lan);
		my $syn    = $protocol eq 'tcp' ? '--syn' : '';
		$self->iptables("-A FORWARD -p $protocol -o $landev $syn -d $dhost --dport $dport -j ACCEPT");
#		$self->iptables("-t nat -A POSTROUTING -p $protocol -d $dhost -o $landev --dport $dport -j SNAT --to $lanip");
	    }
	}
    }
}

=head2 $bal->ip_route(@args)

Shortcut for $bal->sh('ip route',@args);

=cut

sub ip_route {shift->sh('ip','route',@_)}

=head2 $bal->ip_rule(@args)

Shortcut for $bal->sh('ip rule',@args);

=cut

sub ip_rule {shift->sh('ip','rule',@_)}

=head2 $verbose = $bal->iptables_verbose([boolean])

Makes iptables send an incredible amount of debugging information to
syslog.

=cut

sub iptables_verbose {
    my $self = shift;
    my $d    = $self->{iptables_verbose};
    $self->{iptables_verbose} = shift if @_;
    $d;
}

=head1 QUERYING THE CONFIGURATION

These methods allow you to get information about the Net::ISP::Balance
object's configuration, including settings and other characteristics
of the various network interfaces.

=head2 @names = $bal->service_names

Return the list of service names defined in balance.conf.

=cut

sub service_names {
    my $self = shift;
    my $s    = $self->services;
    return keys %$s;
}

=head2 @names = $bal->isp_services

Return list of service names that correspond to load-balanced ISPs.

=cut

sub isp_services {
    my $self = shift;
    my @n    = $self->service_names;
    return grep {$self->role($_) eq 'isp'} @n;
}

=head2 @names = $bal->lan_services

Return list of service names that correspond to lans.


=cut

sub lan_services {
    my $self = shift;
    my @n    = $self->service_names;
    return grep {$self->role($_) eq 'lan'} @n;
}

=head2 @up = $bal->up(@up_services)

Get or set the list of ISP interfaces that are currently active and
should be used for balancing.

=cut

sub up {
    my $self = shift;
    unless ($self->{up}) { # initialize with running services
	my @svc = grep {$self->running($_)} $self->isp_services;
	$self->{up} = \@svc;
    }
    my @up = @{$self->{up}};
    $self->{up} = \@_ if @_;
    return @up;
}

=head2 $services = $bal->services

Return a hash containing the configuration information for  each
service. The keys are the service names. Here's an example:

 {
 0  HASH(0x91201e8)
   'CABLE' => HASH(0x9170500)
      'dev' => 'eth0'
      'fwmark' => 2
      'gw' => '191.3.88.1'
      'ip' => '191.3.88.152'
      'net' => '191.3.88.128/27'
      'ping' => 'www.google.ca'
      'role' => 'isp'
      'running' => 1
      'table' => 2
   'DSL' => HASH(0x9113e00)
      'dev' => 'ppp0'
      'fwmark' => 1
      'gw' => '112.211.154.198'
      'ip' => '11.120.199.108'
      'net' => '112.211.154.198/32'
      'ping' => 'www.google.ca'
      'role' => 'isp'
      'running' => 1
      'table' => 1
   'LAN' => HASH(0x913ce58)
      'dev' => 'eth1'
      'fwmark' => undef
      'gw' => '192.168.10.1'
      'ip' => '192.168.10.1'
      'net' => '192.168.10.0/24'
      'ping' => ''
      'role' => 'lan'
      'running' => 1
 }

=cut

sub services { return shift->{services} }

=head2 $service = $bal->service('CABLE')

Return the subhash describing the single named service (see services()
above).

=cut

sub service {
    shift->{services}{shift()};
}

=head2 $dev = $bal->dev('CABLE')

=head2 $ip = $bal->ip('CABLE')

=head2 $gateway = $bal->gw('CABLE')

=head2 $network = $bal->net('CABLE')

=head2 $role = $bal->role('CABLE')

=head2 $running = $bal->running('CABLE')

=head2 $mark_number = $bal->fwmark('CABLE')

=head2 $routing_table_number = $bal->table('CABLE')

=head2 $ping_dest   = $bal->ping('CABLE')

These methods pull out the named information from the configuration
data. fwmark() returns a small integer that will be used for marking
connections for routing through one of the ISP connections when an
outgoing connection originates on the LAN and is routed through the
router. table() returns a small integer corresponding to a routing
table used to route connections originating on the router itself.

=cut

sub dev { shift->_service_field(shift,'dev') }
sub ip  { shift->_service_field(shift,'ip')  }
sub gw  { shift->_service_field(shift,'gw')  }
sub net { shift->_service_field(shift,'net')  }
sub running { shift->_service_field(shift,'running')  }
sub role   { shift->_service_field(shift,'role')  }
sub fwmark { shift->_service_field(shift,'fwmark')  }
sub table { shift->_service_field(shift,'table')  }
sub ping   { shift->_service_field(shift,'ping')  }

sub _service_field {
    my $self = shift;
    my ($service,$field) = @_;
    my $s = $self->{services}{$service} or return;
    $s->{$field};
}

=head1 FILES AND PATHS

These are methods that determine where Net::ISP::Balance finds its
configuration files.

=head2 $path = Net::ISP::Balance->install_etc

Returns the path to where the network configuration files reside on
this system, e.g. /etc/network. Note that this only knows about
Ubuntu/Debian-style network configuration files in /etc/network, and
RedHat/CentOS network configuration files in
/etc/sysconfig/network-scripts.

=cut

sub install_etc {
    my $self = shift;
    return '/etc/network'                    if -d '/etc/network';
    return '/etc/sysconfig/network-scripts'  if -d '/etc/sysconfig/network-scripts';
    return '/etc';
}

=head2 $file = Net::ISP::Balance->default_conf_file

Returns the path to the default configuration file,
$ETC_NETWORK/balance.conf.

=cut

sub default_conf_file {
    my $self = shift;
    return $self->install_etc.'/balance.conf';
}

=head2 $file_or_dir = Net::ISP::Balance->default_interface_file

Returns the path to the place where the system stores its network
configuration information. On Ubuntu/Debian-derived systems, this will
be the file /etc/network/interfaces. On RedHad/CentOS-derived systems,
this is the directory named /etc/sysconfig/network-scripts/ which
contains a series of ifcfg-* files.

=cut

sub default_interface_file {
    my $self = shift;
    return '/etc/network/interfaces'        if -d '/etc/network';
    return '/etc/sysconfig/network-scripts' if -d '/etc/sysconfig/network-scripts';
    die "I don't know where to find network interface configuration files on this system";
}

=head2 $dir = Net::ISP::Balance->default_rules_directory

Returns the path to the directory where the additional router and
firewall rules are stored. On Ubuntu-Debian-derived systems, this is
/etc/network/balance/. On RedHat/CentOS systems, this is
/etc/sysconfig/network-scripts/balance/.

=cut

sub default_rules_directory {
    my $self = shift;
    return $self->install_etc."/balance";
}

=head2 $file = Net::ISP::Balance->default_lsm_conf_file

Returns the path to the place where we should store lsm.conf, the file
used to configure the lsm (link status monitor) application.

On Ubuntu/Debian-derived systems, this will be the file
/etc/network/lsm.conf. On RedHad/CentOS-derived systems, this will be
/etc/sysconfig/network-scripts/lsm.conf.

=cut

sub default_lsm_conf_file {
    my $self = shift;
    return $self->install_etc."/lsm.conf";
}

=head2 $dir = Net::ISP::Balance->default_lsm_scripts_dir

Returns the path to the place where lsm stores its helper scripts.  On
Ubuntu/Debian-derived systems, this will be the directory
/etc/network/lsm/. On RedHad/CentOS-derived systems, this will be
/etc/sysconfig/network-scripts/lsm/.

=cut

sub default_lsm_scripts_dir {
    my $self = shift;
    return $self->install_etc.'/lsm/';
}

=head2 $file = $bal->bal_conf_file([$new_file])

Get/set the main configuration file path, balance.conf.

=cut

sub bal_conf_file {
    my $self = shift;
    my $d   = $self->{bal_conf_file};
    $self->{bal_conf_file} = shift if @_;
    $d;
}

=head2 $dir = $bal->rules_directory([$new_rules_directory])

Get/set the route and firewall rules directory.

=cut

sub rules_directory {
    my $self = shift;
    my $d   = $self->{rules_directory};
    $self->{rules_directory} = shift if @_;
    $d;
}

=head2 $file = $bal->lsm_conf_file([$new_conffile])

Get/set the path to the lsm configuration file.

=cut

sub lsm_conf_file {
    my $self = shift;
    my $d   = $self->{lsm_conf_file};
    $self->{lsm_conf_file} = shift if @_;
    $d;
}

=head2 $dir = $bal->lsm_scripts_dir([$new_dir])

Get/set the path to the lsm scripts directory.

=cut

sub lsm_scripts_dir {
    my $self = shift;
    my $d   = $self->{lsm_scripts_dir};
    $self->{lsm_scripts_dir} = shift if @_;
    $d;
}

=head1 INFREQUENTLY-USED METHODS

These are methods that are used internally, but may be useful to
applications developers.

=head2 $lsm_config_text = $bal->lsm_config_file(-warn_email=>'root@localhost')

This method creates the text used to create the lsm.conf configuration
file. Pass it a series of -name=>value pairs to incorporate into the
file.

Possible switches and their defaults are:

    -checkip                    127.0.0.1
    -eventscript                /etc/network/lsm/balancer_event_script
    -notifyscript               /etc/network/lsm/default_script
    -max_packet_loss            15
    -max_successive_pkts_lost    7
    -min_packet_loss             5
    -min_successive_pkts_rcvd   10
    -interval_ms              1000
    -timeout_ms               1000
    -warn_email               root
    -check_arp                   0
    -sourceip                 <autodiscovered>
    -device                   <autodiscovered>
    -ttl                      0 <use system value>
    -status                   2 <no assumptions>
    -debug                    8 <moderate verbosity from scale of 0 to 100>

=cut

sub lsm_config_text {
    my $self = shift;
    my %args = @_;
    my $scripts_dir = $self->lsm_scripts_dir;
    my %defaults = (
                      -checkip              => '127.0.0.1',
                      -debug                => 8,
                      -eventscript          => "$scripts_dir/balancer_event_script",
                      -notifyscript         => "$scripts_dir/default_script",
                      -max_packet_loss      => 15,
                      -max_successive_pkts_lost =>  7,
                      -min_packet_loss          =>  5,
                      -min_successive_pkts_rcvd =>  10,
                      -interval_ms              => 1000,
                      -timeout_ms               => 1000,
                      -warn_email               => 'root',
                      -check_arp                =>  0,
                      -sourceip                 => undef,
                      -device                   => undef,
                      -ttl                      => 0,
                      -status                   => 2
	);
    %defaults = (%defaults,%{$self->{lsm_config}},%args);  # %args supersedes what's in %defaults

    my $result = "# This file is autogenerated by load_balancer.pl when it first runs.\n";
    $result   .= "# Do not edit directly. Instead edit /etc/network/balance.conf.\n\n";
    $result   .= "debug=$defaults{-debug}\n\n";
    delete $defaults{-debug};

    $result .= "defaults {\n";
    $result .= " name=defaults\n";
    for my $option (sort keys %defaults) {
	(my $o = $option) =~ s/^-//;
	$defaults{$option} = '' unless defined $defaults{$option}; # avoid uninit var warnings
	$result .= " $o=$defaults{$option}\n";
    }
    $result .= "}\n\n";

    for my $svc ($self->isp_services) {
	my $device = $self->dev($svc);
	my $src_ip = $self->ip($svc);
	my $ping   = $self->ping($svc);
	$result .= "connection {\n";
	$result .= " name=$svc\n";
	$result .= " device=$device\n";
	$result .= " sourceip=$src_ip\n";
	$result .= " checkip=$ping\n";
	$result .= "}\n\n";
    }

    return $result;
}

sub _parse_configuration_file {
    my $self = shift;
    my $path = shift;
    my (%services,%lsm_options);
    open my $f,$path or die "Could not open $path: $!";
    while (<$f>) {
	chomp;
	next if /^\s*#/;
	if (/^(\w+)\s*=\s*(.*)$/) { # lsm config
	    $lsm_options{"-${1}"} = $2;
	    next;
	}
	my ($service,$device,$role,$ping_dest) = split /\s+/;
	next unless $service && $device && $role;
	$services{$service}{dev}=$device;
	$services{$service}{role}=$role;
	$services{$service}{ping}=$ping_dest;
    }
    close $f;
    $self->{svc_config}=\%services;
    $self->{lsm_config}=\%lsm_options;
}

sub _collect_interfaces {
    my $self = shift;
    my $interfaces = shift;
    my $s    = $self->{svc_config} or return;

    my ($iface_type,$gateways) = -f $interfaces ? $self->_get_debian_ifcfg($interfaces)   # 'network/interfaces' file
                                                : $self->_get_centos_ifcfg($interfaces);  # 'network-scripts/ifcfg-*' files
                               
    my (%ifaces,%devs);

    # map devices to services
    for my $svc (keys %$s) {
	my $dev = $s->{$svc}{dev};
	$devs{$dev}=$svc;
    }

    my $counter = 0;
    for my $dev (keys %$iface_type) {
	my $svc     = $devs{$dev} or next;
	my $role  = $svc ? $s->{$svc}{role} : '';
	my $type  = $iface_type->{$dev};
	my $info = $type eq 'static' ? $self->get_static_info($dev,$gateways->{$dev})
	          :$type eq 'dhcp'   ? $self->get_dhcp_info($dev)
	          :$type eq 'ppp'    ? $self->get_ppp_info($dev)
		  :undef;
	$info ||= {dev=>$dev,running=>0}; # not running
	$info or die "Couldn't figure out how to get info from $dev";
	if ($role eq 'isp') {
	    $counter++;
	    $info->{fwmark} = $counter;
	    $info->{table}  = $counter;
	}
	# next unless $info->{running};  # maybe we should do this?
	$info->{ping} = $s->{$svc}{ping};
	$info->{role} = $role;
	$ifaces{$svc}=$info;
    }
    $self->{services} = \%ifaces;
}

sub _get_debian_ifcfg {
    my $self = shift;
    my $interfaces = shift;

    my (%iface_type,%gw,$lastdev);
    
    # use /etc/network/interfaces to figure out what kind of
    # device each is.
    open my $f,$interfaces or die "$interfaces: $!";
    while (<$f>) {
	chomp;
	if (/^\s*iface\s+(\w+)\s+inet\s+(\w+)/) {
	    $iface_type{$1} = $2;
	    $lastdev        = $1;
	}
	if (/^\s*gateway\s+(\S+)/ && $lastdev) {
	    $gw{$lastdev}   = $1;
	}
    }
    close $f;
    return (\%iface_type,\%gw);
}

sub _get_centos_ifcfg {
    my $self = shift;
    my $interfaces = shift;

    my (%ifcfg,%iface_type,%gw);

    # collect all "ifcfg-* files";
    opendir my $dh,$interfaces or die "Can't open $interfaces for reading: $!";
    while (my $entry = readdir($dh)) {
	next if $entry =~ /^\./;
	next unless $entry =~ /ifcfg-(?:Auto_)?(\w+)$/;
	$ifcfg{$entry} = $1;
    }
    closedir $dh;
    for my $entry (keys %ifcfg) {
	my $file = "$interfaces/$entry";
	my $dev  = $ifcfg{$entry};
	my $realdevice;
	open my $fh,$file or die "$file: $!";
	while (<$fh>) {
	    chomp;
	    if (/^GATEWAY\s*=\s*(\S+)/) {
		$gw{$dev}=$1;
	    }
	    if (/^BOOTPROTO\s*=\s*(\w+)/) {
		$iface_type{$dev} = $1 eq 'dhcp' ? 'dhcp' : 'static';
	    }
	    if (/^DEVICE\s*=\s*(\w+)/) {
		$realdevice = $1;
	    }
	}
	$iface_type{$dev} = 'ppp' if $dev =~ /^ppp\d+/;  # hack 'cause no other way to figure it out
	close $fh;

	# I don't know if this can happen in RHL/CentOS, but ifcfg* files can
	# have a DEVICE entry that may not necessarily match the file name. Arrrgh!
	if ($realdevice && $realdevice ne $dev) {
	    $iface_type{$realdevice}=$iface_type{$dev};
	    $gw{$realdevice}=$gw{$realdevice};
	    delete $iface_type{$dev};
	    delete $gw{$dev};
	}

    }

    return (\%iface_type,\%gw);
}

=head2 $info = $bal->get_ppp_info($dev)

This nmethod returns a hashref containing information about a PPP
network interface device, including IP address, gateway, network, and
netmask. The $dev argument is a standard Linux network device name
such as "ppp0".

=cut

sub get_ppp_info {
    my $self     = shift;
    my $device   = shift;
    my $ifconfig = $self->_ifconfig($device) or return;
    my ($ip)     = $ifconfig =~ /inet addr:(\S+)/;
    my ($peer)   = $ifconfig =~ /P-t-P:(\S+)/;
    my ($mask)   = $ifconfig =~ /Mask:(\S+)/;
    my $up       = $ifconfig =~ /^\s+UP\s/m;
    my $block    = Net::Netmask->new($peer,$mask);
    return {running  => $up,
	    dev => $device,
	    ip  => $ip,
	    gw  => $peer,
	    net => "$block",
	    fwmark => undef,};
}

=head2 $info = $bal->get_static_info($deb)

This nmethod returns a hashref containing information about a
statically-defined network interface device, including IP address,
gateway, network, and netmask. The $dev argument is a standard Linux
network device name such as "etho0".

=cut


sub get_static_info {
    my $self     = shift;
    my ($device,$gw) = @_;
    my $ifconfig = $self->_ifconfig($device) or return;
    my ($addr)   = $ifconfig =~ /inet addr:(\S+)/;
    my $up       = $ifconfig =~ /^\s+UP\s/m;
    my ($mask)   = $ifconfig =~ /Mask:(\S+)/;
    my $block    = Net::Netmask->new($addr,$mask);
    return {running  => $up,
	    dev => $device,
	    ip  => $addr,
	    gw  => $gw || $block->nth(1),
	    net => "$block",
	    fwmark => undef,};
}

=head2 $info = $bal->get_dhcp_info($deb)

This nmethod returns a hashref containing information about a network
interface device that is configured via dhcp, including IP address,
gateway, network, and netmask. The $dev argument is a standard Linux
network device name such as "eth0".

=cut

sub get_dhcp_info {
    my $self     = shift;
    my $device   = shift;
    my $fh       = $self->_open_dhclient_leases($device) or die "Can't find lease file for $device";
    my $ifconfig = $self->_ifconfig($device)             or die "Can't ifconfig $device";

    my ($ip,$gw,$netmask);
    while (<$fh>) {
	chomp;

	if (/fixed-address (\S+);/) {
	    $ip = $1;
	    next;
	}
	
	if (/option routers (\S+)[,;]/) {
	    $gw = $1;
	    next;
	}

	if (/option subnet-mask (\S+);/) {
	    $netmask = $1;
	    next;
	}
    }

    die "Couldn't find all required information" 
	unless defined($ip) && defined($gw) && defined($netmask);

    my $up       = $ifconfig =~ /^\s+UP\s/m;
    my $block = Net::Netmask->new($ip,$netmask);
    return {running  => $up,
	    dev => $device,
	    ip  => $ip,
	    gw  => $gw,
	    net => "$block",
	    fwmark => undef,
    };
}

=head2 $path = $bal->find_dhclient_leases($dev)

This method finds the dhclient configuration file corresponding to
DHCP-managed device $dev. The device is a standard device name such as
"eth0".

=cut

sub find_dhclient_leases {
    my $self     = shift;
    my $device = shift;
    my @locations = ('/var/lib/NetworkManager','/var/lib/dhcp','/var/lib/dhclient');
    for my $l (@locations) {
	my @matches = glob("$l/dhclient*$device.lease*");
	next unless @matches;
	return $matches[0];
    }
    return;
}

sub _open_dhclient_leases {
    my $self = shift;
    my $device = shift;
    if (my $dummy = $self->{dummy_data}{"leases_$device"}) {
	return IO::String->new($dummy);
    }
    my $leases = $self->find_dhclient_leases($device) or die "Can't find lease file for $device";
    open my $fh,$leases or die "Can't open $leases: $!";
    return $fh;
}

sub _ifconfig {
    my $self   = shift;
    my $device = shift;
    if (my $dummy = $self->{dummy_data}{"ifconfig_$device"}) {
	return $dummy;
    }
    return `ifconfig $device`;
}

#################################### here are the routing rules ###################

=head2 $bal->set_routes()

This method is called by set_routes_and_firewall() to emit the rules
needed to create the load balancing routing tables.

=cut

sub set_routes {
    my $self = shift;
    $self->routing_rules();
    $self->local_routing_rules();
}

=head2 $bal->set_firewall

This method is called by set_routes_and_firewall() to emit the rules
needed to create the balancing firewall.

=cut

sub set_firewall {
    my $self = shift;
    $self->base_fw_rules();
    $self->balancing_fw_rules();
    $self->sanity_fw_rules();
    $self->nat_fw_rules();
    $self->local_fw_rules();
}


=head2 $bal->enable_forwarding($boolean)

=cut

sub enable_forwarding {
    my $self = shift;
    my $enable = $_[0] ? 1 : 0;
    $self->sh("echo $enable > /proc/sys/net/ipv4/ip_forward");
}
=head2 $bal->routing_rules()

This method is called by set_routes() to emit the rules
needed to create the routing rules.

=cut

sub routing_rules {
    my $self = shift;
    $self->_initialize_routes();
    $self->_create_default_route();
    $self->_create_service_routing_tables();
}

sub _initialize_routes {
    my $self  = shift;
    $self->sh(<<END);
ip route flush all
ip rule flush
ip rule add from all lookup main pref 32766
ip rule add from all lookup default pref 32767
END
    ;

    $self->ip_route("flush table ",$self->table($_)) foreach $self->isp_services;

    # main table
    $self->ip_route("add ",$self->net($_),'dev',$self->dev($_),'src',$self->ip($_)) foreach $self->service_names;
}

sub _create_default_route {
    my $self = shift;
    my $D    = shift;

    my @up = $self->up;

    # create multipath route
    if (@up > 1) { # multipath
	print STDERR "# setting multipath default gw\n" if $self->verbose;
	# EG
	# ip route add default scope global nexthop via 192.168.10.1 dev eth0 weight 1 \
	#                                   nexthop via 192.168.11.1 dev eth1 weight 1
	my $hops = '';
	for my $svc (@up) {
	    my $gw  = $self->gw($svc)  or next;
	    my $dev = $self->dev($svc) or next;
	    $hops  .= "nexthop via $gw dev $dev weight 1 ";
	}
	die "no valid gateways!" unless $hops;
	$self->ip_route("add default scope global $hops");
    } 

    else {
	print STDERR "# setting single default route via $up[0]n" if $self->verbose;
	$self->ip_route("add default via",$self->gw($up[0]),'dev',$self->dev($up[0]));
    }

}

sub _create_service_routing_tables {
    my $self = shift;

    for my $svc ($self->isp_services) {
	print STDERR "# creating routing table for $svc\n" if $self->verbose;
	$self->ip_route('add table',$self->table($svc),'default dev',$self->dev($svc),'via',$self->gw($svc));
	for my $s ($self->service_names) {
	    $self->ip_route('add table',$self->table($svc),$self->net($s),'dev',$self->dev($s),'src',$self->ip($s));
	}
	$self->ip_rule('add from',$self->ip($svc),'table',$self->table($svc));
	$self->ip_rule('add fwmark',$self->fwmark($svc),'table',$self->table($svc));
    }
}

=head2 $bal->local_routing_rules()

This method is called by set_routes() to process the fules and emit
the commands contained in the customized route files located in
$ETC_DIR/balance/routes.

=cut

sub local_routing_rules {
    my $self = shift;
    my $dir  = $self->rules_directory;
    my @files = sort glob("$dir/routes/*");
    $self->_execute_rules_files(@files);
}

=head2 $bal->local_fw_rules()

This method is called by set_firewall() to process the fules and emit
the commands contained in the customized route files located in
$ETC_DIR/balance/firewall.

=cut

sub local_fw_rules {
    my $self = shift;
    my $dir  = $self->rules_directory;
    my @files = sort glob("$dir/firewall/*");
    $self->_execute_rules_files(@files);
}

sub _execute_rules_files {
    my $self = shift;
    my @files = @_;

    for my $f (@files) {
	print STDERR "# executing contents of $f\n" if $self->verbose;
	next if $f =~ /(~|\.bak)$/ or $f=~/^#/;

	if ($f =~ /\.pl$/) {  # perl script
	    our $B = $self;
	    do $f;
	    warn $@ if $@;
	} else {
	    open my $fh,$f or die "Couldn't open $f: $!";
	    $self->sh($_) while <$fh>;
	    close $fh;
	}
    }
}

#########################
# firewall rules
#########################

=head2 $bal->base_fw_rules()

This method is called by set_firewall() to set up basic firewall
rules, including default rules and reporting.

=cut

sub base_fw_rules {
    my $self = shift;
    $self->sh(<<END);
iptables -F
iptables -t nat    -F
iptables -t mangle -F
iptables -X
iptables -P INPUT    DROP
iptables -P OUTPUT   DROP
iptables -P FORWARD  DROP

iptables -N DROPGEN
iptables -A DROPGEN -j LOG -m limit --limit 1/minute --log-level 4 --log-prefix "GENERAL: "
iptables -A DROPGEN -j DROP

iptables -N DROPINVAL
iptables -A DROPINVAL -j LOG -m limit --limit 1/minute --log-level 4 --log-prefix "INVALID: "
iptables -A DROPINVAL -j DROP

iptables -N DROPPERM
iptables -A DROPPERM -j LOG -m limit --limit 1/minute --log-level 4 --log-prefix "ACCESS-DENIED: "
iptables -A DROPPERM -j DROP

iptables -N DROPSPOOF
iptables -A DROPSPOOF -j LOG -m limit --limit 1/minute --log-level 4 --log-prefix "DROP-SPOOF: "
iptables -A DROPSPOOF -j DROP

iptables -N DROPFLOOD
iptables -A DROPFLOOD -m limit --limit 1/minute  -j LOG --log-level 4 --log-prefix "DROP-FLOOD: "
iptables -A DROPFLOOD -j DROP

iptables -N DEBUG
iptables -A DEBUG  -j LOG --log-level 3 --log-prefix "DEBUG: "
END
;
    if ($self->iptables_verbose) {
	print STDERR " #Setting up debugging logging\n" if $self->verbose;
	$self->sh(<<END);	
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
}

=head2 $bal->balancing_fw_rules()

This method is called by set_firewall() to set up the mangle/fwmark
rules for balancing outgoing connections.

=cut 

sub balancing_fw_rules {
    my $self = shift;

    print STDERR "# balancing FW rules\n" if $self->verbose;

    for my $svc ($self->isp_services) {
	my $table = "MARK-${svc}";
	my $mark  = $self->fwmark($svc);
	next unless defined $mark && defined $table;
	$self->sh(<<END);
iptables -t mangle -N $table
iptables -t mangle -A $table -j MARK     --set-mark $mark
iptables -t mangle -A $table -j CONNMARK --save-mark
END
    }

    my @up = $self->up;

    # packets from LAN
    for my $lan ($self->lan_services) {
	my $landev = $self->dev($lan);
	
	if (@up > 1) {
	    print STDERR "# creating balanced mangling rules\n" if $self->verbose;
	    my $count = @up;
	    my $i = 1;
	    for my $svc (@up) {
		my $table = "MARK-${svc}";
		my $probability = 1/$i++; # 1, 1/2, 1/3, 1/4...
		$self->iptables("-t mangle -A PREROUTING -i $landev -m conntrack --ctstate NEW -m statistic --mode random --probability $probability -j $table");
	    }
	}

	else {
	    my $svc = $up[0];
	    print STDERR "# forcing all traffic through $svc\n" if $self->verbose;
	    $self->iptables("-t mangle -A PREROUTING -i $landev -m conntrack --ctstate NEW -j MARK-${svc}");
	}

	$self->iptables("-t mangle -A PREROUTING -i $landev -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark");
    }

    # inbound packets from WAN
    for my $wan ($self->isp_services) {
	my $dev = $self->dev($wan);
	$self->iptables("-t mangle -A PREROUTING -i $dev -m conntrack --ctstate NEW -j MARK-${wan}");
	$self->iptables("-t mangle -A PREROUTING -i $dev -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark");
    }

}

=head2 $bal->sanity_fw_rules()

This is called by set_firewall() to create a sensible series of
firewall rules that seeks to prevent spoofing, flooding, and other
antisocial behavior. It also enables UDP-based network time and domain
name service.

=cut

sub sanity_fw_rules {
    my $self = shift;

    # if any of the devices are ppp, then we clamp the mss
    my @ppp_devices = grep {/ppp\d+/} map {$self->dev($_)} $self->isp_services;
    $self->iptables("-t mangle -A POSTROUTING -o $_ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu")
	foreach @ppp_devices;

    # lo is ok
    $self->iptables(['-A INPUT  -i lo -j ACCEPT',
		     '-A OUTPUT -o lo -j ACCEPT',
		     '-A INPUT -d 127.0.0.0/8 -j DROPPERM']);

    # accept continuing foreign traffic
    $self->iptables(['-A INPUT   -m state --state ESTABLISHED,RELATED -j ACCEPT',
		     '-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT',
		     '-A INPUT   -p tcp --tcp-flags SYN,ACK ACK -j ACCEPT',
		     '-A FORWARD -p tcp --tcp-flags SYN,ACK ACK -j ACCEPT',
		     '-A FORWARD -p tcp --tcp-flags SYN,ACK,FIN,RST RST -j ACCEPT'
		    ]);

    # we allow ICMP echo, but establish flood limits
    $self->iptables(['-A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT',
		     '-A INPUT -p icmp --icmp-type echo-request -j DROPFLOOD']);

    # establish expected traffic patterns between lan(s) and other interfaces
    for my $lan ($self->lan_services) {
	my $dev = $self->dev($lan);
	my $net = $self->net($lan);
	# allow unlimited traffic from internal network using legit address	
	$self->iptables("-A INPUT   -i $dev -s $net -j ACCEPT");

	# allow locally-generated output to the LAN on the LANDEV
	$self->iptables("-A OUTPUT  -o $dev -d $net  -j ACCEPT");
	# and allow broadcasts to the lan
	$self->iptables("-A OUTPUT  -o $dev -d 255.255.255.255/32  -j ACCEPT");

	# any outgoing udp packet is fine with me
	$self->iptables("-A OUTPUT  -p udp -s $net -j ACCEPT");

	# allow domain and time services
	$self->iptables(['-A INPUT   -p udp --source-port domain -j ACCEPT',
			 "-A FORWARD -p udp --source-port domain -d $net -j ACCEPT"]);

	# time
	$self->iptables(['-A INPUT   -p udp --source-port ntp -j ACCEPT',
			 "-A FORWARD -p udp --source-port ntp -d $net -j ACCEPT"]);

	# lan/wan forwarding
	# allow lan/wan forwarding
	for my $svc ($self->isp_services) {
	    my $ispdev = $self->dev($svc);
	    $self->iptables(["-A FORWARD  -i $dev -o $ispdev -s $net ! -d $net -j ACCEPT",
			     "-A OUTPUT   -o $ispdev                 ! -d $net -j ACCEPT"]);
	}
    }

    # allow forwarding between lans
    my @lans = $self->lan_services;
    for (my $i=0;$i<@lans;$i++) {
	my $lan1 = $lans[$i];
	my $lan2 = $lans[$i+1];
	next unless $lan2;
	$self->iptables('-A FORWARD -i',$self->dev($lan1),'-o',$self->dev($lan2),'-s',$self->net($lan1),'-j ACCEPT');
	$self->iptables('-A FORWARD -o',$self->dev($lan1),'-i',$self->dev($lan2),'-s',$self->net($lan2),'-j ACCEPT');
    }

    # anything else is bizarre and should be dropped
    $self->iptables('-A OUTPUT  -j DROPSPOOF');
}

=head2 $bal->nat_fw_rules()

This is called by set_firewall() to set up basic NAT rules for lan traffic over ISP

=cut

sub nat_fw_rules {
    my $self = shift;
    $self->iptables('-t nat -A POSTROUTING -o',$self->dev($_),'-j MASQUERADE')
	foreach $self->isp_services;
}

1;

=head1 BUGS

Please report bugs to GitHub: https://github.com/lstein/Net-ISP-Balance.

=head1 AUTHOR

Copyright 2014, Lincoln D. Stein (lincoln.stein@gmail.com)

Senior Principal Investigator,
Ontario Institute for Cancer Research

=head1 LICENSE

This package is distributed under the terms of the Perl Artistic
License 2.0. See http://www.perlfoundation.org/artistic_license_2_0.

=cut

__END__
