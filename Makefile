CC ?= gcc
AR ?= ar
JULIA ?= julia

CPPFLAGS ?=
CPPFLAGS += -Iinclude -Igenerated
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic
SHARED_CFLAGS ?= -fPIC

BUILD_DIR := build
LIB_DIR := lib
ADAPTER_OBJ := $(BUILD_DIR)/julia_polycall.o
STATIC_LIB := $(LIB_DIR)/libjulia_polycall.a
TEST_BIN := $(BUILD_DIR)/julia_polycall_adapter_test

ifeq ($(OS),Windows_NT)
EXE_EXT := .exe
NATIVE_LIB := $(LIB_DIR)/julia_polycall.dll
MOCK_NATIVE_LIB := $(BUILD_DIR)/julia_polycall.dll
TEST_BIN := $(TEST_BIN)$(EXE_EXT)
else
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
NATIVE_LIB := $(LIB_DIR)/libjulia_polycall.dylib
MOCK_NATIVE_LIB := $(BUILD_DIR)/libjulia_polycall.dylib
else
NATIVE_LIB := $(LIB_DIR)/libjulia_polycall.so
MOCK_NATIVE_LIB := $(BUILD_DIR)/libjulia_polycall.so
endif
endif

.DEFAULT_GOAL := all

.PHONY: all
all: $(STATIC_LIB)

$(BUILD_DIR) $(LIB_DIR):
ifeq ($(OS),Windows_NT)
	@if not exist "$@" mkdir "$@"
else
	@mkdir -p $@
endif

$(ADAPTER_OBJ): c_src/julia_polycall.c include/julia_polycall.h generated/polycall/polycall_ffi.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

$(STATIC_LIB): $(ADAPTER_OBJ) | $(LIB_DIR)
	$(AR) rcs $@ $^

$(TEST_BIN): c_src/julia_polycall.c tests/polycall_ffi_mock.c tests/julia_polycall_adapter_test.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) -Itests $(CFLAGS) $^ -o $@

.PHONY: test
test: $(TEST_BIN)
	$(TEST_BIN)

.PHONY: native
native: | $(LIB_DIR)
ifeq ($(OS),Windows_NT)
	@if "$(strip $(POLYCALL_LDFLAGS))"=="" (echo Set POLYCALL_LDFLAGS to the libpolycall v1.5 linker flags & exit /b 2)
else
	@test -n "$(POLYCALL_LDFLAGS)" || (echo "Set POLYCALL_LDFLAGS to the libpolycall v1.5 linker flags" && exit 2)
endif
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SHARED_CFLAGS) -DJULIA_POLYCALL_BUILD_SHARED \
		-shared c_src/julia_polycall.c $(POLYCALL_LDFLAGS) -o $(NATIVE_LIB)

$(MOCK_NATIVE_LIB): c_src/julia_polycall.c tests/polycall_ffi_mock.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) -Itests $(CFLAGS) $(SHARED_CFLAGS) \
		-DJULIA_POLYCALL_BUILD_SHARED -shared $^ -o $@

.PHONY: test-julia
test-julia: $(MOCK_NATIVE_LIB)
ifeq ($(OS),Windows_NT)
	@set "JULIA_POLYCALL_LIBRARY=$(abspath $(MOCK_NATIVE_LIB))" && \
		$(JULIA) --project=. test/runtests.jl
else
	JULIA_POLYCALL_LIBRARY="$(abspath $(MOCK_NATIVE_LIB))" \
		$(JULIA) --project=. test/runtests.jl
endif

.PHONY: verify-dry
verify-dry:
ifeq ($(OS),Windows_NT)
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-dry.ps1
else
	sh scripts/verify-dry.sh
endif

.PHONY: clean
clean:
ifeq ($(OS),Windows_NT)
	@if exist "$(BUILD_DIR)" rmdir /s /q "$(BUILD_DIR)"
	@if exist "$(LIB_DIR)" rmdir /s /q "$(LIB_DIR)"
else
	rm -rf $(BUILD_DIR) $(LIB_DIR)
endif

-include $(ADAPTER_OBJ:.o=.d)
