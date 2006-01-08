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
