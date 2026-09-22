# NavIC-SIPS firmware
#   make          build firmware.elf / .bin / .hex and print its size
#   make clean

CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
SIZE    := $(CROSS)size

ARCH    := -march=rv32imc -mabi=ilp32
CFLAGS  := $(ARCH) -Os -ffreestanding -fno-builtin -nostdlib \
           -Wall -Wextra -ffunction-sections -fdata-sections
LDFLAGS := $(ARCH) -nostdlib -T link.ld -Wl,--gc-sections -Wl,-Map=firmware.map

all: firmware.hex
	@$(SIZE) firmware.elf
	@echo "ROM image: $$(stat -c %s firmware.bin) bytes"

firmware.elf: start.S main.c sips.h link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S main.c -lgcc

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

# One 32-bit little-endian word per line, for $readmemh into the ROM.
firmware.hex: firmware.bin
	python3 -c "import sys; d=open('$<','rb').read(); d+=b'\0'*(-len(d)%4); \
open('$@','w').write(''.join('%08x\n'%int.from_bytes(d[i:i+4],'little') for i in range(0,len(d),4)))"

clean:
	rm -f firmware.elf firmware.bin firmware.hex firmware.map

.PHONY: all clean
