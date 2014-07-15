package Net::ISP::Balance;

use strict;
use IO::String;
use Fcntl ':flock';
use Carp 'croak','carp';

eval 'use Net::Netmask';
eval 'use Net::ISP::Balance::ConfigData';

our $VERSION    = '1.04';

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

=head1 USAGE

This library supports load_balance.pl, a script to load-balance a home
network across two or more Internet Service Providers (ISP). The
load_balance.pl script can be found in the bin subdirectory of this
distribution. Installation and configuration instructions can be found
at http://lstein.github.io/Net-ISP-Balance/.

=head1 FREQUENTLY-USED METHODS

Here are the class methods for this module that can be called on the
class name.

=head2 $bal = Net::ISP::Balance->new('/path/to/config_file.conf');

Creates a new balancer object. 

The first optional argument is the balancer configuration file, which
defaults to /etc/network/balance.conf on Ubuntu/Debian-derived
systems, and /etc/sysconfig/network-scripts/balance.conf on
RedHat/CentOS-derived systems. From hereon, we'll refer to the base of
the various configuration files as $ETC_NETWORK.

=cut

sub new {
    my $class = shift;
    my ($conf,$dummy_test_data)  = @_;
    $conf       ||= $class->default_conf_file;
    $conf       && -r $conf       || croak 'Must provide a readable configuration file path';
    my $self  = bless {
	verbose   => 0,
	echo_only => 0,
	services  => {},
	rules_directory => $class->default_rules_directory,
	lsm_conf_file   => $class->default_lsm_conf_file,
	lsm_scripts_dir => $class->default_lsm_scripts_dir,
	bal_conf_file   => $conf,
	dummy_data      => $dummy_test_data,
    },ref $class || $class;

    $self->_parse_configuration_file($conf);
    $self->_collect_interfaces();

    return $self;
}

=head2 $bal->set_routes_and_firewall

Once the Balance objecty is created, call set_routes_and_firewall() to
configure the routing tables and firewall for load balancing. These
rules will either be executed on the system, or printed to standard
output as a series of shell script commands if echo_only() is set to
true.

The routing tables and firewall rules are based on the configuration
described in $ETC_NETWORK/balance.conf. You may add custom routes and
rules by creating files in $ETC_NETWORK/balance/routes and
$ETC_NETWORK/balance/firewall. The former contains a series of files
or perl scripts that define additional routing rules. The latter
contains files or perl scripts that define additional firewall rules.

Files located in $ETC_NETWORK/balance/pre-run will be executed just
before load_balance.pl emits any route/firewall commands, while those
in $ETC_NETWORK/balance/post-run will be run after load_balance.pl is
finished.

Any files you put into these directories will be read in alphabetic
order and added to the routes and/or firewall rules emitted by the
load balancing script.Contained in this directory are subdirectories named "routes" and
"firewall". The former contains a series of files or perl scripts that
define additional routing rules. The latter contains files or perl
scripts that define additional firewall rules.

Note that files ending in ~ or starting with # are treated as autosave files 
and ignored.

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
    unless ($self->isp_services) {
	warn "No ISP services seem to be up. Not altering routing tables or firewall.\n";
	return;
    }
    $self->pre_run_rules();
    $self->enable_forwarding(0);
    $self->set_routes();
    $self->set_firewall();
    $self->enable_forwarding(1);
    $self->post_run_rules();
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

=head2 $bal->iptables(@args)

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
	$seen_rule{$_}++   || $self->sh('iptables',$_) foreach @{$_[0]};
    } else {
	$seen_rule{"@_"}++ || $self->sh('iptables',@_)
    }
}

sub _iptables_add_rule {
    my $self = shift;
    my ($operation,$chain,$table,@args) = @_;
    croak "You must provide a chain name" unless $chain;
    my $op  = $operation eq 'append' ? '-A'
	     :$operation eq 'delete' ? '-D'
	     :$operation eq 'check ' ? '-C'
	     :$operation eq 'insert' ? '-I'
	     :'-A';
    
    my $command = '';
    $command   .= "-t $table " if $table;
    $command   .= "$op $chain ";
    $command   .= $self->_process_iptable_options(@args);
    $self->iptables($command);
}

sub iptables_append {
    my $self = shift;
    my ($table,$chain,@args) = @_;
    $self->_iptables_add_rule('append',$table,$chain,@args);
}

sub iptables_delete {
    my $self = shift;
    my ($table,$chain,@args) = @_;
    $self->_iptables_add_rule('delete',$table,$chain,@args);
}

sub iptables_check {
    my $self = shift;
    my ($table,$chain,@args) = @_;
    $self->_iptables_add_rule('check',$table,$chain,@args);
}

sub iptables_insert {
    my $self = shift;
    my ($table,$chain,@args) = @_;
    $self->_iptables_add_rule('insert',$table,$chain,@args);
}

=head2 $bal->firewall_rule($chain,$table,@args)

Issue an iptables firewall rule.

 $chain -- The chain to apply the rule to, e.g. "INPUT". 
 
 $table -- The table to apply the rule to, e.g. "nat". Undef defaults to
           the standard "filter" table.

 @args  -- The other arguments to pass to iptables.

Here is a typical example of blocking incoming connections to port 25:

 $bal->firewall_rule(INPUT=>undef,-p=>'tcp',-dport=>25,-j=>'REJECT');

This will issue the following command:

 iptables -A INPUT -p tcp --dport 25 -j REJECT

The default operation is to append the rule to the chain using
-A. This can be changed by passing $bal->firewall_op() any of the
strings "append", "delete", "insert" or "check". Subsequent calls to
firewall_rule() will return commands for the indicated function:

 $bal->firewall_op('delete');
 $bal->firewall_rule(INPUT=>undef,-p=>'tcp',-dport=>25,-j=>'REJECT');
 # gives  iptables -A INPUT -p tcp --dport 25 -j REJECT

If you want to apply a series of deletes and then revert to the
original append behavior, then it is easiest to localize the hash key
"firewall_op":

 {
   local $bal->{firewall_op} = 'delete';
   $bal->firewall_rule(INPUT=>undef,-dport=>25,-j=>'ACCEPT');
   $bal->firewall_rule(INPUT->undef,-dport=>80,-j=>'ACCEPT');
 }
 
   $bal->firewall_rule(INPUT=>undef,-dport=>25,-j=>'DROP');
   $bal->firewall_rule(INPUT=>undef,-dport=>80,-j=>'DROP');

=cut

sub firewall_rule {
    my $self = shift;
    my ($chain,$table,@args) = @_;
    my $operation = $self->firewall_op();
    $self->_iptables_add_rule($operation,$chain,$table,@args);
}

sub firewall_op {
    my $self = shift;
    if (@_) {
	$self->{firewall_op} = shift;
	return;
    }
    my $d = $self->{firewall_op} || 'append';
    return $d;
}

=head2 $bal->force_route($service_or_device,@selectors)

The force_route() method issues iptables commands that will force
certain traffic to travel over a particular ISP service or network
device. This is useful, for example, when one of your ISPs acts as
your e-mail relay and only accepts connections from the IP address
it assigns.

$service_or_device is the symbolic name of an ISP service
(e.g. "CABLE") or a network device that a service is attached to
(e.g. "eth0").

@selectors are a series of options that will be passed to
iptables to select the routing of packets. For example, to forward all
outgoing mail (destined to port 25) to the "CABLE" ISP, you would
write:

    $bal->force_route('CABLE','--syn','-p'=>'tcp','--dport'=>25);

@selectors is a series of optional arguments that will be passed to
iptables on the command line. They will simply be space-separated, and
so the following is equivalent to the previous example:

    $bal->force_route('CABLE','--syn -p tcp --dport 25');

Bare arguments that begin with a leading hyphen and are followed by
two or more alphanumeric characters are automatically converted into
double-hyphen arguments. This allows you to simplify commands
slightly. The following is equivalent to the previous examples:

    $bal->force_route('CABLE',-syn,-p=>'tcp',-dport=>25);

You can delete force_route rules by setting firewall_op() to 'delete':

    $bal->firewall_op('delete');
    $bal->force_route('CABLE',-syn,-p=>'tcp',-dport=>25);

=cut

sub force_route {
    my $self = shift;
    my ($service_or_device,@selectors) = @_;
    
    my $service = $self->_service_or_device($service_or_device)
	or croak "did not recognize $service_or_device as a service or a device";

    my $dest      = $self->mark_table($service);
    my $selectors = $self->_process_iptable_options(@selectors);
    $self->firewall_rule(PREROUTING=>'mangle',$selectors,-j=>$dest);
}

=head2 $bal->add_route($address => $device, [$masquerade])

This method is used to create routing and firewall rules for a network
that isn't mentioned in balance.conf. This may be necessary to route
to VPNs and/or to the control interfaces of attached modems.

The first argument is the network address in CIDR format,
e.g. '192.168.2.0/24'. The second is the network interface that the
network can be accessed via. The third, optional, argument is a
boolean. If true, then firewall rules will be set up to masquerade
from the LAN into the attached network.

Note that this is pretty limited. If you want to do anything more
sophisticated you're better off setting the routes and firewall rules
manually.

=cut

sub add_route {
    my $self = shift;
    my ($network,$device,$masquerade) = @_;
    $network && $device or croak "usage: add_network(\$network,\$device,[\$masquerade])";
    # add the route to our main table
    $self->ip_route("add $network dev $device");
    # add the route to each outgoing table
    $self->ip_route("add $network dev $device table $_") for map {$self->table($_)} $self->isp_services;
    
    # create appropriate firewall rules for the network
    {
	local $self->{firewall_op} = 'insert';
	$self->firewall_rule(OUTPUT => undef,
			     -o    => $device,
			     -d    => $network,
			     -j    => 'ACCEPT');
	$self->firewall_rule(INPUT => undef,
			     -i    => $device,
			     -s    => $network,
			     -j    => 'ACCEPT');
	$self->firewall_rule(FORWARD => undef,
			     -i    => $self->dev($_),
			     -s    => $self->net($_),
			     -o    => $device,
			     -d    => $network,
			     -j    => 'ACCEPT') for $self->lan_services;
	$self->firewall_rule(FORWARD => undef,
			     -i    => $device,
			     -s    => $network,
			     -o    => $self->dev($_),
			     -d    => $self->net($_),
			     -j    => 'ACCEPT') for $self->lan_services;
    }
    if ($masquerade) {
	$self->firewall_rule(POSTROUTING=>'nat',
			     -d => $network,
			     -o => $device,
			     -j => 'MASQUERADE');
    }
}

sub _process_iptable_options {
    my $self = shift;
    my @opt  = @_;
    foreach (@opt) {
	$_ = "-$_" if /^-\w{2,}/;  # add an extra hyphen to -arguments
	$_ =~ quotemeta($_);
    }
    return join ' ',@opt;
}

sub _mark {
    my $self    = shift;
    my $service = shift;
    return "MARK-${service}";
}

=head2 $table_name = $bal->mark_table($service)

This returns the iptables table name for connections marked for output
on a particular ISP service. The name is simply the word "MARK-"
appended to the service name. For example, for a service named "DSL",
the corresponding firewall table will be named "MARK-DSL".

=cut

sub mark_table { shift->_mark(shift) }

sub _service_or_device {
    my $self = shift;
    my $sod  = shift;
    return $sod if $self->dev($sod);
    # otherwise try looking for devices
    my %dev2s = map {$self->dev($_) => $_} $self->service_names;
    return $dev2s{$sod};
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

=head2 $state = $bal->event($service => $new_state)

Record a transition between "up" and "down" for a named service. The
first argument is the name of the ISP service that has changed,
e.g. "CABLE". The second argument is either "up" or "down".

The method returns a hashref in which the keys are the ISP service names
and the values are one of 'up' or 'down'.

The persistent state information is stored in /var/lib/lsm/ under a
series of files named <SERVICE_NAME>.state.

=cut

sub event {
    my $self = shift;

    if (@_) {
	my ($svc,$new_state) = @_;
	$new_state =~ /^(up|down)$/  or croak "state must be 'up' or  down'";
	$self->dev($svc)             or croak "service '$svc' is unknown";
	my $file = "/var/lib/lsm/${svc}.state";
	my $mode = -e $file ? '+<' : '>';
	open my $fh,$mode,$file or croak "Couldn't open $file mode $mode: $!";
	flock $fh,LOCK_EX;
	truncate $fh,0;
	seek($fh,0,0);
	print $fh $new_state;
	close $fh;
    }

    my %state;
    for my $svc ($self->isp_services) {
	my $file = "/var/lib/lsm/${svc}.state";
	if (open my $fh,'<',$file) {
	    flock $fh,LOCK_SH;
	    my $state = <$fh>;
	    close $fh;
	    $state{$svc}=$state;
	} else {
	    $state{$svc}='unknown';
	}
    }
    my @up = grep {$state{$_} eq 'up'} keys %state;
    $self->up(@up);
    return \%state;
}

=head2 $bal->run_eventd(@args)

Runs scripts in response to lsm events. The scripts are stored in
directories named after the events, e.g.:

 /etc/network/lsm/up.d/*
 /etc/network/lsm/down.d/*
 /etc/network/lsm/long_down.d/*

Scripts are called with the following arguments:

  0. STATE
  1. SERVICE NAME
  2. CHECKIP
  3. DEVICE
  4. WARN_EMAIL
  5. REPLIED
  6. WAITING
  7. TIMEOUT
  8. REPLY_LATE
  9. CONS_RCVD
 10. CONS_WAIT
 11. CONS_MISS
 12. AVG_RTT
 13. SRCIP
 14. PREVSTATE
 15. TIMESTAMP

=cut

sub run_eventd {
    my $self = shift;
    my @args = @_;
    my $state = $args[0];
    my $dir  = $self->lsm_scripts_dir();
    my $dird = "$dir/${state}.d";
    my @files = sort glob("$dird/*");
    for my $script (@files) {
	next unless -f $script && -x _;
	system $script,@args;
    }    
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
    return $self->install_etc."/balance/lsm.conf";
}

=head2 $dir = Net::ISP::Balance->default_lsm_scripts_dir

Returns the path to the place where lsm stores its helper scripts.  On
Ubuntu/Debian-derived systems, this will be the directory
/etc/network/lsm/. On RedHad/CentOS-derived systems, this will be
/etc/sysconfig/network-scripts/lsm/.

=cut

sub default_lsm_scripts_dir {
    my $self = shift;
    return $self->install_etc.'/lsm';
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
    -eventscript                /etc/network/load_balance.pl
    -long_down_eventscript      /etc/network/load_balance.pl
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
    -device                   <autodiscovered>                      -eventscript          => $balance_script,
    -ttl                      0 <use system value>
    -status                   2 <no assumptions>
    -debug                    8 <moderate verbosity from scale of 0 to 100>

=cut

sub lsm_config_text {
    my $self = shift;
    my %args = @_;
    my $scripts_dir    = $self->lsm_scripts_dir;
    my $balance_script = $self->install_etc."/load_balance.pl";
    my %defaults = (
                      -checkip              => '127.0.0.1',
                      -debug                => 8,
                      -eventscript            => $balance_script,
                      -long_down_eventscript  => $balance_script,
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
	croak "load_balance.conf line $.: A service can not be named 'up' or 'down'"
	    if $service=~/^(up|down)$/;
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
    my $s    = $self->{svc_config} or return;

    # get interfaces with assigned addresses
    my $a    = $self->_ip_addr_show;
    my (undef,@ifs)  = split /^\d+: /m,$a;
    chomp(@ifs);
    my %ifs = map {split(/: /,$_,2)} @ifs;

    # get existing routes
    my (%gws,%nets);
    my $r    = $self->_ip_route_show;
    my @routes = split /^(?!\s)/m,$r;
    chomp(@routes);
    foreach (@routes) {
	while (/(\S+)\s+via\s+(\S+)\s+dev\s+(\w+)/g) {
	    my ($net,$gateway,$dev) = ($1,$2,$3);
	    ($net) = /^(\S+)/ if $net eq 'nexthop';
	    $nets{$dev} = $net unless $net eq 'default';
	    $gws{$dev}  = $gateway;
	}
    }
                               
    # map devices to services
    my %devs;
    for my $svc (keys %$s) {
	my $dev = $s->{$svc}{dev};
	$devs{$dev}=$svc;
    }

    my %ifaces;
    my $counter = 0;
    for my $dev (keys %devs) {
	my $info      = $ifs{$dev} or next;
	my $svc       = $devs{$dev};
	my $role      = $s->{$svc}{role};
	my $running   = $info =~ /[<,]UP[,>]/;
	my ($addr,$bits)= $info =~ /inet (\d+\.\d+\.\d+\.\d+)(?:\/(\d+))?/;
	$bits ||= 32;
	my ($peer)      = $info =~ /peer\s+(\d+\.\d+\.\d+\.\d+)/;
	my $block       = Net::Netmask->new("$addr/$bits");
	$ifaces{$svc} = {
	    dev     => $dev,
	    running => $running,
	    gw      => $gws{$dev}  || $peer,
	    net     => $nets{$dev} || ($peer?"$peer/32":undef) || "$block",
	    ip      => $addr,
	    fwmark  => $role eq 'isp' ? ++$counter : undef,
	    table   => $role eq 'isp' ?   $counter : undef,
	    role    => $role,
	    ping    => $s->{$svc}{ping},
	};
    }
    $self->{services} = \%ifaces;
}

sub _ip_addr_show {
    my $self = shift;
    return $self->{dummy_data}{"ip_addr_show"} || `ip addr show`;
}

sub _ip_route_show {
    my $self = shift;
    return $self->{dummy_data}{"ip_route_show"} || `ip route show all`;
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

=head2 $bal->pre_run_rules()

This method is called by set_routes_and_firewall() to process the fules and emit
the commands contained in the customized route files located in
$ETC_DIR/balance/pre-run.

=cut

sub pre_run_rules {
    my $self = shift;
    my $dir  = $self->rules_directory;
    my @files = sort glob("$dir/pre-run/*");
    $self->_execute_rules_files(@files);
}

=head2 $bal->post_run_rules()

This method is called by set__routes_andfirewall() to process the
fules and emit the commands contained in the customized route files
located in $ETC_DIR/balance/post-run.

=cut

sub post_run_rules {
    my $self = shift;
    my $dir  = $self->rules_directory;
    my @files = sort glob("$dir/post-run/*");
    $self->_execute_rules_files(@files);
}


sub _execute_rules_files {
    my $self = shift;
    my @files = @_;

    for my $f (@files) {
	next if $f =~ /~$/;   # ignore emacs backup files
	next if $f =~ /^#/;   # ignore autosave files
	print STDERR "# executing contents of $f\n" if $self->verbose;
	$self->sh("## Including rules from $f ##\n");
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
	$self->sh("## Finished $f ##\n");
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
	my $table = $self->mark_table($svc);
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
		my $table       = $self->mark_table($svc);
		my $probability = 1/$i++; # 1, 1/2, 1/3, 1/4...
		$self->iptables("-t mangle -A PREROUTING -i $landev -m conntrack --ctstate NEW -m statistic --mode random --probability $probability -j $table");
	    }
	}

	else {
	    my $svc = $up[0];
	    print STDERR "# forcing all traffic through $svc\n" if $self->verbose;
	    my $table  = $self->mark_table($svc);
	    $self->iptables("-t mangle -A PREROUTING -i $landev -m conntrack --ctstate NEW -j $table");
	}

	$self->iptables("-t mangle -A PREROUTING -i $landev -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark");
    }

    # inbound packets from WAN
    for my $wan ($self->isp_services) {
	my $dev   = $self->dev($wan);
	my $table = $self->mark_table($wan);
	$self->iptables("-t mangle -A PREROUTING -i $dev -m conntrack --ctstate NEW -j $table");
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

# These lines are now contained in 02.forwardings.pl
#	# allow domain and time services
#	$self->iptables(['-A INPUT   -p udp --source-port domain -j ACCEPT',
#			 "-A FORWARD -p udp --source-port domain -d $net -j ACCEPT"]);
#
#	# time
#	$self->iptables(['-A INPUT   -p udp --source-port ntp -j ACCEPT',
#			 "-A FORWARD -p udp --source-port ntp -d $net -j ACCEPT"]);

	# lan/wan forwarding
	# allow lan/wan forwarding
	for my $svc ($self->isp_services) {
	    my $ispdev = $self->dev($svc);
	    $self->iptables("-A FORWARD -i $dev -o $ispdev -s $net -j ACCEPT");
	    $self->iptables("-A OUTPUT -o $ispdev -j ACCEPT");
	}
    }

    # allow forwarding between lans
    my @lans = $self->lan_services;
    for (my $i=0;$i<@lans;$i++) {
	my $lan1 = $lans[$i];
	my $lan2 = $lans[$i+1];
	next unless $lan2;
	$self->iptables('-A FORWARD','-i',$self->dev($lan1),'-o',$self->dev($lan2),'-s',$self->net($lan1),'-d',$self->net($lan2),'-j ACCEPT');
	$self->iptables('-A FORWARD','-i',$self->dev($lan2),'-o',$self->dev($lan1),'-s',$self->net($lan2),'-d',$self->net($lan1),'-j ACCEPT');
    }

    # anything else is bizarre and should be dropped
    $self->iptables('-A OUTPUT  -j DROPSPOOF');
}

=head2 $bal->nat_fw_rules()

This is called by set_firewall() to set up basic NAT rules for lan traffic over ISP

=cut

sub nat_fw_rules {
    my $self = shift;
    return unless $self->lan_services;
    $self->iptables('-t nat -A POSTROUTING -o',$self->dev($_),'-j MASQUERADE')
	foreach $self->isp_services;
}

=head2 $bal->start_lsm()

Start an lsm process.

=cut

sub start_lsm {
    my $self = shift;
    my $lsm      = Net::ISP::Balance::ConfigData->config('lsm_path');
    my $lsm_conf = $self->lsm_conf_file;
    system "$lsm $lsm_conf /var/run/lsm.pid";
}

=head2 $bal->signal_lsm($signal)

Send a signal to a running LSM and return true if successfully
signalled. The signal can be numeric (e.g. 9) or a string ('TERM').

=cut

sub signal_lsm {
    my $self = shift;
    my $signal = shift;
    $signal   ||= 0;
    my $pid;
    open my $f,'/var/run/lsm.pid' or return;
    chomp($pid = <$f>);
    close $f;
    return unless $pid =~ /^\d+$/;
    return kill($signal=>$pid);
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
