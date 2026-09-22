#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${KERNEL_OUT:-$ROOT/build-fast-deferred}"
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
        ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        CC="$CC" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
        LZ4="$LZ4_TOOL" LOCALVERSION= "$@"
}

seed_config()
{
    mkdir -p "$OUT"

    base="${KERNEL_BASE_CONFIG:-}"
    [ -n "$base" ] || die "set KERNEL_BASE_CONFIG to config extracted from deployed known-good zImage"
    [ -f "$base" ] || die "KERNEL_BASE_CONFIG does not exist: $base"

    cp "$base" "$OUT/.config"
    echo "Seeded deferred fast-boot config from $base"

    grep -q '^CONFIG_ARCH_AT91=y$' "$OUT/.config" || die "base config is not AT91"
    grep -q '^CONFIG_SOC_SAMA5D2=y$' "$OUT/.config" || die "base config is not SAMA5D2"
    grep -q '^CONFIG_MODULES=y$' "$OUT/.config" || die "base config has no module support"

    for sym in DRM DRM_FBDEV_EMULATION DRM_ATMEL_HLCDC DRM_PANEL_SIMPLE \
               MFD_ATMEL_HLCDC FB FB_SIMPLE \
               BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM PWM PWM_ATMEL_HLCDC_PWM
    do
        grep -q "^CONFIG_${sym}=y$" "$OUT/.config" ||
            die "base config is not deployed known-good display config: CONFIG_${sym} is not y"
    done
}

move_if_builtin()
{
    sym="$1"
    if grep -q "^CONFIG_${sym}=y$" "$OUT/.config"; then
        "$ROOT/scripts/config" --file "$OUT/.config" --keep-case -m "$sym"
        printf '%s\n' "$sym" >> "$EXPECTED_MODULES_FILE"
        printf '  defer %-28s y -> m\n' "$sym"
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

    move_if_builtin MACB
    move_if_builtin WILC_SPI
    move_if_builtin WILC_SDIO
    move_if_builtin SPI_ATMEL_QUADSPI
    move_if_builtin MTD_SPI_NAND
    move_if_builtin MTD_SPI_NOR
    move_if_builtin APDS9300
    move_if_builtin INPUT_DRV260X_HAPTICS
    move_if_builtin KXCJK1013

    make_kernel olddefconfig

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" || die "CONFIG_KERNEL_LZ4 did not remain enabled"

    for sym in ARCH_AT91 SOC_SAMA5D2 MMC MMC_BLOCK MMC_SDHCI MMC_SDHCI_PLTFM MMC_SDHCI_OF_AT91 EXT4_FS \
               DRM DRM_FBDEV_EMULATION DRM_ATMEL_HLCDC DRM_PANEL_SIMPLE MFD_ATMEL_HLCDC FB FB_SIMPLE \
               BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM PWM PWM_ATMEL_HLCDC_PWM DMADEVICES AT_XDMAC \
               ATMEL_SSC SND_ATMEL_SOC SND_ATMEL_SOC_SSC SND_ATMEL_SOC_SSC_DMA \
               SND_SOC_ADS131A_CODEC SND_AUDIO_GRAPH_CARD2 TI_ADS131A
    do
        grep -q "^CONFIG_${sym}=y$" "$config" || die "critical CONFIG_${sym} is no longer built-in"
    done

    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        grep -q "^CONFIG_${sym}=m$" "$config" || die "requested deferred CONFIG_${sym} did not resolve to m"
    done < "$EXPECTED_MODULES_FILE"

    KERNELRELEASE="$(make_kernel -s kernelrelease)"
    [ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] || die "unexpected kernel release: $KERNELRELEASE"
}

build_deferred()
{
    make_kernel -j"$JOBS" zImage microchip/nextgen.dtb modules
    [ -f "$OUT/arch/arm/boot/zImage" ] || die "zImage was not produced"
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] || die "nextgen.dtb was not produced"

    rm -rf "$OUT/mods"
    make_kernel INSTALL_MOD_PATH="$OUT/mods" modules_install
}

case "${1:-build}" in
    clean) rm -rf "$OUT"; echo "Removed $OUT" ;;
    config) configure_deferred ;;
    rebuild) rm -rf "$OUT"; configure_deferred; build_deferred ;;
    build) configure_deferred; build_deferred ;;
    *) echo "Usage: $0 [build|rebuild|config|clean]" >&2; exit 2 ;;
esac
