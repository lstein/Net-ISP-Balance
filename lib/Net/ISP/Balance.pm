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
 my $lsm_conf = $bal->lsm_config_file(-checkip    => 'www.google.com',
                                      -warn_email => 'root@localhost'
    );

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
 # /etc/network/balance/dnat_rules.conf               forward incoming connections to designated host(s)
 # /etc/network/balance/incoming_service_rules.conf   allow incoming services to the router
 # /etc/network/balance/local_routes.conf             additional routes
 # /etc/network/balance/local_rules.conf              additional firewall rules

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

=head2 $services = $bal->services

=cut

sub services { return shift->{services} }

=head2 $service = $bal->service('CABLE')

=cut

sub service {
    shift->{services}{shift()};
}

=head2 $dev = $bal->dev('CABLE')

=cut

sub dev { shift->_service_field(shift,'dev') }
sub ip  { shift->_service_field(shift,'ip')  }
sub gw  { shift->_service_field(shift,'gw')  }
sub net { shift->_service_field(shift,'net')  }
sub running { shift->_service_field(shift,'running')  }
sub fwmark { shift->_service_field(shift,'fwmark')  }
sub ping   { shift->_service_field(shift,'ping')  }


sub _service_field {
    my $self = shift;
    my ($service,$field) = @_;
    my $s = $self->{services}{$service} or return;
    $s->{$field};
}

sub _parse_configuration_file {
    my $self = shift;
    my $path = shift;
    my %services;
    open my $f,$path or die "Could not open $path: $!";
    while (<$f>) {
	chomp;
	next if /^\s*#/;
	my ($service,$device,$action,$ping_dest) = split /\s+/;
	next unless $service && $device && $action;
	$services{$service}{dev}=$device;
	$services{$service}{action}=$action;
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
	my $action = $svc ? $s->{$svc}{action} : '';
	my $type  = $iface_type{$dev};
	my $info = $type eq 'static' ? $self->get_static_info($dev,$gw{$dev})
	          :$type eq 'dhcp'   ? $self->get_dhcp_info($dev)
	          :$type eq 'ppp'    ? $self->get_ppp_info($dev)
		  :undef;
	$info ||= {dev=>$dev,running=>0}; # not running
	$info or die "Couldn't figure out how to get info from $dev";
	if ($action eq 'balance') {
	    $counter++;
	    $info->{fwmark} = $counter;
	    $info->{table}  = $counter;
	}
	# ignore any interfaces that do not seem to be running
	next unless $info->{running};
	$info->{ping} = $s->{$svc}{ping};
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
    my $arg  = shift;
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



1;

