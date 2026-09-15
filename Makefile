SHELL := /bin/bash

SBCL ?= sbcl
FILE_SERVER_IP ?= 10.0.2.2
LAMBDA64_DIR ?= Lambda64
IMAGE ?= lambda64.image
QEMU_SYSTEM_AARCH64 ?= qemu-system-aarch64
MEMORY ?= 4G
CPUS ?= 4
RESOLUTION ?= 1280x800
QUICKLISP_SETUP ?= $(or $(firstword $(wildcard $(HOME)/quicklisp/setup.lisp $(HOME)/.quicklisp/setup.lisp)),$(HOME)/quicklisp/setup.lisp)
LOCAL_TEST_TIMEOUT_SECONDS ?= 4800
STRESS_REPETITIONS ?= 3
TEST_RESULTS_ROOT ?= $(CURDIR)/test-results

-include local.mk

LAMBDA64_ROOT := $(abspath $(LAMBDA64_DIR))
IMAGE_PATH := $(abspath $(IMAGE))
IMAGE_STEM := $(basename $(IMAGE_PATH))
IMAGE_MAP := $(IMAGE_STEM).map
IMAGE_SYMBOL_TABLE := $(IMAGE_STEM).symbol-table
TEST_MANIFEST := $(IMAGE_STEM).test-manifest
KERNEL ?= $(LAMBDA64_ROOT)/tools/kboot/kboot-generic-arm64.bin

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
	@echo "  1. make deps"
	@echo "  2. make cold-image"
	@echo "     make test-fast               # host + build + ARM64 codegen tests"
	@echo "     make test-integration        # build once, positive + injected QEMU boots"
	@echo "     make test-all                # complete local suite including stress"
	@echo "  3. make run-file-server       # in a second terminal"
	@echo "  4. make qemu-arm64            # portable TCG"
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
	@./scripts/with-temporary-config.sh \
		"$(LAMBDA64_ROOT)/config.lisp" \
		"$(FILE_SERVER_IP)" \
		"$(CURDIR)/home/" \
		"$(LAMBDA64_ROOT)/" \
		-- bash -c 'cd "$$1" && CI="$$2" LBUILD_OUTPUT="$$3" "$$4" --dynamic-space-size 2048 --load "$$5"' \
		bash "$(LAMBDA64_ROOT)" "$(CI)" "$(IMAGE_STEM)" "$(SBCL)" "$(CURDIR)/build-cold-image.lisp"

test-image:
	@$(MAKE) --no-print-directory \
		CI=true \
		SBCL="$(SBCL)" \
		FILE_SERVER_IP="$(FILE_SERVER_IP)" \
		LAMBDA64_DIR="$(LAMBDA64_DIR)" \
		IMAGE="$(IMAGE)" \
		QEMU_SYSTEM_AARCH64="$(QEMU_SYSTEM_AARCH64)" \
		cold-image
	@./scripts/assert-test-image-artifacts.sh \
		"$(IMAGE_PATH)" \
		"$(IMAGE_MAP)" \
		"$(IMAGE_SYMBOL_TABLE)"
	@./scripts/write-test-manifest.sh \
		"$(IMAGE_PATH)" \
		"$(TEST_MANIFEST)" \
		"$(CURDIR)" \
		"$(SBCL)" \
		"$(QEMU_SYSTEM_AARCH64)" \
		'make test-image IMAGE=$(IMAGE) LAMBDA64_DIR=$(LAMBDA64_DIR)'

test-scripts:
	@./scripts/tests/test-lbuild-scripts.sh

test-unit: test-scripts
	@$(LAMBDA64_ROOT)/tests/host/run.sh

test-codegen:
	@LAMBDA64_QUICKLISP_SETUP="$(QUICKLISP_SETUP)" \
		$(LAMBDA64_ROOT)/tools/ci/test-arm64-scavenge-codegen.sh "$(LAMBDA64_ROOT)"
	@LAMBDA64_QUICKLISP_SETUP="$(QUICKLISP_SETUP)" \
		$(LAMBDA64_ROOT)/tools/ci/test-arm64-nlx-ssa-codegen.sh "$(LAMBDA64_ROOT)"

test-fast: test-unit test-codegen
	@echo "Local fast test layers passed"

docs-check:
	@python3 scripts/check-docs.py

todo-fixme-check:
	@python3 scripts/check-todo-fixme.py --verify

lisp-style-check:
	@$(LAMBDA64_ROOT)/tests/host/test-first-party-source-hygiene.sh
	@$(LAMBDA64_ROOT)/tests/host/test-first-party-generic-declarations.sh

style-check: lisp-style-check

test-integration: test-fast test-image
	@./scripts/run-local-test-matrix.sh \
		--suite integration \
		--lambda64-root "$(LAMBDA64_ROOT)" \
		--image "$(IMAGE_PATH)" \
		--manifest "$(TEST_MANIFEST)" \
		--fixture-root "$(CURDIR)/home" \
		--results-root "$(TEST_RESULTS_ROOT)" \
		--timeout "$(LOCAL_TEST_TIMEOUT_SECONDS)" \
		--sbcl "$(SBCL)"

test-stress: test-fast test-image
	@./scripts/run-local-test-matrix.sh \
		--suite stress \
		--lambda64-root "$(LAMBDA64_ROOT)" \
		--image "$(IMAGE_PATH)" \
		--manifest "$(TEST_MANIFEST)" \
		--fixture-root "$(CURDIR)/home" \
		--results-root "$(TEST_RESULTS_ROOT)" \
		--timeout "$(LOCAL_TEST_TIMEOUT_SECONDS)" \
		--stress-repetitions "$(STRESS_REPETITIONS)" \
		--sbcl "$(SBCL)"

test-local: test-integration

test-all: test-integration test-stress
	@echo "Complete local Lambda64 test system passed"

run-file-server: run-file-server.lisp
	cd "$(LAMBDA64_ROOT)/file-server" && "$(SBCL)" --load "$(CURDIR)/run-file-server.lisp"

# The home/ libraries used to be git submodules and are now tracked directly, so
# there is nothing to fetch.  The target stays because it is in every set of
# build instructions and in muscle memory; making it vanish would only produce
# confusing "No rule to make target" errors.
deps:
	@echo "home/ libraries are tracked in-tree; nothing to fetch."

asdf: deps
	$(MAKE) -C home/asdf build/asdf.lisp

# Boot an existing image directly.  A snapshotted image resumes -- threads,
# desktop and network come back from the image -- so this needs no file server
# and compiles nothing.  The qemu/kvm/hvf targets below exist to bring a cold
# image up for the first time, which does need one.
boot:
	@./scripts/boot-image.sh $(BOOT_ARGS)

qemu: qemu-arm64
qemu-arm64:
	$(QEMU_SYSTEM_AARCH64) -machine virt -cpu max $(QEMU_COMMON_ARGS)

kvm: kvm-arm64
kvm-arm64:
	$(QEMU_SYSTEM_AARCH64) -machine virt -accel kvm -cpu host $(QEMU_COMMON_ARGS)

hvf: hvf-arm64
hvf-arm64:
	@# highmem stays enabled: highmem=off caps guest RAM below the 4GB line
	@# ("Addressing limited to 32 bits"), and stage-four dependency loading
	@# needs more than that to avoid paging out function pages -- a no-IRQ
	@# region that touches one dies with page-fault-no-irqs.
	$(QEMU_SYSTEM_AARCH64) -machine virt -accel hvf -cpu host $(QEMU_COMMON_ARGS)

clean:
	rm -rf home/.cache/common-lisp/ home/.slime/ home/asdf/build/
	@if [ -d "$(LAMBDA64_ROOT)" ]; then \
		find "$(LAMBDA64_ROOT)" -name '*.llf' -type f -delete; \
	fi
	rm -f "$(IMAGE_PATH)" "$(IMAGE_MAP)" "$(IMAGE_SYMBOL_TABLE)" "$(TEST_MANIFEST)"

.PHONY: all cold-image test-image test-scripts test-unit test-codegen test-fast docs-check todo-fixme-check lisp-style-check style-check test-integration test-stress test-local test-all run-file-server deps asdf qemu qemu-arm64 kvm kvm-arm64 hvf hvf-arm64 clean
