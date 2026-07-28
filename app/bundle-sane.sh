#!/bin/bash
# Assemble a relocatable copy of SANE (scanimage + the canon_dr backend) from
# the local Homebrew install into build/sane-bundle/, with all install names
# rewritten to @loader_path so it runs from inside the app bundle. build.sh
# copies the result into "P215 Scan.app/Contents/Frameworks/sane".
#
# Requires: brew install sane-backends
set -euo pipefail
cd "$(dirname "$0")"

CELLAR="$(brew --prefix sane-backends 2>/dev/null || true)"
if [ -z "$CELLAR" ] || [ ! -x "$CELLAR/bin/scanimage" ]; then
    echo "error: sane-backends not found; brew install sane-backends" >&2
    exit 1
fi
CELLAR="$(cd "$CELLAR" && pwd -P)"   # resolve the versioned Cellar path

OUT=build/sane-bundle
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib/sane" "$OUT/etc/sane.d" "$OUT/licenses"

cp "$CELLAR/bin/scanimage" "$OUT/bin/"
cp "$CELLAR/lib/libsane.1.dylib" "$OUT/lib/"
cp "$CELLAR/lib/sane/libsane-canon_dr.1.so" "$OUT/lib/sane/"
cp "$CELLAR/lib/sane/libsane-dll.1.so" "$OUT/lib/sane/" 2>/dev/null || true

# The dll meta-backend loads only what dll.conf lists.
echo canon_dr > "$OUT/etc/sane.d/dll.conf"
cp /opt/homebrew/etc/sane.d/canon_dr.conf "$OUT/etc/sane.d/" 2>/dev/null \
    || cp "$CELLAR/etc/sane.d/canon_dr.conf" "$OUT/etc/sane.d/"

# Pull in every Homebrew dylib the copied binaries reference, transitively.
closure_done=""
collect() {
    local f="$1"
    otool -L "$f" | awk 'NR>1 {print $1}' | { grep '^/opt/homebrew' || true; } | while read -r dep; do
        local base="$(basename "$dep")"
        if [ ! -f "$OUT/lib/$base" ] && [ "$base" != "libsane.1.dylib" ]; then
            cp "$(readlink -f "$dep")" "$OUT/lib/$base"
            collect "$OUT/lib/$base"
        fi
    done
}
collect "$OUT/bin/scanimage"
collect "$OUT/lib/libsane.1.dylib"
for so in "$OUT"/lib/sane/*.so; do collect "$so"; done

# Rewrite install names: each Mach-O points at its dependencies relative to
# itself, so the whole tree is position independent.
rewrite() {
    local f="$1" prefix="$2"
    install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
    otool -L "$f" | awk 'NR>1 {print $1}' | { grep '^/opt/homebrew' || true; } | while read -r dep; do
        install_name_tool -change "$dep" "$prefix/$(basename "$dep")" "$f" 2>/dev/null
    done
    codesign -s - -f "$f" 2>/dev/null
}
rewrite "$OUT/bin/scanimage" "@loader_path/../lib"
for lib in "$OUT"/lib/*.dylib; do rewrite "$lib" "@loader_path"; done
for so in "$OUT"/lib/sane/*.so; do rewrite "$so" "@loader_path/.."; done

# An invalid signature is a SIGKILL at load time on arm64 — verify every one.
for f in "$OUT/bin/scanimage" "$OUT"/lib/*.dylib "$OUT"/lib/sane/*.so; do
    codesign --verify --strict "$f" || { echo "error: bad signature on $f" >&2; exit 1; }
done

# GPL/LGPL compliance: ship the licenses and say where the source lives.
VERSION="$(basename "$CELLAR")"
cp "$CELLAR/COPYING" "$OUT/licenses/sane-backends.COPYING" 2>/dev/null || true
cat > "$OUT/licenses/NOTICE.txt" <<EOF
This directory contains an unmodified binary copy of sane-backends
$VERSION (GPL-2.0-or-later, with the SANE exception) and the libraries it
links against, built by Homebrew:

  sane-backends  https://gitlab.com/sane-project/backends
  libusb         https://libusb.info            (LGPL-2.1)
  libjpeg-turbo  https://libjpeg-turbo.org      (BSD-style)
  libpng         http://www.libpng.org          (libpng license)

Complete corresponding source for every component is available from the
URLs above and from Homebrew (https://github.com/Homebrew/homebrew-core);
the exact build recipes are the "sane-backends", "libusb", "jpeg-turbo"
and "libpng" formulae. The P215 Scan application invokes scanimage as a
separate process and is licensed independently (MIT).
EOF

echo "==> smoke test (relocated)"
SANE_CONFIG_DIR="$PWD/$OUT/etc/sane.d" "$OUT/bin/scanimage" --version

echo "Built: $OUT ($(du -sh "$OUT" | cut -f1))"
