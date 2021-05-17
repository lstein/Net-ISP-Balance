#
# (C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>
#
# License: GPLv2
#

VERSION	?= $(lastword $(shell grep ^Version: foolsm.spec))
PROGS	= foolsm
PKG     = foolsm

CC	= gcc
override CFLAGS	+= -w -O2 -DFOOLSM_VERSION=\"$(VERSION)\"
#override CFLAGS += -D NO_PLUGIN_EXPORT
#override CFLAGS += -D NO_PLUGIN_EXPORT_MUNIN
#override CFLAGS += -D NO_PLUGIN_EXPORT_STATUS

PREFIX ?= /usr/local
DESTDIR ?=
BINDIR ?= $(PREFIX)/sbin
ifeq ($(PREFIX), /usr)
ETCDIR ?= /etc/foolsm
else
ETCDIR ?= $(PREFIX)/etc/foolsm
endif
DOCDIR ?= $(PREFIX)/share/doc/foolsm
EXAMPLEDIR ?= $(DOCDIR)/examples
SCRIPTDIR ?= $(PREFIX)/libexec/foolsm

DOCFILES = README foolsm.conf.sample default_script.sample rsyslog-foolsm.conf.sample
SCRIPTS	= shorewall_script shorewall6_script default_script group_script

override CFLAGS += -D ETCDIR=\"$(ETCDIR)\"
override CFLAGS += -D SCRIPTDIR=\"$(SCRIPTDIR)\"

.PHONY:	all clean distclean tar rpm

all: $(PROGS)

foolsm: foolsm.o icmp_t.o icmp6_t.o config.o globals.o cksum.o forkexec.o signal_handler.o timecalc.o plugin_export.o save_statuses.o pidfile.o cmdline.o usage.o

clean distclean:
	rm -rf *~ .*~ *.o $(PROGS) debugfiles.list debuglinks.list debugsources.list *.orig

tar: distclean
	tar zcvf ../$(PKG)-$(VERSION).tar.gz \
		--transform=s,.,$(PKG)-$(VERSION), \
		--show-transformed-name \
		--exclude .git \
		--exclude .gitignore \
		.

rpm: tar
	cp ../$(PKG)-$(VERSION).tar.gz ~/rpmbuild/SOURCES
	cp $(PKG).spec ~/rpmbuild/SPECS
	rpmbuild -ba ~/rpmbuild/SPECS/$(PKG).spec

install: foolsm
	@mkdir -p ../blib/etc/balance/lsm
	@mkdir -p ../blib/bin
	@install -m u=rwx,go=x     foolsm ../blib/bin/
	@install -m u=rwx,go=r default_script balancer_event_script ../blib/etc/balance/lsm/
