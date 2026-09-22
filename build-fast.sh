#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
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

if ! command -v lz4 >/dev/null 2>&1; then
    echo "error: host lz4 tool is required for CONFIG_KERNEL_LZ4" >&2
    echo "Install the system lz4 package, then rerun." >&2
    exit 1
fi

if [ ! -f "$ROOT/.config" ]; then
    if [ -n "${KERNEL_BASE_CONFIG:-}" ] && [ -f "$KERNEL_BASE_CONFIG" ]; then
        cp "$KERNEL_BASE_CONFIG" "$ROOT/.config"
        echo "Seeded .config from $KERNEL_BASE_CONFIG"
    else
        echo "error: no kernel .config in $ROOT" >&2
        echo "Set KERNEL_BASE_CONFIG=/path/to/known-good/.config on the first run." >&2
        exit 1
    fi
fi

if [ ! -f "$ROOT/.config.pre-fastboot" ]; then
    cp "$ROOT/.config" "$ROOT/.config.pre-fastboot"
fi

cfg="$ROOT/scripts/config"
config="$ROOT/.config"

# Stage 1 fast-boot baseline: compression only.
# Keep the DTS and driver/probe topology exactly as the current meter build.
"$cfg" --file "$config" -e KERNEL_LZ4
for sym in KERNEL_GZIP KERNEL_BZIP2 KERNEL_LZMA KERNEL_XZ KERNEL_LZO KERNEL_ZSTD KERNEL_UNCOMPRESSED; do
    "$cfg" --file "$config" -d "$sym"
done

make_args="ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE"

if command -v ccache >/dev/null 2>&1 && [ "${KERNEL_CCACHE:-1}" = "1" ]; then
    CC="ccache ${TOOLCHAIN_PREFIX}gcc"
    HOSTCC="ccache gcc"
    HOSTCXX="ccache g++"
else
    CC="${TOOLCHAIN_PREFIX}gcc"
    HOSTCC="gcc"
    HOSTCXX="g++"
fi
export CC HOSTCC HOSTCXX

make -C "$ROOT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    CC="$CC" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" olddefconfig

grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" || {
    echo "error: olddefconfig did not retain CONFIG_KERNEL_LZ4=y" >&2
    exit 1
}

case "${1:-build}" in
    config)
        ;;
    clean)
        make -C "$ROOT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" clean
        ;;
    rebuild)
        make -C "$ROOT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" clean
        make -C "$ROOT" -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
            CC="$CC" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" zImage dtbs
        ;;
    build)
        make -C "$ROOT" -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
            CC="$CC" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" zImage dtbs
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|clean]" >&2
        exit 2
        ;;
esac

echo
echo "NextGen fast-boot kernel profile:"
grep -E '^CONFIG_KERNEL_(LZ4|GZIP|BZIP2|LZMA|XZ|LZO|ZSTD|UNCOMPRESSED)=' "$config" || true

if [ -f "$ROOT/arch/arm/boot/zImage" ]; then
    echo
    echo "Kernel image:"
    ls -lh "$ROOT/arch/arm/boot/zImage"
fi

dtb=""
for candidate in \
    "$ROOT/arch/arm/boot/dts/microchip/nextgen.dtb" \
    "$ROOT/arch/arm/boot/dts/nextgen.dtb"
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

if command -v ccache >/dev/null 2>&1 && [ "${KERNEL_CCACHE:-1}" = "1" ]; then
    echo
    ccache -s | sed -n '1,12p'
fi
