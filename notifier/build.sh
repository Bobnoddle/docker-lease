#!/bin/bash
# build.sh — regenerate docker-lease-notifier.app from scratch.
#
# Produces a self-contained, ad-hoc-signed .app bundle whose only job is to post
# one notification per invocation (see Notify.swift). Requires the Swift
# toolchain: `xcode-select --install` or a full Xcode install.
#
# Usage:
#   ./build.sh                     # -> ~/.local/bin/docker-lease-notifier.app
#   ./build.sh --out /tmp/out      # -> /tmp/out/docker-lease-notifier.app
#   ./build.sh --icon path/to.png  # source artwork (default ../assets/icon/master.png)
#
# Env:
#   NOTIFIER_BUNDLE_ID   bundle identifier (default below)
#   ICON_SRC             same as --icon
#   OUT                  same as --out
#   SKIP_LSREGISTER=1    do not touch the LaunchServices database

# ---------------------------------------------------------------- BRAND ----
BRAND_PROJECT="docker-lease"
BRAND_OWNER="bobnoddle"
BRAND_NAMESPACE="io.github.${BRAND_OWNER}.docker-lease"
LAUNCHD_LABEL="${BRAND_NAMESPACE}.reaper"
NOTIFIER_BUNDLE_ID="${NOTIFIER_BUNDLE_ID:-${BRAND_NAMESPACE}-notifier}"
# ---------------------------------------------------------------------------

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="docker-lease-notifier.app"
EXEC_NAME="docker-lease-notify"
MIN_MACOS="13.0"

OUT="${OUT:-$HOME/.local/bin}"
ICON_SRC="${ICON_SRC:-$HERE/../assets/icon/master.png}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out)       OUT="${2:?--out needs a directory}"; shift 2 ;;
    --icon)      ICON_SRC="${2:?--icon needs a path}"; shift 2 ;;
    --bundle-id) NOTIFIER_BUNDLE_ID="${2:?--bundle-id needs a value}"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v swiftc >/dev/null 2>&1 || die "swiftc not found; install the Swift toolchain (xcode-select --install)"
command -v sips >/dev/null 2>&1 || die "sips not found (should ship with macOS)"
command -v iconutil >/dev/null 2>&1 || die "iconutil not found (should ship with macOS)"
[ -f "$ICON_SRC" ] || die "icon not found: $ICON_SRC"
[ -f "$HERE/Notify.swift" ] || die "Notify.swift missing next to build.sh"

APP="$OUT/$APP_NAME"
TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/docker-lease-iconset.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

say "docker-lease notifier build"
say "  bundle id : $NOTIFIER_BUNDLE_ID"
say "  icon      : $ICON_SRC"
say "  output    : $APP"

# ---------------------------------------------------------------- icon -----
# The master artwork is not square. sips --padToHeightWidth pads with an OPAQUE
# colour, which would put a white box behind the rounded icon. Compose onto a
# transparent 1024x1024 canvas instead, then let sips fan that out.
say "  icon: compositing $ICON_SRC onto a transparent 1024x1024 canvas"
cat >"$TMP/pad.swift" <<'SWIFT'
import AppKit
import Foundation

let a = CommandLine.arguments
guard a.count == 4, let side = Double(a[3]), side > 0,
      let src = NSImage(contentsOfFile: a[1]) else {
    FileHandle.standardError.write(Data("iconpad: bad arguments\n".utf8))
    exit(2)
}
let s = Int(side)
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(3) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: s, height: s).fill(using: .copy)
let m = src.size
let scale = min(side / m.width, side / m.height)
let w = m.width * scale, h = m.height * scale
src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
         from: .zero, operation: .sourceOver, fraction: 1.0)
ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
try png.write(to: URL(fileURLWithPath: a[2]))
SWIFT
swiftc -O "$TMP/pad.swift" -o "$TMP/iconpad"
"$TMP/iconpad" "$ICON_SRC" "$TMP/master-1024.png" 1024

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" \
            "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
  px="${spec%%:*}"; name="${spec#*:}"
  sips -z "$px" "$px" "$TMP/master-1024.png" --out "$ICONSET/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$TMP/AppIcon.icns"

# ---------------------------------------------------------------- bundle ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat >"$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$NOTIFIER_BUNDLE_ID</string>
  <key>CFBundleName</key><string>docker reaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLISTEOF

cp "$TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# ---------------------------------------------------------------- compile --
# Build each slice the SDK actually supports. If one arch fails we ship the
# other and SAY SO in the output, rather than failing the whole build on a
# toolchain that only has one of them.
SLICES=""
for arch in arm64 x86_64; do
  if swiftc -O -swift-version 5 -target "${arch}-apple-macos${MIN_MACOS}" \
       -o "$TMP/$EXEC_NAME-$arch" "$HERE/Notify.swift" 2>"$TMP/$arch.err"; then
    SLICES="$SLICES $arch"
    say "  compiled $arch slice"
  else
    warn "$arch slice failed (SDK or toolchain limitation); see output below"
    sed 's/^/    /' "$TMP/$arch.err" >&2 || true
  fi
done

[ -n "$SLICES" ] || die "no architecture compiled; cannot build the notifier"

# shellcheck disable=SC2086  # word splitting over the slice list is intended
lipo -create $(for a in $SLICES; do printf '%s ' "$TMP/$EXEC_NAME-$a"; done) \
  -output "$APP/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP/Contents/MacOS/$EXEC_NAME"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  || die "codesign failed for $APP"

if [ "${SKIP_LSREGISTER:-0}" != "1" ] && \
   [ -x "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" ]; then
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
    -f "$APP" >/dev/null 2>&1 || warn "lsregister failed (harmless: the bundle still runs)"
fi

say "built: $APP"
say "  arch        : $(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || echo unknown)"
say "  executable  : $APP/Contents/MacOS/$EXEC_NAME"
say "  signature   : $(codesign -dv "$APP" 2>&1 | awk -F= '/^Signature/{print $2} /^Authority/{print "authority=" $2; exit}')"
say ""
say "The new bundle id ($NOTIFIER_BUNDLE_ID) has no notification permission yet."
say "Grant it once, or the helper exits 3 and docker-lease falls back to osascript:"
say "  \"$APP/Contents/MacOS/$EXEC_NAME\" --request-authorization"
