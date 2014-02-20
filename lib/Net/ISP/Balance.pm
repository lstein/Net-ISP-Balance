package Net::ISP::Balance;

use strict;
use Net::Netmask;
use IO::String;
use Carp 'croak','carp';

our $VERSION    = 0.10;

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

=head1 METHODS

Here are major methods that are recommended for users of this module.

=head2 $bal = Net::ISP::Balance->new('/path/to/config_file.conf','/path/to/interfaces');

Creates a new balancer object. 

The first optional argument is the balancer configuration file, defaults
to /etc/network/balance.conf.  

The second optional argument is the system network interfaces file,
defaulting to /etc/network/interfaces.

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
	bal_conf_file   => $conf,
	dummy_data=>$dummy_test_data,
    },ref $class || $class;

    $self->_parse_configuration_file($conf);
    $self->_collect_interfaces($interfaces);

    return $self;
}

sub default_conf_file {
    my $self = shift;
    return '/etc/network/balance.conf'                   if -d '/etc/network';
    return '/etc/sysconfig/network-scripts/balance.conf' if -d '/etc/sysconfig/network-scripts';
    return '/etc/balance.conf';
}

sub default_interface_file {
    my $self = shift;
    return '/etc/network/interfaces'        if -d '/etc/network';
    return '/etc/sysconfig/network-scripts' if -d '/etc/sysconfig/network-scripts';
    die "I don't know where to find network interface configuration files on this system";
}

sub default_rules_directory {
    my $self = shift;
    return '/etc/network/balance'                   if -d '/etc/network';
    return '/etc/sysconfig/network-scripts/balance' if -d '/etc/sysconfig/network-scripts';
    die "I don't know where to place the balancer rules on this system";
}

sub default_lsm_conf_file {
    my $self = shift;
    return '/etc/network/lsm.conf'                   if -d '/etc/network';
    return '/etc/sysconfig/network-scripts/lsm.conf' if -d '/etc/sysconfig/network-scripts';
    return '/etc/lsm.conf';
}

=head2 $bal->rules_directory([$rules_directory])

Directory in which *.conf and *.pl files containing additional routing and firewall
rules can be found. Starts out as '/etc/network/balance'

=cut

sub rules_directory {
    my $self = shift;
    my $d   = $self->{rules_directory};
    $self->{rules_directory} = shift if @_;
    $d;
}

sub lsm_conf_file {
    my $self = shift;
    my $d   = $self->{lsm_conf_file};
    $self->{lsm_conf_file} = shift if @_;
    $d;
}

sub bal_conf_file {
    my $self = shift;
    my $d   = $self->{bal_conf_file};
    $self->{bal_conf_file} = shift if @_;
    $d;
}

=head2 $bal->verbose([boolean]);

=cut

sub verbose {
    my $self = shift;
    my $d    = $self->{verbose};
    $self->{verbose} = shift if @_;
    $d;
}

=head2 $bal->iptables_verbose([boolean])

Makes iptables log verbosely to syslog

=cut

sub iptables_verbose {
    my $self = shift;
    my $d    = $self->{iptables_verbose};
    $self->{iptables_verbose} = shift if @_;
    $d;
}

=head2 $bal->echo_only([boolean]);

=cut

sub echo_only {
    my $self = shift;
    my $d    = $self->{echo_only};
    $self->{echo_only} = shift if @_;
    $d;
}

=head2 @names = $bal->service_names

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
Currently this is only tested with a single lan!!

=cut

sub lan_services {
    my $self = shift;
    my @n    = $self->service_names;
    return grep {$self->role($_) eq 'lan'} @n;
}

=head2 @up = $bal->up(@up_services)

Get or set the list of ISP interfaces that should be used for balancing.

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

=cut

sub services { return shift->{services} }

=head2 $service = $bal->service('CABLE')

=cut

sub service {
    shift->{services}{shift()};
}

=head2 $dev = $bal->dev('CABLE')

=head2 $ip = $bal->ip('CABLE')

=head2 $gateway = $bal->gw('CABLE')

=head2 $network = $bal->net('CABLE')

=head2 $role = $bal->role('CABLE')

Possible roles are "isp" and "lan". "isp" indicates an outgoing
interface connected to an internet service provider. "lan" indicates a
local interface connected to your network. Currently we expect there
to be only one lan but this may chance in the fugure.

=head2 $running = $bal->running('CABLE')

=head2 $mark_number = $bal->fwmark('CABLE')

=head2 $routing_table_number = $bal->table('CABLE')

This is currently always the same as the fwmark to simplify debugging.

=head2 $ping_dest   = $bal->ping('CABLE')

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

=head2 $lsm_config_text = $bal->lsm_config_file(-warn_email=>'root@localhost')

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
    my %defaults = (
                      -checkip              => '127.0.0.1',
                      -debug                => 8,
                      -eventscript          => '/etc/network/lsm/balancer_event_script',
                      -notifyscript         => '/etc/network/lsm/default_script',
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
	next unless $entry =~ /ifcfg-.*(\w+)$/;
	$ifcfg{$entry} = $1;
    }
    closedir $dh;
    for my $entry (keys %ifcfg) {
	my $file = "$interfaces/$entry";
	my $dev  = $ifcfg{$entry};
	open my $fh,$file or die "$file: $!";
	while (<$fh>) {
	    chomp;
	    if (/^GATEWAY\s*=\s*(\S+)/) {
		$gw{$dev}=$1;
	    }
	    if (/^BOOTPROTO\s*=\s*(\w+)/) {
		$iface_type{$dev} = $1 eq 'dhcp' ? 'dhcp' : 'static';
	    }
	}
	$iface_type{$dev} = 'ppp' if $dev =~ /^ppp\d+/;  # hack 'cause no other way to figure it out
	close $fh;
    }

    return (\%iface_type,\%gw);
}

# e.g. sh "ip route flush table main";
=head2 $bal->sh(@args)

Either pass @args to the shell for execution, or print to stdout, depending on
setting of echo_only().

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


=head2 $bal->iptables(@args)

Invoke sh() to call "iptables @args".

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

=head2 $bal->ip_route(@args)

Invoke sh() to call "ip route @args".

=cut

sub ip_route {shift->sh('ip','route',@_)}

=head2 $bal->ip_rule(@args)

Invoke sh() to call "ip rule @args".

=cut

sub ip_rule {shift->sh('ip','rule',@_)}

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

sub find_dhclient_leases {
    my $self     = shift;
    my $device = shift;
    my @locations = ('/var/lib/NetworkManager','/var/lib/dhcp');
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

=head2 $bal->set_routes_and_firewall

=cut

sub set_routes_and_firewall {
    my $self = shift;
    $self->enable_forwarding(0);
    $self->set_routes();
    $self->set_firewall();
    $self->enable_forwarding(1);
}

=head2 $bal->set_routes

=cut

sub set_routes {
    my $self = shift;
    $self->routing_rules();
    $self->local_routing_rules();
}

=head2 $bal->set_routes

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

=head2 $bal->local_routing_rules

Execute tables and perl scripts found in the routes subdirectory

=cut

sub local_routing_rules {
    my $self = shift;
    my $dir  = $self->rules_directory;
    my @files = sort glob("$dir/routes/*");
    $self->_execute_rules_files(@files);
}

=head2 $bal->local_fw_rules

Execute tables and perl scripts found in the firewall subdirectory

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

Set up basic firewall rules, including default rules and reporting

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

This creates a sensible series of firewall rules that seeks to prevent
spoofing, flooding, and other antisocial behavior. It also enables
UDP-based network time and domain name service.

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

    # anything else is bizarre and should be dropped
    $self->iptables('-A OUTPUT  -j DROPSPOOF');
}

=head2 $bal->nat_fw_rules()

Set up basic NAT rules for lan traffic over ISP

=cut

sub nat_fw_rules {
    my $self = shift;
    $self->iptables('-t nat -A POSTROUTING -o',$self->dev($_),'-j MASQUERADE')
	foreach $self->isp_services;
}

=head2 $bal->forward($incoming_port,$destination_host,@protocols)

Creates appropriate port/host forwarding rules. Destination host can
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

    for my $protocol (@protocols) {
	for my $d (@dev) {
	    $self->iptables(["-A INPUT   -p $protocol --dport $port -j ACCEPT",
			     "-A FORWARD -p $protocol --dport $port -j ACCEPT",
			     "-t nat -A PREROUTING -i $d -p $protocol --dport $port -j DNAT --to-destination $host"]);
	}
	$self->iptables('-t nat -A POSTROUTING -p',$protocol,
			'-d',$dhost,'--dport',$dport,
			'-s',$self->net($_),
			'-j','SNAT',
			'--to',$self->ip($_)) foreach $self->lan_services;
    }
}

1;

