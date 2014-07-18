#
# (C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>
#
# License: GPLv2
#

VERSION	?= $(lastword $(shell grep ^Version: lsm.spec))
PROGS	= lsm
PKG     = lsm

CC	= gcc
override CFLAGS	+= -Wall -O2 -DLSM_VERSION=\"$(VERSION)\"
LDFLAGS =

.PHONY:	all clean distclean tar rpm

all: $(PROGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

lsm: lsm.o icmp_t.o icmp6_t.o config.o globals.o cksum.o forkexec.o signal_handler.o timecalc.o plugin_export.o save_statuses.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean distclean:
	rm -rf *~ .*~ *.o $(PROGS) Makefile.depend debugfiles.list debuglinks.list debugsources.list *.orig

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

Makefile.depend: *.c *.h Makefile
	$(CC) -MM *.c > $@

install: lsm
	mkdir -p ../blib/etc/balance/lsm
	mkdir -p ../blib/etc/balance/lsm/up.d
	mkdir -p ../blib/etc/balance/lsm/down.d
	mkdir -p ../blib/etc/balance/lsm/long_down.d
	touch ../blib/etc/balance/lsm/up.d/01.upevent
	touch ../blib/etc/balance/lsm/down.d/01.downevent
	touch ../blib/etc/balance/lsm/long_down.d/01.long_downevent
	chmod +x ../blib/etc/balance/lsm/*.d/*
	mkdir -p ../blib/bin
	install -m u=rwx,go=x     lsm ../blib/bin/
	install -m u=rwx,go=r default_script balancer_event_script ../blib/etc/balance/lsm/

-include Makefile.depend
