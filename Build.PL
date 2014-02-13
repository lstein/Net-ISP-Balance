#!/usr/bin/perl

use strict;
use warnings;
use Module::Build;

my $class = Module::Build->subclass(code=><<EOF);
    sub ACTION_build {
	my \$self = shift;
	\$self->SUPER::ACTION_build();
	chomp(my \$make  = `which make`);
	chomp(my \$nmake = `which nmake`);
	\$make ||= \$nmake;
	system "cd lsm; \$make";
    }

    sub ACTION_clean {
	my \$self = shift;
	\$self->SUPER::ACTION_clean();
        system "cd lsm; make -s clean";
    }


    sub ACTION_install {
	my \$self = shift;
	\$self->SUPER::ACTION_install();
        system "cd lsm; make install";
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

$build->create_build_script;
exit 0;
