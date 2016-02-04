#!/usr/bin/perl

=head1 NAME

load_balance.pl Load balance a host or network across two or more Internet connections.

=head1 SYNOPSIS

 # get status report
 % sudo load_balance.pl -s

 # start link monitoring and load balance across all up ISPs
 % sudo load_balance.pl

 # load balance across "CABLE" and "DSL" only
 % sudo load_balance.pl CABLE DSL

 # print out the routing and firewall commands that would
 # ordinarily be executed
 % load_balance.pl -d

=head1 DESCRIPTION

This script can be run on a Linux-based home router or standalone
computer to load balance your network connection among two or more
Internet Service Providers (ISPs). When aggregated across multiple
simultaneous connections, you will achieve the sum of the bandwidth of
all ISP connections. In addition, the script will continuously ping
each outgoing interface and adjust routing in the event that one or
more ISPs become unavailable. This provides failover.

The script can be called with no arguments, in which case it will mark
all known ISPs as being up and launch the "lsm" link monitor to test
each one periodically for connectivity. It can also be called with one
or more symbolic names for ISP connections, as defined in
load_balance.conf. These will be forced "up" and other ISP connections
will be forced "down".

Other command-line options allow you to view the status of your ISP
connections, kill a running lsm, and more.

Generally this script must be run as root, since it alters the routing
table and firewall rules.

For full installation and configuration instructions, please see
L<http://lstein.github.io/Net-ISP-Balance/>.

=head1 COMMAND-LINE OPTIONS

Each command-line option can be abbreviated or used in long-form.

 --debug, -d     Turn on debugging. In this mode, no firewall or
                 routing commands will be executed, but instead
                 will be printed to standard output for inspection.

 --verbose, -v   Verbose output. Echo all route and iptables commands
                 to STDERR before executing them.

 --Version, -V   Print version of Net::ISP::Balance.

 --status,-s     Print current status of each monitored ISP interface
                 to STDOUT.

 --kill,-k       Kill any running lsm process.

 --flush,-f      Flush all firewall chains and rules. If not given, then
                 the default is to try to keep custom iptables rules 
                 introduced by firewall utilities such as fail2ban and
                 miniunpnpd.

 --help,-h       Print this message.

=head1 COMMON USAGE

This section describes common usage patterns. Note that
load_balance.pl must always be run as root.

=over 4

=item Mark all ISPs as up and start link monitoring:

 % sudo load_balance.pl

=item Mark just the listed ISP(s) as up. Do not start link monitoring:

 % sudo load_balance.pl CABLE

=item Bring up the listed ISP service, leaving the other(s) in their current
state. This is usually done behind the scenes by lsm.

 % sudo load_balance.pl up CABLE

=item Bring down the listed ISP service, leaving the other(s) in the
current state. This is usually done behind the scenes by lsm:

 % sudo load_balance.pl down CABLE

=item Print current status of the defined ISPs:

 % sudo load_balance.pl -s

=item Kill lsm and discontinue the link monitoring:

 % sudo load_balance.pl -k

=item Print to standard output all the routing and firewall commands
that would ordinarily be issued on startup. Do not launch lsm or
actually change anything:

 % sudo load_balance.pl -d

=back

=head1 FILES

This section gives locations of important files.

=head2 Debian/Ubuntu/Mint systems

 /etc/network/balance.conf        # Main configuration file
 /etc/network/balance/firewall/   # Additional firewall rules
 /etc/network/balance/routes/     # Additional routing rules

=head2 RedHat/CentOS systems

 /etc/sysconfig/network-scripts/balance.conf        # Main configuration file
 /etc/sysconfig/network-scripts/balance/firewall/   # Additional firewall rules
 /etc/sysconfig/network-scripts/balance/routes/     # Additional routing rules

=head2 Format of the balance.conf:

balance.conf is the main configuration file. It defines the interfaces
connected to the ISPs and to the LAN (if running on a router). Here is
a typical example:

 #service    device   role     ping-ip
 CABLE       eth0     isp      173.194.43.95
 DSL         eth1     isp      173.194.43.95
 LAN         eth2     lan      

 # name=value pairs define lsm configuration variables
 warn_email=fred@gmail.com
 max_packet_loss=10
 min_packet_loss=5

There are two parts of the configuration file. The first part, which
is required, is a four-column table that defines interfaces to be
monitored.

The first column is a service name that is used to bring up or down
the needed routes and firewall rules.

The second column is the name of the network interface device that
connects to that service.

The third column is either "isp" or "lan". There may be any number of
these. The script will load balance traffic across all ISPs, and will
act as a firewall between the LAN (if any) and the Internet. You do
not need to have a "lan" entry if this is a standalone host.

The fourth and last column is the IP address of a host that can be
periodically pinged to test the integrity of each ISP connection. If
too many pings failed, the service will be brought down and all
traffic routed through the remaining ISP(s). The service will continue
to be monitored and will be brought up when it is once again
working. Choose a host that is not likely to go offline for reasons
unrelated to your network connectivity, such as google.com, or the
ISP's web site.

The second (optional) part of the configuration file is a series of
name=value pairs that allow you to customize the behavior of lsm, such
as where to send email messages when a link's status changes. Please
see L<http://lsm.foobar.fi/> for the comprehensive list.

=head1 SEE ALSO

L<Net::ISP::Balance>

=head1 AUTHOR

Lincoln Stein, lincoln.stein@gmail.com

Copyright (c) 2014 Lincoln D. Stein
                                                                                
This package and its accompanying libraries is free software; you can
redistribute it and/or modify it under the terms of the GPL (either
version 1, or at your option, any later version) or the Artistic
License 2.0.

=cut

use strict;
use Net::ISP::Balance;
use Sys::Syslog;
use Fcntl ':flock';
use File::Spec;
use Getopt::Long qw(:config no_ignore_case);
use Carp 'croak';
use Pod::Usage 'pod2usage';
use constant LOCK_TIMEOUT => 30;  # if two processes running simultaneously, length of time second will wait for first

my ($DEBUG,$VERBOSE,$STATUS,$KILL,$HELP,$FLUSH,$VERSION);
my $result = GetOptions('debug' => \$DEBUG,
			'verbose'=>\$VERBOSE,
			'Version'=>\$VERSION,
			'status' => \$STATUS,
			'kill'   => \$KILL,
			'flush'  => \$FLUSH,
			'help'   => \$HELP,
    );
if (!$result || $HELP) {
    pod2usage(-message => "Usage: $0",
	      -exitval => -1,
	      -verbose => 2);
    exit 0;
}
if ($VERSION) {
    print $Net::ISP::Balance::VERSION,"\n";
    exit 0;
}

my $lock_fh = do_lock();
END { do_unlock($lock_fh); }

# command line arguments correspond to the ISP services (defined in the config file)
# that are "up". LAN services are assumed to be always up.

openlog('load_balance.pl','ndelay,pid','local0');

my $bal = eval {Net::ISP::Balance->new()};

fatal_error("Could not initialize balancer; maybe some interfaces are unavailable? Error message=$@")
    unless $bal;;

$bal->echo_only($DEBUG);
$bal->verbose($VERBOSE);
$bal->keep_custom_chains(!$FLUSH);

# these two subroutines exit
do_status()   if $STATUS;
do_kill_lsm() if $KILL;

my %SERVICES = map {$_=>1} $bal->isp_services;

my %LSM_STATE = (up              => 'up',
		 down            => 'down',
		 long_down       => 'down',
		 long_down_to_up => 'up');

if (exists $LSM_STATE{$ARGV[0]}) {
    do_unlock($lock_fh);    # to allow eventd to call us recursively
    $bal->run_eventd(@ARGV);
    $lock_fh = do_lock();
    if (($SERVICES{my $name = $ARGV[1]})) {
	my $device = $ARGV[3] || $bal->dev($name);
	syslog('warning',"$name ($device) is now in state '$ARGV[0]'.");
	$bal->event($name => $LSM_STATE{$ARGV[0]}) if $LSM_STATE{$ARGV[0]};
    }
}

else {
    my @up = @ARGV ? @ARGV : $bal->isp_services;
    my %up_services = map {uc($_) => 1} @up;
    @up             = keys %up_services; # uniqueify
    my @down        = grep {!$up_services{$_}} $bal->isp_services;
    $bal->event($_ => 'up')   foreach @up;
    $bal->event($_ => 'down') foreach @down;
}

syslog('info',"adjusting routing tables...");
$bal->set_routes_and_firewall();
start_or_reload_lsm($bal);
# start_lsm($bal) unless @ARGV || $DEBUG;

exit 0;

sub do_status {
    my $state = $bal->event();
    for my $svc (sort $bal->isp_services) {
	printf("%-15s %8s\n",$svc,$state->{$svc}||'unknown');
    }
    if ($< == 0)  { # running as root
	kill(USR1 => `cat /var/run/lsm.pid`);
	print STDERR "See syslog for detailed link monitoring information from lsm.\n";
    }
    exit 0;
}

sub do_kill_lsm {
    my $lsm_running = -e '/var/run/lsm.pid' && kill(0=>`cat /var/run/lsm.pid`);
    if ($lsm_running) {
	kill(TERM => `cat /var/run/lsm.pid`);
	print STDERR "lsm process killed\n";
    } else {
	print STDERR "lsm does not seem to be running\n";
    }
    exit 0;
}

sub start_or_reload_lsm {
    my $bal = shift;

    my $config_changed = write_lsm_config($bal);
    my $lsm_conf       = $bal->lsm_conf_file;
    my $lsm_pid        = -e '/var/run/lsm.pid' && `cat /var/run/lsm.pid`;
    chomp($lsm_pid);

    my $lsm_running = $lsm_pid && kill(0=>$lsm_pid);

    syslog('info',"lsm PID=$lsm_pid, is_running=$lsm_running");

    if ($lsm_running && $config_changed) {
	syslog('info',"Reloading lsm link status monitoring daemon");    
	kill(HUP => $lsm_pid);
    } else {
	syslog('info',"Starting lsm link status monitoring daemon");    
	$bal->start_lsm();
    }
}

sub write_lsm_config {
    my $bal = shift;

    my $lsm_conf = $bal->lsm_conf_file();

    my $old_text = '';
    open my $fh,$lsm_conf or die "$lsm_conf: $!";
    $old_text .= $_ while <$fh>;
    close $fh;

    my $new_text = $bal->lsm_config_text();
    return if $new_text eq $old_text;
    
    # Create config file
    open $fh,'>',$lsm_conf or die "$lsm_conf: $!";
    print $fh $new_text;
    close $fh or die "$lsm_conf: $!";
    
    return 1;
}

sub fatal_error {
    my $msg = shift;
    syslog('crit',$msg);
    croak $msg,"\n";
}

sub do_lock {
    my $lockfile = File::Spec->catfile(File::Spec->tmpdir,
				       "load_balance.$>.lock");
    open (my $fh,'>>',$lockfile) or fatal_error("Can't open $lockfile for locking");
    eval {
	local $SIG{ALRM} = sub { die "timeout" };
	alarm(LOCK_TIMEOUT);
	flock($fh,LOCK_EX)            or fatal_error("Can't lock $lockfile");
	alarm(0);
    };
    fatal_error("Lock timed out") if $@ =~ /timeout/;
    return $fh;
}


sub do_unlock {
    my $fh = shift;
    return unless $fh;
    flock($fh,LOCK_UN);
    my $lockfile = get_lockfile();
    unlink $lockfile;
}

sub get_lockfile {
    return File::Spec->catfile(File::Spec->tmpdir,
			       "load_balance.$>.lock");
}
