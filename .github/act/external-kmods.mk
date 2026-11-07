# Prerequisites and defconfig must be completed before entering this graph.
# Share dependencies between goals while retaining OpenWrt's jobserver export.
OPENWRT_BUILD := 1
export OPENWRT_BUILD
export MAKE_JOBSERVER = $(filter --jobserver%,$(MAKEFLAGS))
include Makefile
