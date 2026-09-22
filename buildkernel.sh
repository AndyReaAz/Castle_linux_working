#!/bin/sh
exec make -j"$(nproc)" \
	ARCH=arm \
	CROSS_COMPILE=arm-linux-gnueabihf- \
	CC="ccache arm-linux-gnueabihf-gcc" \
	HOSTCC="ccache gcc" \
	HOSTCXX="ccache g++" \
	"$@"
    