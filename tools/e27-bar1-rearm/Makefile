# E27 experiment module — build against the running (or a target) kernel.
#   make                      # build against /lib/modules/$(uname -r)/build
#   make KDIR=/usr/src/kernels/7.0.9-204.fc44.x86_64
obj-m += tbegpu_bar1_rearm.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
