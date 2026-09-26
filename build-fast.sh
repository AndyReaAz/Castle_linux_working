#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ACTION="${1:-build}"
PROFILE="${2:-${NEXTGEN_KERNEL_PROFILE:-normal}}"

case "$PROFILE" in
    normal)
        DEFAULT_OUT="$ROOT/build-fast-6.18"
        MODULES_STAGING_DEFAULT="$ROOT/../staging/linux-6.18-modules"
        ;;
    bringup)
        DEFAULT_OUT="$ROOT/build-fast-6.18-bringup"
        MODULES_STAGING_DEFAULT="$ROOT/../staging/linux-6.18-bringup-modules"
        ;;
    *)
        echo "error: unknown kernel profile '$PROFILE' (expected normal or bringup)" >&2
        exit 2
        ;;
esac

OUT="${KERNEL_OUT:-$DEFAULT_OUT}"
MODULES_STAGING="${KERNEL_MODULES_STAGING:-$MODULES_STAGING_DEFAULT}"
ARCH=arm
TOOLCHAIN_PREFIX="${KERNEL_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"
CROSS_COMPILE="$TOOLCHAIN_PREFIX"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
EXPECTED_RELEASE="6.18.35-linux4microchip-2026.04.2+"

export ARCH CROSS_COMPILE

die()
{
    echo "error: $*" >&2
    exit 1
}

[ -x "$ROOT/scripts/config" ] || die "scripts/config not found in $ROOT"
command -v "${TOOLCHAIN_PREFIX}gcc" >/dev/null 2>&1 ||
    die "ARM compiler not found: ${TOOLCHAIN_PREFIX}gcc"

if [ "${KERNEL_CCACHE:-1}" = 1 ]; then
    command -v ccache >/dev/null 2>&1 || die "ccache requested but not found"
    CC="ccache ${TOOLCHAIN_PREFIX}gcc"
    HOSTCC="ccache gcc"
    HOSTCXX="ccache g++"
else
    CC="${TOOLCHAIN_PREFIX}gcc"
    HOSTCC=gcc
    HOSTCXX=g++
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

    # Preserve the proven board configuration. A generic SAMA5 seed may
    # configure successfully while omitting NextGen USB/input/runtime drivers.
    # The frozen board defconfig will become the default once imported; until
    # then use an explicit saved known-good config outside the build directory.
    base="${KERNEL_BASE_CONFIG:-$ROOT/arch/arm/configs/nextgen_defconfig}"
    [ -f "$base" ] || die "NextGen board config missing: $base; set KERNEL_BASE_CONFIG to a saved known-good NextGen config"
    cp "$base" "$OUT/.config"
    echo "Seeded 6.18 config from: $base"
    grep -q '^CONFIG_ARCH_AT91=y$' "$OUT/.config" || die "base config is not AT91"
    grep -q '^CONFIG_SOC_SAMA5D2=y$' "$OUT/.config" || die "base config is not SAMA5D2"
}

make_kernel()
{
    make -C "$ROOT" O="$OUT" \
        ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
        CC="$CC" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
        LZ4="$LZ4_TOOL" LOCALVERSION= "$@"
}

show_config()
{
    echo
    echo "NextGen Linux 6.18 profile:"
    echo "  PROFILE       = $PROFILE"
    echo "  ARCH          = $ARCH"
    echo "  CROSS_COMPILE = $CROSS_COMPILE"
    echo "  RELEASE       = ${KERNELRELEASE:-not-built}"
    echo "  MODULE STAGE  = $MODULES_STAGING"
    grep -E '^CONFIG_MODULES=' "$OUT/.config" || true
    grep -E '^CONFIG_KERNEL_(LZ4|GZIP|BZIP2|LZMA|XZ|LZO|ZSTD|UNCOMPRESSED)=' "$OUT/.config" || true
    grep -E '^CONFIG_(VT|VT_CONSOLE|VT_HW_CONSOLE_BINDING|FRAMEBUFFER_CONSOLE|FRAMEBUFFER_CONSOLE_DETECT_PRIMARY|FONTS|FONT_8x16|DMADEVICES|AT_XDMAC|DRM|DRM_FBDEV_EMULATION|DRM_ATMEL_HLCDC|DRM_PANEL_SIMPLE|MFD_ATMEL_HLCDC|FB|FB_SIMPLE|BACKLIGHT_CLASS_DEVICE|BACKLIGHT_PWM|PWM|PWM_ATMEL_HLCDC_PWM|SPI|SPI_ATMEL|SPI_ATMEL_QUADSPI|MTD|MTD_SPI_NOR|MTD_SPI_NOR_USE_4K_SECTORS|MTD_SPI_NAND|MTD_UBI|MTD_UBI_FASTMAP|MTD_UBI_BLOCK|UBIFS_FS|UBIFS_FS_LZO|EXT4_FS|BLK_DEV_LOOP|SQUASHFS|SQUASHFS_LZO|ATMEL_SSC|SND_SOC|SND_ATMEL_SOC_SSC_DMA|SND_ATMEL_SOC_SSC|TI_ADS131A|SND_AUDIO_GRAPH_CARD2|WILC1000|WILC1000_SPI|WILC1000_SDIO)=' "$OUT/.config" || true
    grep -E '^CONFIG_BLK_DEV_LOOP_MIN_COUNT=' "$OUT/.config" || true
}

configure_fast()
{
    seed_config
    find_lz4

    cfg="$ROOT/scripts/config"
    config="$OUT/.config"

    "$cfg" --file "$config" -e KERNEL_LZ4
    for sym in KERNEL_GZIP KERNEL_BZIP2 KERNEL_LZMA KERNEL_XZ KERNEL_LZO KERNEL_ZSTD KERNEL_UNCOMPRESSED
    do
        "$cfg" --file "$config" -d "$sym"
    done

    "$cfg" --file "$config" --set-str LOCALVERSION "+"
    "$cfg" --file "$config" -d LOCALVERSION_AUTO
    "$cfg" --file "$config" -d BASE_SMALL

    # Explicit hardware features required by NextGen.
    for sym in \
        DRM DRM_FBDEV_EMULATION DRM_ATMEL_HLCDC DRM_PANEL_SIMPLE \
        MFD_ATMEL_HLCDC FB FB_SIMPLE BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM \
        PWM PWM_ATMEL_HLCDC_PWM DMADEVICES AT_XDMAC ATMEL_SSC \
        SND_ATMEL_SOC_SSC SND_ATMEL_SOC_SSC_DMA SND_AUDIO_GRAPH_CARD2 \
        TI_ADS131A
    do
        "$cfg" --file "$config" -e "$sym"
    done

    # Boot/runtime storage primitives shared by the SD and production-NAND
    # backends. Keep everything required before /persist is mounted built in.
    "$cfg" --file "$config" -e SPI
    "$cfg" --file "$config" -e SPI_ATMEL
    "$cfg" --file "$config" -e MTD
    "$cfg" --file "$config" -e SPI_ATMEL_QUADSPI
    "$cfg" --file "$config" -e MTD_SPI_NAND
    "$cfg" --file "$config" -e MTD_UBI
    "$cfg" --file "$config" -e MTD_UBI_BLOCK
    "$cfg" --file "$config" -e UBIFS_FS
    "$cfg" --file "$config" -e UBIFS_FS_LZO
    "$cfg" --file "$config" -e MTD_SPI_NOR_USE_4K_SECTORS

    # Production boot no longer needs NOR after U-Boot hand-off, so the normal
    # runtime keeps SPI-NOR deferred. The service bring-up image needs direct
    # built-in NOR access for destructive provisioning.
    if [ "$PROFILE" = bringup ]; then
        "$cfg" --file "$config" -e MTD_SPI_NOR
    else
        "$cfg" --file "$config" -m MTD_SPI_NOR
    fi

    "$cfg" --file "$config" -e EXT4_FS
    "$cfg" --file "$config" -e BLK_DEV_LOOP
    "$cfg" --file "$config" --set-val BLK_DEV_LOOP_MIN_COUNT 4
    "$cfg" --file "$config" -e SQUASHFS
    "$cfg" --file "$config" -e SQUASHFS_LZO

    # WILC remains an application-owned delayed module.
    "$cfg" --file "$config" -m WILC1000_SPI
    "$cfg" --file "$config" -d WILC1000_SDIO
    "$cfg" --file "$config" -d WILC1000_HW_OOB_INTR

    "$cfg" --file "$config" -e PREEMPT
    "$cfg" --file "$config" -d PREEMPT_NONE
    "$cfg" --file "$config" -d PREEMPT_VOLUNTARY
    "$cfg" --file "$config" -d PREEMPT_RT

    # Bring-up cards reserve fbcon/tty1 for the operator progress screen.
    if [ "$PROFILE" = bringup ]; then
        "$cfg" --file "$config" -d LOGO
        "$cfg" --file "$config" -e VT
        "$cfg" --file "$config" -e VT_CONSOLE
        "$cfg" --file "$config" -e VT_HW_CONSOLE_BINDING
        "$cfg" --file "$config" -e FRAMEBUFFER_CONSOLE
        "$cfg" --file "$config" -e FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
        "$cfg" --file "$config" -e FONTS
        "$cfg" --file "$config" -e FONT_8x16
    else
        "$cfg" --file "$config" -d FRAMEBUFFER_CONSOLE
        "$cfg" --file "$config" -d FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
    fi

    make_kernel olddefconfig

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" ||
        die "CONFIG_KERNEL_LZ4 did not resolve to y"
    grep -q '^CONFIG_PREEMPT=y$' "$config" ||
        die "CONFIG_PREEMPT did not resolve to y"

    for sym in ARCH_AT91 SOC_SAMA5D2 DRM DRM_FBDEV_EMULATION DRM_ATMEL_HLCDC DRM_PANEL_SIMPLE \
               MFD_ATMEL_HLCDC FB FB_SIMPLE BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM PWM PWM_ATMEL_HLCDC_PWM \
               DMADEVICES AT_XDMAC ATMEL_SSC SND_ATMEL_SOC_SSC SND_ATMEL_SOC_SSC_DMA \
               SND_AUDIO_GRAPH_CARD2 TI_ADS131A \
               SPI SPI_ATMEL MTD SPI_ATMEL_QUADSPI MTD_SPI_NAND MTD_UBI MTD_UBI_BLOCK \
               UBIFS_FS UBIFS_FS_LZO EXT4_FS BLK_DEV_LOOP SQUASHFS SQUASHFS_LZO
    do
        grep -q "^CONFIG_${sym}=y$" "$config" ||
            die "CONFIG_${sym} did not resolve to y"
    done

    grep -q '^CONFIG_BLK_DEV_LOOP_MIN_COUNT=4$' "$config" ||
        die "CONFIG_BLK_DEV_LOOP_MIN_COUNT did not resolve to 4"
    grep -q '^CONFIG_MODULES=y$' "$config" ||
        die "CONFIG_MODULES is required for delayed device loading"
    grep -q '^CONFIG_MTD_SPI_NOR_USE_4K_SECTORS=y$' "$config" ||
        die "CONFIG_MTD_SPI_NOR_USE_4K_SECTORS did not resolve to y"
    grep -q '^CONFIG_WILC1000_SPI=m$' "$config" ||
        die "CONFIG_WILC1000_SPI did not resolve to m"
    grep -q '^CONFIG_WILC1000=m$' "$config" ||
        die "CONFIG_WILC1000 core did not resolve to m"

    if [ "$PROFILE" = bringup ]; then
        grep -q '^CONFIG_MTD_SPI_NOR=y$' "$config" ||
            die "bring-up CONFIG_MTD_SPI_NOR did not resolve to y"
        grep -q '^# CONFIG_LOGO is not set$' "$config" ||
            die "bring-up CONFIG_LOGO must be disabled"
        for sym in VT VT_CONSOLE VT_HW_CONSOLE_BINDING FRAMEBUFFER_CONSOLE FRAMEBUFFER_CONSOLE_DETECT_PRIMARY FONT_8x16
        do
            grep -q "^CONFIG_${sym}=y$" "$config" ||
                die "bring-up CONFIG_${sym} did not resolve to y"
        done
    else
        grep -q '^CONFIG_MTD_SPI_NOR=m$' "$config" ||
            die "normal CONFIG_MTD_SPI_NOR did not resolve to m"
        grep -q '^# CONFIG_FRAMEBUFFER_CONSOLE is not set$' "$config" ||
            die "normal profile unexpectedly enables framebuffer console"
    fi

    KERNELRELEASE="$(make_kernel -s kernelrelease)"
    [ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] ||
        die "unexpected kernel release: $KERNELRELEASE"

    show_config
}

build_dtb()
{
    make_kernel -j"$JOBS" microchip/nextgen.dtb
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] ||
        die "nextgen.dtb was not produced"
}

stage_modules()
{
    rm -rf "$MODULES_STAGING"
    mkdir -p "$MODULES_STAGING"

    make_kernel INSTALL_MOD_PATH="$MODULES_STAGING" modules_install

    staged="$MODULES_STAGING/lib/modules/$EXPECTED_RELEASE"
    [ -d "$staged" ] || die "modules_install did not produce $staged"
    rm -f "$staged/build" "$staged/source"

    echo "Staged NextGen kernel modules: $staged"
}

build_fast()
{
    make_kernel -j"$JOBS" zImage microchip/nextgen.dtb modules
    [ -f "$OUT/arch/arm/boot/zImage" ] || die "zImage was not produced"
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] ||
        die "nextgen.dtb was not produced"
    stage_modules
}

case "$ACTION" in
    clean)
        rm -rf "$OUT"
        echo "Removed $OUT"
        ;;
    config)
        configure_fast
        ;;
    dtb)
        configure_fast
        build_dtb
        ;;
    rebuild)
        base="${KERNEL_BASE_CONFIG:-$ROOT/arch/arm/configs/nextgen_defconfig}"
        [ -f "$base" ] || die "NextGen board config missing: $base; set KERNEL_BASE_CONFIG to a saved known-good NextGen config"
        case "$(readlink -f "$base")" in
            "$(readlink -m "$OUT")"/*)
                die "save KERNEL_BASE_CONFIG outside KERNEL_OUT before a rebuild"
                ;;
        esac
        rm -rf "$OUT"
        configure_fast
        build_fast
        ;;
    build)
        configure_fast
        build_fast
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|dtb|clean] [normal|bringup]" >&2
        exit 2
        ;;
esac
