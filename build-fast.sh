#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${KERNEL_OUT:-$ROOT/build-fast}"
ARCH=arm
TOOLCHAIN_PREFIX="${KERNEL_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"
CROSS_COMPILE="$TOOLCHAIN_PREFIX"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
EXPECTED_RELEASE="6.6.23-linux4microchip-2024.04+"

export ARCH CROSS_COMPILE

die()
{
    echo "error: $*" >&2
    exit 1
}

[ -x "$ROOT/scripts/config" ] || die "scripts/config not found in $ROOT"
command -v "${TOOLCHAIN_PREFIX}gcc" >/dev/null 2>&1 ||
    die "ARM compiler not found: ${TOOLCHAIN_PREFIX}gcc"

if [ "${KERNEL_CCACHE:-1}" = "1" ]; then
    command -v ccache >/dev/null 2>&1 ||
        die "ccache requested but not found"
    CC="ccache ${TOOLCHAIN_PREFIX}gcc"
    HOSTCC="ccache gcc"
    HOSTCXX="ccache g++"
else
    CC="${TOOLCHAIN_PREFIX}gcc"
    HOSTCC="gcc"
    HOSTCXX="g++"
fi
export CC HOSTCC HOSTCXX

find_lz4()
{
    if command -v lz4c >/dev/null 2>&1; then
        LZ4_TOOL=lz4c
    elif command -v lz4 >/dev/null 2>&1; then
        LZ4_TOOL=lz4
    else
        die "host lz4/lz4c tool is required"
    fi
}

seed_config()
{
    mkdir -p "$OUT"

    base="${KERNEL_BASE_CONFIG:-}"

    if [ -n "$base" ]; then
        [ -f "$base" ] ||
            die "KERNEL_BASE_CONFIG does not exist: $base"
        cp "$base" "$OUT/.config"
        echo "Seeded fast-boot config from $base"
    elif [ ! -f "$OUT/.config" ]; then
        if [ -f "$ROOT/.config" ]; then
            cp "$ROOT/.config" "$OUT/.config"
            echo "Seeded fast-boot config from $ROOT/.config"
        else
            die "no base config; set KERNEL_BASE_CONFIG=/path/to/known-good/config"
        fi
    fi

    grep -q '^CONFIG_ARCH_AT91=y$' "$OUT/.config" ||
        die "base config is not AT91"
    grep -q '^CONFIG_SOC_SAMA5D2=y$' "$OUT/.config" ||
        die "base config is not SAMA5D2"
}

make_kernel()
{
    make -C "$ROOT" O="$OUT"         ARCH="$ARCH"         CROSS_COMPILE="$CROSS_COMPILE"         CC="$CC"         HOSTCC="$HOSTCC"         HOSTCXX="$HOSTCXX"         LZ4="$LZ4_TOOL"         LOCALVERSION=         "$@"
}

show_config()
{
    echo
    echo "NextGen fast-boot kernel profile:"
    echo "  ARCH          = $ARCH"
    echo "  CROSS_COMPILE = $CROSS_COMPILE"
    echo "  CC            = $CC"
    echo "  HOSTCC        = $HOSTCC"
    echo "  RELEASE       = ${KERNELRELEASE:-not-built}"

    grep -E '^CONFIG_MODULES=' "$OUT/.config" || true
    grep -E '^CONFIG_KERNEL_(LZ4|GZIP|BZIP2|LZMA|XZ|LZO|ZSTD|UNCOMPRESSED)=' "$OUT/.config" || true
    grep -E '^CONFIG_(ARCH_AT91|SOC_SAMA5D2|ATMEL_SSC|SND_ATMEL_SOC|SND_ATMEL_SOC_SSC_DMA|SND_ATMEL_SOC_SSC|TI_ADS131A|SND_AUDIO_GRAPH_CARD2|SND_SOC_ADS131A_CODEC)=' "$OUT/.config" || true
}

configure_fast()
{
    seed_config
    find_lz4

    cfg="$ROOT/scripts/config"
    config="$OUT/.config"

    # Stage 1 fast-boot baseline: compression only.
    # Preserve the known-good NextGen hardware/driver configuration.
    "$cfg" --file "$config" -e KERNEL_LZ4
    for sym in         KERNEL_GZIP         KERNEL_BZIP2         KERNEL_LZMA         KERNEL_XZ         KERNEL_LZO         KERNEL_ZSTD         KERNEL_UNCOMPRESSED
    do
        "$cfg" --file "$config" -d "$sym"
    done

    # Keep the deployed kernel/module release directory stable despite the
    # snapshot-style Git history used by the working mirror.
    "$cfg" --file "$config" --set-str LOCALVERSION "+"
    "$cfg" --file "$config" -d LOCALVERSION_AUTO

    make_kernel olddefconfig

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" ||
        die "CONFIG_KERNEL_LZ4 did not resolve to y"

    # These are known-good NextGen requirements from workingconfig.  The
    # fast-boot baseline must not change their built-in status.
    for sym in         ARCH_AT91         SOC_SAMA5D2         ATMEL_SSC         SND_ATMEL_SOC         SND_ATMEL_SOC_SSC         SND_ATMEL_SOC_SSC_DMA         SND_SOC_ADS131A_CODEC         SND_AUDIO_GRAPH_CARD2         TI_ADS131A
    do
        grep -q "^CONFIG_${sym}=y$" "$config" ||
            die "CONFIG_${sym} did not remain built-in"
    done

    KERNELRELEASE="$(make_kernel -s kernelrelease)"
    [ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] ||
        die "unexpected kernel release: $KERNELRELEASE"

    show_config
}

build_fast()
{
    make_kernel -j"$JOBS" \
        zImage \
        microchip/nextgen.dtb

    [ -f "$OUT/arch/arm/boot/zImage" ] ||
        die "zImage was not produced"
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] ||
        die "nextgen.dtb was not produced"
}

show_outputs()
{
    if [ -f "$OUT/arch/arm/boot/zImage" ]; then
        echo
        echo "Kernel image:"
        ls -lh "$OUT/arch/arm/boot/zImage"
    fi

    if [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ]; then
        echo "Device tree:"
        ls -lh "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb"
    fi

    module_count=$(grep -c '=m$' "$OUT/.config" || true)
    echo "  modular config entries: $module_count"

    if [ "${KERNEL_CCACHE:-1}" = "1" ]; then
        echo
        ccache -s | sed -n '1,12p'
    fi
}

case "${1:-build}" in
    clean)
        rm -rf "$OUT"
        echo "Removed $OUT"
        ;;
    config)
        configure_fast
        show_outputs
        ;;
    rebuild)
        rm -rf "$OUT"
        configure_fast
        build_fast
        show_outputs
        ;;
    build)
        configure_fast
        build_fast
        show_outputs
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|clean]" >&2
        exit 2
        ;;
esac
