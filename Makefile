# Makefile
# Copyright © 1998-1999 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

CC = gcc
CFLAGS = -O2 -Wall -g
LD = gcc
LDFLAGS = 

PRGS = wanna-build-mail buildd-mail-wrapper

all: $(PRGS)

wanna-build-mail: wanna-build-mail.c
	$(CC) $(CFLAGS) -o $@ $^
	strip $@

buildd-mail-wrapper: buildd-mail-wrapper.c
	$(CC) $(CFLAGS) -o $@ $^
	strip $@

clean: 
	rm -f $(PRGS)
