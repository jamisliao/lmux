#!/usr/bin/env python3
# Bundled fonts: D2Coding Regular + Bold as WOFF 1.0, from the upstream .ttc
# (D2Coding-*-all.ttc; its two "ligature" faces are not bundled).
#   App/scripts/make-fonts.py TTC OUTDIR
#   App/scripts/make-fonts.py assets/fonts/D2Coding-Ver1.3.3-20260725-all.ttc App/Resources/Fonts
# If TTC doesn't exist (the public repo doesn't ship it), the official release zip is downloaded
# (URL and sha256 pinned below, both checked) and the .ttc is read from it in memory.
# D2Coding .ttc -> one WOFF 1.0 per weight (Regular, Bold), font tables byte-for-byte
# unchanged (zlib-compressed only, no WOFF metadata): an OFL "not a Modified Version" conversion.
import hashlib, io, os, struct, sys, urllib.request, zipfile, zlib

# naver/d2codingfont release VER1.3.3 (the WOFFs in App/Resources/Fonts come from it).
ZIP_URL = 'https://github.com/naver/d2-coding-font/releases/download/VER1.3.3/D2Coding-Ver1.3.3-20260725.zip'
ZIP_SHA256 = 'c2a6e364d4102eb2c4de52ffe3d76317c1f4c045e3737e022e69ee0be47f31e2'
TTC_IN_ZIP = 'D2CodingAll/D2Coding-Ver1.3.3-20260725-all.ttc'
TTC_SHA256 = 'db293f7f1652adb9b120c1fef27337ba3bae59a6f77bdc6a23a07dddcc697402'


def fetch_ttc():
    print('%s not found: downloading %s' % (src, ZIP_URL), file=sys.stderr)
    z = urllib.request.urlopen(ZIP_URL, timeout=120).read()
    if hashlib.sha256(z).hexdigest() != ZIP_SHA256:
        sys.exit('error: %s does not match the pinned sha256; not using it' % ZIP_URL)
    d = zipfile.ZipFile(io.BytesIO(z)).read(TTC_IN_ZIP)
    if hashlib.sha256(d).hexdigest() != TTC_SHA256:
        sys.exit('error: %s in the zip does not match the pinned sha256' % TTC_IN_ZIP)
    return d


src, outdir = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read() if os.path.exists(src) else fetch_ttc()
n = struct.unpack('>I', d[8:12])[0]
for o in struct.unpack('>%dI' % n, d[12:12 + 4 * n]):
    sfnt, nt = struct.unpack('>IH', d[o:o + 6])
    recs = sorted([struct.unpack('>4sIII', d[o + 12 + 16 * i:o + 28 + 16 * i]) for i in range(nt)], key=lambda r: r[0])
    t = {r[0]: r for r in recs}
    _, _, no, nl = t[b'name']
    fmt, cnt, so = struct.unpack('>HHH', d[no:no + 6])
    nm = {}
    for i in range(cnt):
        p, e, l, nid, ln, lo = struct.unpack('>6H', d[no + 6 + 12 * i:no + 18 + 12 * i])
        if p == 3 and nid in (1, 2): nm[nid] = d[no + so + lo:no + so + lo + ln].decode('utf-16-be')
    if nm.get(1) != 'D2Coding': continue
    hdr = 44 + 20 * nt
    dirs, blobs = b'', b''
    sfnt_size = 12 + 16 * nt
    for tag, cs, to, tl in recs:
        raw = d[to:to + tl]
        comp = zlib.compress(raw, 9)
        data = comp if len(comp) < tl else raw
        dirs += struct.pack('>4sIIII', tag, hdr + len(blobs), len(data), tl, cs)
        blobs += data + b'\0' * ((4 - len(data) % 4) % 4)
        sfnt_size += tl + (4 - tl % 4) % 4
    total = hdr + len(blobs)
    head = struct.pack('>4sIIHHIHHIIIII', b'wOFF', sfnt, total, nt, 0, sfnt_size, 1, 0, 0, 0, 0, 0, 0)
    fn = '%s/D2Coding-%s.woff' % (outdir, nm[2])
    open(fn, 'wb').write(head + dirs + blobs)
    print(fn, total)
