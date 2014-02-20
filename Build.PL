#!/usr/bin/perl

use strict;
use warnings;
use Module::Build;

my $class = Module::Build->subclass(code=><<'EOF');
use File::Find 'find';
use File::Basename 'basename';

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
    mkdir '/var/lib/lsm';
    }

sub process_lsm_files {
     my $self = shift;
     my $dir  = $self->base_dir();
     $self->SUPER::ACTION_build();
     chomp(my $make  = `which make 2>/dev/null`);
     chomp(my $nmake = `which nmake 2>/dev/null`);
     $make ||= $nmake;
     system "cd lsm; $make install; cd $dir";
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
      'Net::Netmask'  => 0,
      'IO::String'    => 0,
    },
    );

my $install_etc =  -d '/etc/network'                   ? '/etc/network'
                 : -d '/etc/sysconfig/network-scripts' ? '/etc/sysconfig/network-scripts'
                 : '/etc/';

$build->add_build_element('etc');
$build->add_build_element('lsm');
$build->install_path('etc'       => $install_etc);
$build->install_path('bin'       => '/usr/local/bin');
$build->install_path('script'    => $install_etc);
$build->create_build_script;
exit 0;
