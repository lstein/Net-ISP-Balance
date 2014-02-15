package Net::ISP::Balance;

use strict;
use Net::Netmask;
use IO::String;
use Carp 'croak','carp';

=head1 NAME

Net::ISP::Balance - Support load balancing across multiple internet service providers

=head1 SYNOPSIS

 use Net::ISP::Balance;

 # initialize the module with its configuration file
 my $bal = Net::ISP::Balance->new('/etc/network/balancer.conf');

 $bal->verbose(1);    # verbosely print commands to STDERR before running them
 $bal->echo_only(1);  # just echo commands to STDOUT; don't run them
 
 # get a configuration file for use with lsm link monitor
 my $lsm_conf = $bal->lsm_config_text(-warn_email => 'root@localhost');

 # Get info about a service. Service names are defined in the configuration file.
 my $i = $bal->service('CABLE');
 # x $i
 # {
 #    dev => 'eth0',
 #    ip  => '192.168.1.8',
 #    gw  => '192.168.1.1',
 #    net => '192.168.1.0/24',
 #    running  => 1,
 #    fwmark   => 1
 # }

 # equivalent method calls...
 $bal->dev('CABLE');
 $bal->ip('CABLE');
 $bal->gw('CABLE');
 $bal->net('CABLE');
 $bal->running('CABLE');
 $bal->fwmark('CABLE');

 # store which balanced ISP services are up and running
 # (usually determined by lsm and communicated via a small wrapper script)
 $bal->up('CABLE');
 $bal->up('DSL');
 $bal->up('SATELLITE');
 # or #
 $bal->up('CABLE','DSL','SATELLITE');
 
 # retrieve which services are up
 # note this is not the same as running(), which indicates whether the
 # interface to the service is available
 @up = $bal->up();

 # top-level call to set up routes and firewall
 $bal->set_routes_and_firewall();

 # lower-level calls, invoked by set_routes_and_firewall()
 # must call up() first with list of ISP services to enable, otherwise
 # no routing outside the internal LAN will occur
 $bal->enable_forwarding(0);
 $bal->routing_rules();
 $bal->base_fw_rules();
 $bal->balancing_fw_rules();
 $bal->nat_fw_rules();
 $bal->incoming_service_fw_rules();
 $bal->dnat_fw_rules();
 $bal->local_rules();
 $bal->enable_forwarding(1);

 # the following customization files are scanned during execution
 # /etc/network/balance/local_ip.conf                 additional calls to "ip"
 # /etc/network/balance/local_ip.pl                   additional calls to "ip" written in perl
 # /etc/network/balance/local_iptables.conf           additional calls to "iptables"
 # /etc/network/balance/local_iptables.pl             additional calls to "iptables" written in perl


=cut


use Carp;

=head1 METHODS

Here are major methods that are recommended for users of this module.

=head2 $bal = Net::ISP::Balance->new('/path/to/config_file.conf','/path/to/interfaces');

Creates a new balancer object. 

The first optional argument is the balancer configuration file, defaults
to /etc/network/balancer.conf.  

The second optional argument is the system network interfaces file,
defaulting to /etc/network/interfaces.

=cut

sub new {
    my $class = shift;
    my ($conf,$interfaces,$dummy_test_data)  = @_;
    $conf       ||= '/etc/network/balancer.conf';
    $interfaces ||= '/etc/network/interfaces';
    $conf       && -r $conf       || croak 'Must provide a readable configuration file path';
    $interfaces && -r $interfaces || croak 'Must provide a readable network interfaces path';
    my $self  = bless {
	verbose   => 0,
	echo_only => 0,
	services  => {},
	dummy_data=>$dummy_test_data,
    },ref $class || $class;

    $self->_parse_configuration_file($conf);
    $self->_collect_interfaces($interfaces);

    return $self;
}

=head2 $bal->verbose([boolean]);

=cut

sub verbose {
    my $self = shift;
    my $d    = $self->{verbose};
    $self->{verbose} = shift if @_;
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
    -status                   1 <assume default up>
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
                      -status                   => 1
	);
    %defaults = (%defaults,%args);  # %args supersedes what's in %defaults

    my $result = '';
    $result   .= "debug=$defaults{-debug}\n";
    delete $defaults{-debug};

    $result .= "defaults {\n";
    for my $option (sort keys %defaults) {
	(my $o = $option) =~ s/^-//;
	$result .= " $o=$defaults{$option}\n";
    }
    $result .= "}\n";

    for my $svc ($self->isp_services) {
	my $device = $self->dev($svc);
	my $ping   = $self->ping($svc);
	$result .= "$svc {\n";
	$result .= " dev=$device\n";
	$result .= " checkip=$ping\n";
	$result .= "}\n";
    }

    return $result;
}

sub _parse_configuration_file {
    my $self = shift;
    my $path = shift;
    my %services;
    open my $f,$path or die "Could not open $path: $!";
    while (<$f>) {
	chomp;
	next if /^\s*#/;
	my ($service,$device,$role,$ping_dest) = split /\s+/;
	next unless $service && $device && $role;
	$services{$service}{dev}=$device;
	$services{$service}{role}=$role;
	$services{$service}{ping}=$ping_dest;
    }
    close $f;
    $self->{svc_config}=\%services;
}

sub _collect_interfaces {
    my $self = shift;
    my $interfaces = shift;
    my $s    = $self->{svc_config} or return;
    my (%ifaces,%iface_type,$lastdev,%gw,%devs);

    # map devices to services
    for my $svc (keys %$s) {
	my $dev = $s->{$svc}{dev};
	$devs{$dev}=$svc;
    }

    # use /etc/network/interfaces to figure out what kind of
    # device each is.
    open my $f,$interfaces or die "$interfaces: $!";
    while (<$f>) {
	chomp;
	if (/^\s*iface\s+(\w+)\s+inet\s+(\w+)/) {
	    $iface_type{$1} = $2;
	    $lastdev = $1;
	}
	if (/^\s*gateway\s+(\S+)/ && $lastdev) {
	    $gw{$lastdev}=$1;
	}
    }
    close $f;
    my $counter = 0;
    for my $dev (keys %iface_type) {
	my $svc     = $devs{$dev} or next;
	my $role  = $svc ? $s->{$svc}{role} : '';
	my $type  = $iface_type{$dev};
	my $info = $type eq 'static' ? $self->get_static_info($dev,$gw{$dev})
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

# use base 'Exporter';
#our @EXPORT_OK = qw(sh get_devices);
# our @EXPORT    = @EXPORT_OK;

our $VERSION    = 0.01;
our $VERBOSE    = 0;
our $DEBUG_ONLY = 0;

# e.g. sh "ip route flush table main";
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
    $self->_extra_routing_rules();
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

    $self->sh("ip route flush table ",$self->table($_)) foreach $self->isp_services;

    # main table
    $self->sh("ip route add ",$self->net($_),'dev',$self->dev($_),'src',$self->ip($_)) foreach $self->service_names;
}

sub _create_default_route {
    my $self = shift;
    my $D    = shift;

    my @up = $self->up;

    # create multipath route
    if (@up > 1) { # multipath
	print STDERR "# Setting multipath default gw\n";
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
	$self->sh("ip route add default scope global $hops");
    } 

    else {
	print STDERR "#Setting single default route via $up[0]n";
	$self->sh("ip route add default via",$self->gw($up[0]),'dev',$self->dev($up[0]));
    }

}

sub _create_service_routing_tables {
    my $self = shift;

    for my $svc ($self->isp_services) {
	print STDERR "#Creating routing table for $svc\n";
	$self->sh('ip route add table',$self->table($svc),'default dev',$self->dev($svc),'via',$self->gw($svc));
	for my $s ($self->service_names) {
	    $self->sh('ip route add table',$self->table($svc),$self->net($s),'dev',$self->dev($s),'src',$self->ip($s));
	}
	$self->sh('ip rule add from',$self->ip($svc),'table',$self->table($svc));
	$self->sh('ip rule add fwmark',$self->fwmark($svc),'table',$self->table($svc));
    }
}

sub _extra_routing_rules {
    my $self = shift;
}

1;

