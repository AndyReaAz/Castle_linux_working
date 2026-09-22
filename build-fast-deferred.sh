#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${KERNEL_OUT:-$ROOT/build-fast-deferred}"
BASE_OUT="${NEXTGEN_BASELINE_OUT:-$ROOT/build-fast}"
ARCH=arm
TOOLCHAIN_PREFIX="${KERNEL_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"
CROSS_COMPILE="$TOOLCHAIN_PREFIX"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
EXPECTED_RELEASE="6.6.23-linux4microchip-2024.04+"
EXPECTED_MODULES_FILE="$OUT/.nextgen-deferred-modules"

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
    command -v ccache >/dev/null 2>&1 || die "ccache requested but not found"
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

make_kernel()
{
    make -C "$ROOT" O="$OUT" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        CC="$CC" \
        HOSTCC="$HOSTCC" \
        HOSTCXX="$HOSTCXX" \
        LZ4="$LZ4_TOOL" \
        LOCALVERSION= \
        "$@"
}

seed_config()
{
    mkdir -p "$OUT"

    base="${KERNEL_BASE_CONFIG:-}"
    if [ -n "$base" ]; then
        [ -f "$base" ] || die "KERNEL_BASE_CONFIG does not exist: $base"
        cp "$base" "$OUT/.config"
        echo "Seeded deferred fast-boot config from $base"
    elif [ ! -f "$OUT/.config" ]; then
        die "set KERNEL_BASE_CONFIG to the known-good NextGen workingconfig"
    fi

    grep -q '^CONFIG_ARCH_AT91=y$' "$OUT/.config" || die "base config is not AT91"
    grep -q '^CONFIG_SOC_SAMA5D2=y$' "$OUT/.config" || die "base config is not SAMA5D2"
    grep -q '^CONFIG_MODULES=y$' "$OUT/.config" || die "base config has no module support"
}

move_if_builtin()
{
    sym="$1"
    if grep -q "^CONFIG_${sym}=y$" "$OUT/.config"; then
        "$ROOT/scripts/config" --file "$OUT/.config" --keep-case -m "$sym"
        printf '%s\n' "$sym" >> "$EXPECTED_MODULES_FILE"
        printf '  defer %-28s y -> m\n' "$sym"
    else
        printf '  leave %-28s unchanged\n' "$sym"
    fi
}

configure_deferred()
{
    seed_config
    find_lz4

    cfg="$ROOT/scripts/config"
    config="$OUT/.config"
    : > "$EXPECTED_MODULES_FILE"

    "$cfg" --file "$config" -e KERNEL_LZ4
    for sym in KERNEL_GZIP KERNEL_BZIP2 KERNEL_LZMA KERNEL_XZ KERNEL_LZO KERNEL_ZSTD KERNEL_UNCOMPRESSED
    do
        "$cfg" --file "$config" -d "$sym"
    done

    "$cfg" --file "$config" --set-str LOCALVERSION "+"
    "$cfg" --file "$config" -d LOCALVERSION_AUTO

    echo "Deferring non-boot-critical built-in drivers:"

    move_if_builtin MACB
    move_if_builtin WILC_SPI

    move_if_builtin SPI_ATMEL_QUADSPI
    move_if_builtin MTD_SPI_NAND
    move_if_builtin MTD_SPI_NOR

    move_if_builtin APDS9300
    move_if_builtin SENSORS_SHT4x
    move_if_builtin IIO_ST_PRESS
    move_if_builtin IIO_ST_PRESS_I2C
    move_if_builtin INPUT_DRV260X_HAPTICS
    move_if_builtin KXCJK1013

    make_kernel olddefconfig

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" || die "CONFIG_KERNEL_LZ4 did not remain enabled"

    for sym in \
        ARCH_AT91 \
        SOC_SAMA5D2 \
        MMC \
        MMC_BLOCK \
        MMC_SDHCI \
        MMC_SDHCI_PLTFM \
        MMC_SDHCI_OF_AT91 \
        EXT4_FS \
        ATMEL_SSC \
        SND_ATMEL_SOC \
        SND_ATMEL_SOC_SSC \
        SND_ATMEL_SOC_SSC_DMA \
        SND_SOC_ADS131A_CODEC \
        SND_AUDIO_GRAPH_CARD2 \
        TI_ADS131A
    do
        grep -q "^CONFIG_${sym}=y$" "$config" || die "critical CONFIG_${sym} is no longer built-in"
    done

    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        grep -q "^CONFIG_${sym}=m$" "$config" ||
            die "requested deferred CONFIG_${sym} did not resolve to m"
    done < "$EXPECTED_MODULES_FILE"

    KERNELRELEASE="$(make_kernel -s kernelrelease)"
    [ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] ||
        die "unexpected kernel release: $KERNELRELEASE"

    echo
    echo "Resolved deferred modules:"
    if [ -s "$EXPECTED_MODULES_FILE" ]; then
        while IFS= read -r sym; do
            grep "^CONFIG_${sym}=m$" "$config"
        done < "$EXPECTED_MODULES_FILE"
    else
        echo "  none of the candidate drivers were built-in in the base config"
    fi
}

build_deferred()
{
    make_kernel -j"$JOBS" zImage microchip/nextgen.dtb modules

    [ -f "$OUT/arch/arm/boot/zImage" ] || die "zImage was not produced"
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] || die "nextgen.dtb was not produced"

    rm -rf "$OUT/mods"
    make_kernel INSTALL_MOD_PATH="$OUT/mods" modules_install

    release_dir="$OUT/mods/lib/modules/$EXPECTED_RELEASE"
    [ -d "$release_dir" ] || die "module install did not create $release_dir"

    module_count=$(find "$release_dir" -type f -name '*.ko' | wc -l)
    [ "$module_count" -gt 0 ] || die "deferred profile produced no kernel modules"
}

show_outputs()
{
    image="$OUT/arch/arm/boot/zImage"
    dtb="$OUT/arch/arm/boot/dts/microchip/nextgen.dtb"

    if [ -f "$image" ]; then
        echo
        echo "Deferred kernel image:"
        ls -lh "$image"

        if [ -f "$BASE_OUT/arch/arm/boot/zImage" ]; then
            base_bytes=$(stat -c '%s' "$BASE_OUT/arch/arm/boot/zImage")
            deferred_bytes=$(stat -c '%s' "$image")
            saved_bytes=$((base_bytes - deferred_bytes))
            awk -v base="$base_bytes" -v now="$deferred_bytes" -v saved="$saved_bytes" 'BEGIN {
                printf "  baseline: %.2f MiB\n", base / 1048576
                printf "  deferred: %.2f MiB\n", now / 1048576
                printf "  saved:    %.2f MiB (%.1f%%)\n", saved / 1048576, (saved * 100.0) / base
            }'
        fi
    fi

    if [ -f "$dtb" ]; then
        echo "Device tree:"
        ls -lh "$dtb"
    fi

    release_dir="$OUT/mods/lib/modules/$EXPECTED_RELEASE"
    if [ -d "$release_dir" ]; then
        echo "Module tree:"
        du -sh "$release_dir"
        count=$(find "$release_dir" -type f -name '*.ko' | wc -l)
        echo "  .ko files: $count"
        echo "Deferred-driver modules:"
        find "$release_dir" -type f -name '*.ko' | grep -E 'wilc|macb|atmel-quadspi|spinand|spi-nor|apds9300|sht4x|st_pressure|drv260x|kxcjk' || true
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
        configure_deferred
        ;;
    rebuild)
        rm -rf "$OUT"
        configure_deferred
        build_deferred
        show_outputs
        ;;
    build)
        configure_deferred
        build_deferred
        show_outputs
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|clean]" >&2
        exit 2
        ;;
esac
