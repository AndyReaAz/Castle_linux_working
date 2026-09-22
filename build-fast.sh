#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${KERNEL_OUT:-$ROOT/build-fast}"
ARCH=arm
TOOLCHAIN_PREFIX="${KERNEL_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"
CROSS_COMPILE="$TOOLCHAIN_PREFIX"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

export ARCH CROSS_COMPILE

[ -x "$ROOT/scripts/config" ] || {
    echo "error: scripts/config not found in $ROOT" >&2
    exit 1
}

if ! command -v "${TOOLCHAIN_PREFIX}gcc" >/dev/null 2>&1; then
    echo "error: ARM compiler not found: ${TOOLCHAIN_PREFIX}gcc" >&2
    echo "Set KERNEL_TOOLCHAIN_PREFIX=/path/to/arm-linux-gnueabihf-" >&2
    exit 1
fi

if [ "${KERNEL_CCACHE:-1}" = "1" ]; then
    command -v ccache >/dev/null 2>&1 || {
        echo "error: ccache requested but not found" >&2
        echo "Set KERNEL_CCACHE=0 only if you intentionally want an uncached build." >&2
        exit 1
    }
    CC="ccache ${TOOLCHAIN_PREFIX}gcc"
    HOSTCC="ccache gcc"
    HOSTCXX="ccache g++"
else
    CC="${TOOLCHAIN_PREFIX}gcc"
    HOSTCC="gcc"
    HOSTCXX="g++"
fi
export CC HOSTCC HOSTCXX

seed_config()
{
    mkdir -p "$OUT"

    if [ ! -f "$OUT/.config" ]; then
        base="${KERNEL_BASE_CONFIG:-}"
        if [ -z "$base" ] && [ -f "$ROOT/.config" ]; then
            base="$ROOT/.config"
        fi

        [ -n "$base" ] && [ -f "$base" ] || {
            echo "error: no base kernel configuration found" >&2
            echo "Set KERNEL_BASE_CONFIG=/path/to/known-good/.config" >&2
            exit 1
        }

        cp "$base" "$OUT/.config"
        echo "Seeded fast-boot config from $base"
    fi
}

configure_fast()
{
    seed_config

    if command -v lz4c >/dev/null 2>&1; then
        LZ4_TOOL=lz4c
    elif command -v lz4 >/dev/null 2>&1; then
        LZ4_TOOL=lz4
    else
        echo "error: host lz4/lz4c tool is required for CONFIG_KERNEL_LZ4" >&2
        echo "Install the system lz4 package, then rerun." >&2
        exit 1
    fi

    cfg="$ROOT/scripts/config"
    config="$OUT/.config"

    # Stage 1 fast-boot baseline: compression only.
    # Keep DTS, drivers, probe topology and video/display behaviour unchanged.
    "$cfg" --file "$config" -e KERNEL_LZ4
    for sym in \
        KERNEL_GZIP KERNEL_BZIP2 KERNEL_LZMA KERNEL_XZ \
        KERNEL_LZO KERNEL_ZSTD KERNEL_UNCOMPRESSED
    do
        "$cfg" --file "$config" -d "$sym"
    done

    make -C "$ROOT" O="$OUT" \
        ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        CC="$CC" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
        LZ4="$LZ4_TOOL" olddefconfig

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" || {
        echo "error: olddefconfig did not retain CONFIG_KERNEL_LZ4=y" >&2
        exit 1
    }
}

build_fast()
{
    make -C "$ROOT" O="$OUT" -j"$JOBS" \
        ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        CC="$CC" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
        LZ4="$LZ4_TOOL" zImage dtbs
}

case "${1:-build}" in
    clean)
        rm -rf "$OUT"
        echo "Removed $OUT"
        exit 0
        ;;
    config)
        configure_fast
        ;;
    rebuild)
        rm -rf "$OUT"
        configure_fast
        build_fast
        ;;
    build)
        configure_fast
        build_fast
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|clean]" >&2
        exit 2
        ;;
esac

config="$OUT/.config"

echo
echo "NextGen fast-boot kernel profile:"
echo "  ARCH          = $ARCH"
echo "  CROSS_COMPILE = $CROSS_COMPILE"
echo "  CC            = $CC"
echo "  HOSTCC        = $HOSTCC"
grep -E '^CONFIG_KERNEL_(LZ4|GZIP|BZIP2|LZMA|XZ|LZO|ZSTD|UNCOMPRESSED)=' "$config" || true

if [ -f "$OUT/arch/arm/boot/zImage" ]; then
    echo
    echo "Kernel image:"
    ls -lh "$OUT/arch/arm/boot/zImage"
fi

dtb=""
for candidate in \
    "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" \
    "$OUT/arch/arm/boot/dts/nextgen.dtb"
do
    if [ -f "$candidate" ]; then
        dtb="$candidate"
        break
    fi
done

if [ -n "$dtb" ]; then
    echo "Device tree:"
    ls -lh "$dtb"
fi

if [ "${KERNEL_CCACHE:-1}" = "1" ]; then
    echo
    ccache -s | sed -n '1,12p'
fi
