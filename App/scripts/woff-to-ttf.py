#!/usr/bin/env python3
# WOFF 1.0 -> TrueType, font tables byte-for-byte unchanged (the inverse of make-fonts.py).
#   App/scripts/woff-to-ttf.py IN.woff OUT.ttf
# bundle.sh ships the fonts as TTF: CoreText maps a TTF file (clean, shared pages) but inflates a
# WOFF into heap memory, twice per face (registration + first use), and keeps it: ~33 MB of the
# app's footprint for D2Coding Regular + Bold. The repo keeps the WOFFs (half the size).
import struct, sys, zlib

d = open(sys.argv[1], 'rb').read()
sig, flavor, _, nt = struct.unpack('>4sIIH', d[:14])
if sig != b'wOFF': sys.exit('error: %s is not a WOFF 1.0 file' % sys.argv[1])
recs = [struct.unpack('>4sIIII', d[44 + 20 * i:64 + 20 * i]) for i in range(nt)]
es = max(i for i in range(16) if 1 << i <= nt)
out = struct.pack('>IHHHH', flavor, nt, 16 << es, es, nt * 16 - (16 << es))
off, body = 12 + 16 * nt, b''
for tag, o, clen, olen, cs in recs:
    t = d[o:o + clen]
    if clen < olen: t = zlib.decompress(t)
    if len(t) != olen: sys.exit('error: table %s: %d bytes, expected %d' % (tag, len(t), olen))
    out += struct.pack('>4sIII', tag, cs, off + len(body), olen)
    body += t + b'\0' * (-olen % 4)
open(sys.argv[2], 'wb').write(out + body)
