# Makefile workaround for Zig build system issues on ARM64 Debian
ZIG = /usr/local/bin/zig
TARGET = native-linux-gnu
OPTIMIZE = ReleaseFast
OUTPUT = zig-out/bin/blitz

.PHONY: all clean run

all: $(OUTPUT)

$(OUTPUT): src/main.zig src/bind_wrapper.c
	@mkdir -p zig-out/bin
	@echo "Finding liburing headers..."
	@INCLUDE_PATH=$$(find /usr/include -name 'liburing.h' 2>/dev/null | head -1 | xargs dirname); \
	if [ -z "$$INCLUDE_PATH" ]; then \
		INCLUDE_PATH="/usr/include"; \
	fi; \
	echo "Using include path: $$INCLUDE_PATH"; \
	echo "Compiling bind_wrapper.c with gcc..."; \
	gcc -c -O3 -D_GNU_SOURCE -I$$INCLUDE_PATH src/bind_wrapper.c -o /tmp/bind_wrapper.o; \
	echo "Building Blitz..."; \
	cd zig-out/bin && $(ZIG) build-exe -O $(OPTIMIZE) -fstrip -target $(TARGET) \
		-lc -I$$INCLUDE_PATH -I../../src \
		../../src/main.zig /tmp/bind_wrapper.o \
		/usr/lib/aarch64-linux-gnu/liburing.so.2.3; \
	if [ -f main ] && [ ! -f ../../$(OUTPUT) ]; then mv main ../../$(OUTPUT); fi; \
	if [ -f blitz ] && [ ! -f ../../$(OUTPUT) ]; then mv blitz ../../$(OUTPUT); fi; \
	if [ ! -f ../../$(OUTPUT) ] && [ -f main ]; then cp main ../../$(OUTPUT); fi; \
	if [ ! -f ../../$(OUTPUT) ] && [ -f blitz ]; then cp blitz ../../$(OUTPUT); fi
	@chmod +x $(OUTPUT)
	@echo "✅ Build complete: $(OUTPUT)"

clean:
	rm -rf zig-out /tmp/bind_wrapper.o

run: $(OUTPUT)
	./$(OUTPUT)

