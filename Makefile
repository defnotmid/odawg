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

test:
	@mkdir -p $(BUILD_DIR)
	@for pkg in tempo theory dsp device analyze assets spec song render tests/registry; do \
		$(ODIN) test $$pkg $(FLAGS) -o:speed -out:$(BUILD_DIR)/test_$$(echo $$pkg | tr / _) || exit 1; \
	done

clean:
	@test -n "$(BUILD_DIR)" && test -n "$(OUT)"
	rm -f "$(OUT)" "$(BUILD_DIR)"/test_*

.PHONY: build speed test clean
