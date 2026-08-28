TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(shell git -C "$(TEST_DIR)" rev-parse --show-toplevel)
LINUX_SRC ?= $(REPO_ROOT)/linux
LINUX_BUILD ?= $(LINUX_SRC)/build
LINUX_HEADERS ?= $(LINUX_BUILD)/headers
OUTPUT ?= $(REPO_ROOT)/busybox/build/sec.bin
CROSS_COMPILE ?= aarch64-linux-gnu-

.PHONY: all clean FORCE

all: $(OUTPUT)

# 每次构建都同步 UAPI header，保证测试程序使用当前 kernel ABI
$(OUTPUT): sec.c FORCE
	$(MAKE) -C "$(LINUX_SRC)" O="$(LINUX_BUILD)" ARCH=arm64 \
		INSTALL_HDR_PATH="$(LINUX_HEADERS)" headers_install
	mkdir -p "$(dir $(OUTPUT))"
	$(CROSS_COMPILE)gcc -static -Os -Wall -Wextra -Werror \
		-I "$(LINUX_HEADERS)/include" sec.c -o "$(OUTPUT)"

FORCE:

clean:
	$(RM) "$(OUTPUT)"
