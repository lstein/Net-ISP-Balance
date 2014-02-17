#!/usr/bin/perl

use strict;
use warnings;
use Module::Build;

my $class = Module::Build->subclass(code=><<'EOF');
use File::Find 'find';
use File::Basename 'basename';

sub ACTION_build {
    my $self = shift;
    my $dir  = $self->base_dir();
    $self->SUPER::ACTION_build();
    chomp(my $make  = `which make`);
    chomp(my $nmake = `which nmake`);
    $make ||= $nmake;
    system "cd lsm; $make; cd $dir";
}

sub ACTION_clean {
    my $self = shift;
    my $dir  = $self->base_dir();
    $self->SUPER::ACTION_clean();
    system "cd lsm; make -s clean; cd $dir";
}


sub ACTION_install {
    my $self = shift;
    my $dir  = $self->base_dir();
    $self->SUPER::ACTION_install();
    system "cd lsm; make install; cd $dir";
    # my $dest = -e '/etc/network/balancer.conf' ? '/etc/network/balancer.conf.pkg-dist'
    # 	:  '/etc/network/balancer.conf';
    # $self->copy_if_modified(from   => './blib/etc/network/balancer.conf',
    # 			    to     => $dest);
    }

sub process_etc_files {
    my $self = shift;
    find({no_chdir=>1,
	  wanted => sub { return unless -f $File::Find::name;
			  my $bn = basename($_);
			  return if $bn =~ /~$/ || $bn =~ /^#/;
			  $self->copy_if_modified(from => $File::Find::name,
						  to_dir => './blib');
	  }},
	 './etc'
	);
}

EOF

my $build = $class->new(
    module_name       => 'Net-ISP-Balance',
    license           => 'perl',
    dist_version_from => 'lib/Net/ISP/Balance.pm',
    dist_abstract     => 'Load balance among two or more ISP connections',
    dist_author       => 'Lincoln Stein <lincoln.stein@gmail.com>',
    configure_requires => { 'Module::Build' => 0 },
    requires          => {
      'Net::Netmask'    => 0,
    },
    );

$build->add_build_element('etc');
$build->install_path('etc'    => '/etc');
$build->install_path('bin'=> '/etc/network');
$build->install_path('script'=> '/etc/network');
$build->create_build_script;
exit 0;
