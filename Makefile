ZIG ?= $(shell if [ -x /opt/homebrew/bin/zig ] && /opt/homebrew/bin/zig version 2>/dev/null | grep -q "0.16."; then echo /opt/homebrew/bin/zig; elif command -v zig >/dev/null 2>&1 && zig version 2>/dev/null | grep -q "0.16."; then echo zig; else command -v zig 2>/dev/null || echo zig; fi)
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

TARGET = dush

# dush requires Zig 0.16.x
ZIG_VERSION := $(shell $(ZIG) version 2>/dev/null)
ifeq (,$(findstring 0.16.,$(ZIG_VERSION)))
$(error zig 0.16.x required (found $(ZIG_VERSION)))
endif

.PHONY: all clean install uninstall test bench

all: $(TARGET)

$(TARGET): build.zig build.zig.zon src/main.zig
	$(ZIG) build -Doptimize=ReleaseFast
	cp zig-out/bin/dush $(TARGET)

test:
	$(ZIG) build test
	python3 tests/test_dush.py

bench:
	$(ZIG) build bench

clean:
	rm -rf zig-out .zig-cache $(TARGET) .bench

install: $(TARGET)
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 755 $(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET)
