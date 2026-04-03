#!/bin/bash
# Workaround for Xcode 26.4 libtool silently dropping archive members
# that aren't 8-byte aligned (zig's ar writer produces archives with
# 2-byte alignment). We repack each input .a with Apple's ar before
# passing to libtool.
set -euo pipefail

ARGS=()
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
counter=0

for arg in "$@"; do
    if [[ "$arg" == *.a && -f "$arg" ]]; then
        # Resolve to absolute path
        abs=$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")
        # Repack the archive with Apple's ar to fix alignment
        dir="$TMPDIR/repack-$counter"
        counter=$((counter + 1))
        mkdir -p "$dir"
        (cd "$dir" && ar x "$abs" && chmod 644 *.o 2>/dev/null || true)
        repacked="$dir/repacked.a"
        ar rcs "$repacked" "$dir"/*.o
        ARGS+=("$repacked")
    else
        ARGS+=("$arg")
    fi
done

exec libtool "${ARGS[@]}"
