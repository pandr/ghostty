# Ghostty Build Fix for Xcode 26.4

## Problem

Ghostty fails to compile with Xcode 26.4, producing hundreds of "Undefined symbols"
errors at the xcodebuild link stage. All ImGui, Sentry, and various other dependency
symbols are missing from `libghostty-fat.a`.

## Root Cause

**Apple's `libtool` in Xcode 26.4 silently drops archive members from `.a` files
produced by Zig's archive writer.**

Zig's `ar` writer produces static archives (`.a` files) with the traditional 2-byte
member alignment. Apple's `libtool` shipped with Xcode 26.4 (`cctools_ld-1266.8`)
now expects 8-byte alignment for 64-bit Mach-O members. When it encounters
non-8-byte-aligned members, it emits a warning but then **silently discards** most
of the misaligned `.o` files from the output.

This is a regression in Xcode 26.4's `libtool`. The older version
(`cctools-1030.6.3`, still available via Command Line Tools) handles the same
archives correctly.

## Evidence

The following experiment was run using the **exact same Zig-produced archive**
(`libdcimgui.a`, SHA256: `a66fbf11325c21ed305cc269f30265ff5931e20c2ad6595f73c8715a1e197cec`),
varying only the `libtool` binary — taken directly from Xcode 26.3 and Xcode 26.4
respectively. No other variables changed.

### libtool versions

```
# Xcode 26.3 libtool
$ strings libtool-xcode-26.3 | grep cctools
cctools-1030.6.3

# Xcode 26.4 libtool
$ strings /Applications/Xcode.app/.../libtool | grep -E 'PROGRAM:|PROJECT:'
@(#)PROGRAM:libtool  PROJECT:ld-1266.8
```

### Results: same archive, different libtool

| libtool | Source | Input members | Output members | Dropped |
|---|---|---|---|---|
| cctools-1030.6.3 | Xcode 26.3 | 12 | **12** | none |
| ld-1266.8 | Xcode 26.4 | 12 | **4** | **8 silently dropped** |

Xcode 26.4 `libtool` emitted **one** warning, but dropped **eight** members:

```
libtool: warning: 64-bit mach-o member 'dcimgui_internal.o' not 8-byte aligned
```

Members dropped (no warning emitted for any of these):

```
dcimgui_internal.o
dcimgui.o
imgui_demo.o
imgui_freetype.o
imgui_impl_metal.o
imgui_impl_osx.o
imgui_tables.o
imgui.o
```

Members retained (the 3 that happen to land on 8-byte boundaries):

```
imgui_draw.o
imgui_widgets.o
ext.o
```

### Fix confirmed: repacking with Apple `ar` restores all members

Repacking the same `.o` files with Apple's `ar` (which writes 8-byte aligned
archives) before passing to Xcode 26.4 `libtool` preserves all 12 members:

```bash
# Repack with Apple ar
mkdir /tmp/repack && cd /tmp/repack
ar x "$DCIMGUI" && chmod 644 *.o
ar rcs /tmp/repacked.a *.o

# Xcode 26.4 libtool now preserves all members
/Applications/Xcode.app/.../libtool -static -o /tmp/out.a /tmp/repacked.a
ar t /tmp/out.a  # 12 members, all present
```

Result: **12 members, no warnings, no drops**.

### How to reproduce

```bash
LIBTOOL_263=<path to Xcode 26.3 libtool binary>
LIBTOOL_264=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool
DCIMGUI=.zig-cache/o/6bde8890a49716c069ce6627f7aa5511/libdcimgui.a

# Build Ghostty first to populate the cache:
# zig build -Demit-macos-app=false

# Xcode 26.3 - all preserved
$LIBTOOL_263 -static -o /tmp/out-26.3.a "$DCIMGUI"
ar t /tmp/out-26.3.a    # 12 members

# Xcode 26.4 - 8 dropped
$LIBTOOL_264 -static -o /tmp/out-26.4.a "$DCIMGUI"
ar t /tmp/out-26.4.a    # 4 members

# Xcode 26.4 after repack - all preserved
mkdir /tmp/repack && cd /tmp/repack && ar x "$DCIMGUI" && chmod 644 *.o
ar rcs /tmp/repacked.a *.o
$LIBTOOL_264 -static -o /tmp/out-26.4-fixed.a /tmp/repacked.a
ar t /tmp/out-26.4-fixed.a  # 12 members
```

## Workaround Applied

Two files modified/added:

1. **`src/build/libtool-wrapper.sh`** - Shell script that extracts each input `.a`,
   re-archives the `.o` files with Apple's `ar` (which produces properly 8-byte
   aligned archives), then calls the real `libtool` with the repacked inputs.

2. **`src/build/LibtoolStep.zig`** - Modified to invoke the wrapper script instead
   of calling `libtool` directly.

This workaround is safe on all Xcode versions since Apple's `ar` always produces
valid archives.

## Upstream Issues

- **Zig**: Should produce 8-byte aligned archive members when targeting Apple
  platforms. This is the underlying issue. (No known upstream issue filed yet.)
- **Apple**: `libtool` should not silently drop archive members. At minimum it
  should error out rather than produce a corrupt output. This is a regression in
  `cctools_ld-1266.8`.

## Context

- Xcode 26.4 also broke Zig's compiler itself (separate issue), which was fixed
  in Zig 0.15.2 (backported by Homebrew). That fix addressed the compiler crash
  but not this archive alignment issue.
- The universal build (arm64 + x86_64) was additionally affected by Xcode 26.4
  being unable to compute the "active architecture" (`ONLY_ACTIVE_ARCH=YES`
  warning), causing it to build for all architectures including x86_64 which then
  failed to link. Using `-Dxcframework-target=native` avoids this, but the
  libtool fix was still required.

## Date

2026-04-01
