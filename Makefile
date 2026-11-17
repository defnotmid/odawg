ODIN ?= odin
BUILD_DIR ?= build
OUT ?= $(BUILD_DIR)/odawg
FLAGS ?= -collection:deps=..

build:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build tools/odawg $(FLAGS) -out:$(OUT)

speed:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build tools/odawg $(FLAGS) -o:speed -out:$(OUT)

PACKAGES := tempo theory dsp device analyze assets spec song render check tests/registry tests/sfz

test:
	@mkdir -p $(BUILD_DIR)
	@for pkg in $(PACKAGES); do \
		$(ODIN) test $$pkg $(FLAGS) -o:speed -out:$(BUILD_DIR)/test_$$(echo $$pkg | tr / _) || exit 1; \
	done

# -vet -strict-style over every package (its tests too) and both tools, the
# tools for each desktop target.
check:
	@for pkg in base $(PACKAGES); do \
		$(ODIN) check $$pkg $(FLAGS) -vet -strict-style -no-entry-point || exit 1; \
	done
	@for tool in tools/odawg tools/mascot; do \
		for target in linux_amd64 windows_amd64 darwin_arm64; do \
			$(ODIN) check $$tool $(FLAGS) -vet -strict-style -target:$$target || exit 1; \
		done; \
	done

clean:
	@test -n "$(BUILD_DIR)" && test -n "$(OUT)"
	rm -f "$(OUT)" "$(BUILD_DIR)"/test_*

.PHONY: build speed test check clean
