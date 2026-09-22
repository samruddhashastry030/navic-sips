"""Build a test SPI-flash image: 512-word weight image + checksum word.

Header uses realistic values: slot 0 mu = 0.125, slot 2 1/sd = 1.2695
(0x0145, what the shipping model stores). Remaining slots pseudo-random.
Checksum is the firmware's rotate-left-1-then-xor over the 512 words.
"""
import random
random.seed(7)

MU, INVSD = 0x0020, 0x0145
words = [random.getrandbits(32) for _ in range(512)]
words[0] = (MU << 16) | MU            # slots 0,1
words[1] = (INVSD << 16) | INVSD      # slots 2,3
words[2] = (words[2] & 0xFFFF0000) | 0x0083   # slot 4, threshold

csum = 0
for w in words:
    csum = (((csum << 1) | (csum >> 31)) & 0xFFFFFFFF) ^ w

with open("wimage.hex", "w") as f:
    for w in words: f.write("%08x\n" % w)
with open("flash.hex", "w") as f:           # one byte per line, little-endian
    for w in words + [csum]:
        for b in range(4): f.write("%02x\n" % ((w >> (8 * b)) & 0xFF))
print("mu=0x%04x invsd=0x%04x checksum=0x%08x bytes=%d"
      % (MU, INVSD, csum, (len(words) + 1) * 4))
