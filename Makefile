SHELL := /bin/bash

SBCL ?= sbcl
FILE_SERVER_IP ?= 10.0.2.2
LAMBDA64_DIR ?= Lambda64
IMAGE ?= lambda64.image
QEMU_SYSTEM_AARCH64 ?= qemu-system-aarch64
MEMORY ?= 2G
CPUS ?= 4
RESOLUTION ?= 1280x800

-include local.mk

LAMBDA64_ROOT := $(abspath $(LAMBDA64_DIR))
IMAGE_PATH := $(abspath $(IMAGE))
IMAGE_STEM := $(basename $(IMAGE_PATH))
IMAGE_MAP := $(IMAGE_STEM).map
IMAGE_SYMBOL_TABLE := $(IMAGE_STEM).symbol-table
KERNEL ?= $(LAMBDA64_ROOT)/tools/kboot/kboot-generic-arm64.bin
HOME_SUBMODULES := $(shell git config -f .gitmodules --get-regexp '^submodule\..*\.path$$' 2>/dev/null | awk '$$2 ~ /^home\// { print $$2 }')
LAMBDA64_SUBMODULE := $(if $(filter $(abspath Lambda64),$(LAMBDA64_ROOT)),Lambda64)

QEMU_COMMON_ARGS = \
	-name Lambda64-arm64 \
	-m $(MEMORY) \
	-smp $(CPUS) \
	-kernel $(KERNEL) \
	-serial stdio \
	-monitor none \
	-no-reboot \
	-device virtio-gpu-device,xres=$(word 1,$(subst x, ,$(RESOLUTION))),yres=$(word 2,$(subst x, ,$(RESOLUTION))) \
	-device virtio-keyboard-device \
	-device virtio-mouse-device \
	-drive if=none,file=$(IMAGE_PATH),id=blk,format=raw \
	-device virtio-blk-device,drive=blk \
	-netdev user,id=vmnic,hostname=lambda64,hostfwd=tcp:127.0.0.1:4005-:4005 \
	-device virtio-net-device,netdev=vmnic \
	-semihosting-config enable=on,target=native

all:
	@echo "LBuild quick start:"
	@echo "  1. cp local.mk.example local.mk   # recommended for sibling checkouts"
	@echo "  2. make deps"
	@echo "  3. make cold-image"
	@echo "  4. make run-file-server       # in a second terminal"
	@echo "  5. make qemu-arm64            # portable TCG"
	@echo "     make kvm-arm64             # Linux KVM"
	@echo "     make hvf-arm64             # Apple Silicon HVF"

cold-image: build-cold-image.lisp asdf
	@test -f "$(LAMBDA64_ROOT)/lispos.asd" || { \
		echo "Lambda64 checkout is missing at $(LAMBDA64_ROOT)" >&2; \
		exit 1; \
	}
	@echo "File server address: $(FILE_SERVER_IP)"
	@echo "Lambda64 source path: $(LAMBDA64_ROOT)/"
	@echo "Home directory path: $(CURDIR)/home/"
	@backup="$$(mktemp)"; \
	cp "$(LAMBDA64_ROOT)/config.lisp" "$$backup"; \
	trap 'cp "$$backup" "$(LAMBDA64_ROOT)/config.lisp"; rm -f "$$backup"' EXIT; \
	{ \
		echo '(in-package :mezzano.internals)'; \
		echo '(defparameter *file-server-host-ip* "$(FILE_SERVER_IP)")'; \
		echo '(defparameter *home-directory-path* "REMOTE:$(CURDIR)/home/")'; \
		echo '(defparameter *mezzano-source-path* "REMOTE:$(LAMBDA64_ROOT)/")'; \
		echo '(setf *compile-parallel* t)'; \
	} > "$(LAMBDA64_ROOT)/config.lisp"; \
	cd "$(LAMBDA64_ROOT)" && \
	LBUILD_OUTPUT="$(IMAGE_STEM)" "$(SBCL)" --dynamic-space-size 2048 --load "$(CURDIR)/build-cold-image.lisp"

run-file-server: run-file-server.lisp
	cd "$(LAMBDA64_ROOT)/file-server" && "$(SBCL)" --load "$(CURDIR)/run-file-server.lisp"

deps:
	git submodule update --init --recursive --jobs 4 $(HOME_SUBMODULES) $(LAMBDA64_SUBMODULE)

asdf: deps
	$(MAKE) -C home/asdf build/asdf.lisp

qemu: qemu-arm64
qemu-arm64:
	$(QEMU_SYSTEM_AARCH64) -machine virt -cpu max $(QEMU_COMMON_ARGS)

kvm: kvm-arm64
kvm-arm64:
	$(QEMU_SYSTEM_AARCH64) -machine virt -accel kvm -cpu host $(QEMU_COMMON_ARGS)

hvf: hvf-arm64
hvf-arm64:
	$(QEMU_SYSTEM_AARCH64) -machine virt,highmem=off -accel hvf -cpu host $(QEMU_COMMON_ARGS)

clean:
	rm -rf home/.cache/common-lisp/ home/.slime/ home/asdf/build/
	@if [ -d "$(LAMBDA64_ROOT)" ]; then \
		find "$(LAMBDA64_ROOT)" -name '*.llf' -type f -delete; \
	fi
	rm -f "$(IMAGE_PATH)" "$(IMAGE_MAP)" "$(IMAGE_SYMBOL_TABLE)"

.PHONY: all cold-image run-file-server deps asdf qemu qemu-arm64 kvm kvm-arm64 hvf hvf-arm64 clean
