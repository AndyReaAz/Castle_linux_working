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
        die "ccache requested but not found; set KERNEL_CCACHE=0 only to disable it intentionally"
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
        die "host lz4/lz4c tool is required for CONFIG_KERNEL_LZ4"
    fi
}

seed_config()
{
    mkdir -p "$OUT"

    if [ ! -f "$OUT/.config" ]; then
        base="${KERNEL_BASE_CONFIG:-}"

        if [ -z "$base" ] && [ -f "$ROOT/.config" ]; then
            base="$ROOT/.config"
        fi

        [ -n "$base" ] && [ -f "$base" ] ||
            die "no base kernel config; set KERNEL_BASE_CONFIG=/path/to/known-good/.config"

        cp "$base" "$OUT/.config"
        echo "Seeded fast-boot config from $base"
    fi
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

    grep -E '^CONFIG_KERNEL_(LZ4|GZIP|BZIP2|LZMA|XZ|LZO|ZSTD|UNCOMPRESSED)='         "$OUT/.config" || true

    grep -E '^CONFIG_(SND_ATMEL_SOC|SND_ATMEL_SOC_SSC_DMA|SND_ATMEL_SOC_SSC|TI_ADS131A|SND_SOC_ADS131A_CODEC)='         "$OUT/.config" || true
}

configure_fast()
{
    seed_config
    find_lz4

    cfg="$ROOT/scripts/config"
    config="$OUT/.config"

    # Stage 1 boot baseline: change kernel compression to LZ4.
    # DTS, probe topology and video/display behaviour remain unchanged.
    "$cfg" --file "$config" -e KERNEL_LZ4
    for sym in         KERNEL_GZIP         KERNEL_BZIP2         KERNEL_LZMA         KERNEL_XZ         KERNEL_LZO         KERNEL_ZSTD         KERNEL_UNCOMPRESSED
    do
        "$cfg" --file "$config" -d "$sym"
    done

    # Keep the NextGen SSC/ADS131A capture path modular.
    #
    # The previous configuration allowed TI_ADS131A=y without the Atmel SSC
    # ASoC DAI being built-in, which caused unresolved helper symbols when
    # linking vmlinux.
    "$cfg" --file "$config" -m SND_ATMEL_SOC
    "$cfg" --file "$config" -m SND_ATMEL_SOC_SSC_DMA
    "$cfg" --file "$config" -m TI_ADS131A

    # Keep the deployed /lib/modules release directory stable even though
    # this working repository has snapshot Git history rather than linux4sam
    # history.
    "$cfg" --file "$config" --set-str LOCALVERSION "+"
    "$cfg" --file "$config" -d LOCALVERSION_AUTO

    make_kernel olddefconfig

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" ||
        die "CONFIG_KERNEL_LZ4 did not resolve to y"

    grep -q '^CONFIG_SND_ATMEL_SOC=m$' "$config" ||
        die "CONFIG_SND_ATMEL_SOC did not resolve to m"

    grep -q '^CONFIG_SND_ATMEL_SOC_SSC_DMA=m$' "$config" ||
        die "CONFIG_SND_ATMEL_SOC_SSC_DMA did not resolve to m"

    grep -q '^CONFIG_SND_ATMEL_SOC_SSC=m$' "$config" ||
        die "CONFIG_SND_ATMEL_SOC_SSC did not resolve to m"

    grep -q '^CONFIG_TI_ADS131A=m$' "$config" ||
        die "CONFIG_TI_ADS131A did not resolve to m"

    KERNELRELEASE="$(make_kernel -s kernelrelease)"
    [ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] ||
        die "unexpected kernel release: $KERNELRELEASE (expected $EXPECTED_RELEASE)"

    show_config
}

build_fast()
{
    make_kernel -j"$JOBS"         zImage         microchip/nextgen.dtb         modules

    [ -f "$OUT/arch/arm/boot/zImage" ] ||
        die "zImage was not produced"

    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] ||
        die "nextgen.dtb was not produced"

    rm -rf "$OUT/mods"

    make_kernel         INSTALL_MOD_PATH="$OUT/mods"         modules_install
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

    if [ -d "$OUT/mods/lib/modules/$EXPECTED_RELEASE" ]; then
        echo "Relevant staged modules:"
        find "$OUT/mods/lib/modules/$EXPECTED_RELEASE"             -type f             \( -name '*ads131a*.ko' -o -name '*atmel*ssc*.ko' -o -name '*atmel_ssc*.ko' \)             -print || true
    fi

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
