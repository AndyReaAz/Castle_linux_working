#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ACTION="${1:-build}"
PROFILE="${2:-${NEXTGEN_KERNEL_PROFILE:-normal}}"

case "$PROFILE" in
    normal)
        DEFAULT_OUT="$ROOT/build-fast-6.18"
        ;;
    bringup)
        DEFAULT_OUT="$ROOT/build-fast-6.18-bringup"
        ;;
    *)
        echo "error: unknown kernel profile '$PROFILE' (expected normal or bringup)" >&2
        exit 2
        ;;
esac

OUT="${KERNEL_OUT:-$DEFAULT_OUT}"
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

seed_config()
{
    mkdir -p "$OUT"

    base="${KERNEL_BASE_CONFIG:-}"
    [ -n "$base" ] || die "set KERNEL_BASE_CONFIG to the deployed known-good 6.6 config"
    [ -f "$base" ] || die "KERNEL_BASE_CONFIG does not exist: $base"

    cp "$base" "$OUT/.config"
    echo "Seeded 6.18 config from deployed 6.6 config: $base"

    grep -q '^CONFIG_ARCH_AT91=y$' "$OUT/.config" || die "base config is not AT91"
    grep -q '^CONFIG_SOC_SAMA5D2=y$' "$OUT/.config" || die "base config is not SAMA5D2"

    # Do not require migrated/peripheral symbols to have a particular
    # tristate value in the 6.6 seed.  The 6.18 profile below reasserts
    # every boot-critical choice before olddefconfig and validates the
    # resolved result afterwards.
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
    grep -E '^CONFIG_MODULES=' "$OUT/.config" || true
    grep -E '^CONFIG_KERNEL_(LZ4|GZIP|BZIP2|LZMA|XZ|LZO|ZSTD|UNCOMPRESSED)=' "$OUT/.config" || true
    grep -E '^CONFIG_(VT|VT_CONSOLE|VT_HW_CONSOLE_BINDING|FRAMEBUFFER_CONSOLE|FRAMEBUFFER_CONSOLE_DETECT_PRIMARY|FONTS|FONT_8x16|DMADEVICES|AT_XDMAC|DRM|DRM_FBDEV_EMULATION|DRM_ATMEL_HLCDC|DRM_PANEL_SIMPLE|MFD_ATMEL_HLCDC|FB|FB_SIMPLE|BACKLIGHT_CLASS_DEVICE|BACKLIGHT_PWM|PWM|PWM_ATMEL_HLCDC_PWM|SPI_ATMEL_QUADSPI|MTD_SPI_NOR|MTD_SPI_NAND|MTD_UBI|MTD_UBI_FASTMAP|UBIFS_FS|UBIFS_FS_LZO|ATMEL_SSC|SND_SOC|SND_ATMEL_SOC_SSC_DMA|SND_ATMEL_SOC_SSC|TI_ADS131A|SND_AUDIO_GRAPH_CARD2|WILC1000|WILC1000_SPI|WILC1000_SDIO)=' "$OUT/.config" || true
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

    # BASE_SMALL was an integer in 6.6 (0 == disabled) and is a bool in
    # 6.18. Translate the deployed value explicitly to avoid a stale-config
    # warning while preserving the same setting.
    "$cfg" --file "$config" -d BASE_SMALL

    # Keep the flash controller/NAND path resident in the kernel.  The first
    # NAND-root profile also needs UBI and UBIFS built in: modules cannot be
    # loaded before the root filesystem itself is available.
    "$cfg" --file "$config" -e SPI_ATMEL_QUADSPI
    "$cfg" --file "$config" -e MTD_SPI_NAND
    "$cfg" --file "$config" -e MTD_UBI
    "$cfg" --file "$config" -e UBIFS_FS
    "$cfg" --file "$config" -e UBIFS_FS_LZO

    # The 6.6 tree used CONFIG_WILC_SPI. Linux 6.18 uses the upstream-style
    # WILC1000 bus symbols. Keep SPI as a module because userspace deliberately
    # loads Wi-Fi only after NetworkManager is ready.
    "$cfg" --file "$config" -m WILC1000_SPI
    "$cfg" --file "$config" -d WILC1000_SDIO
    "$cfg" --file "$config" -d WILC1000_HW_OOB_INTR

    # NextGen has latency-sensitive acquisition/UI work.  Use the normal
    # fully preemptible kernel model while retaining the deployed HZ=100.
    "$cfg" --file "$config" -e PREEMPT
    "$cfg" --file "$config" -d PREEMPT_NONE
    "$cfg" --file "$config" -d PREEMPT_VOLUNTARY
    "$cfg" --file "$config" -d PREEMPT_RT

    # Bring-up cards reserve the LCD for explicit operator status. The UART
    # remains the only kernel console; the provisioning script writes /dev/tty1.
    if [ "$PROFILE" = "bringup" ]; then
        "$cfg" --file "$config" -e MTD_SPI_NOR
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

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" || die "CONFIG_KERNEL_LZ4 did not resolve to y"
    grep -q '^CONFIG_PREEMPT=y$' "$config" || die "CONFIG_PREEMPT did not resolve to y"

    if [ "$PROFILE" = "bringup" ]; then
        grep -q '^# CONFIG_LOGO is not set$' "$config" ||
            die "bring-up CONFIG_LOGO must be disabled"
        for sym in MTD_SPI_NOR VT VT_CONSOLE VT_HW_CONSOLE_BINDING FRAMEBUFFER_CONSOLE FRAMEBUFFER_CONSOLE_DETECT_PRIMARY FONT_8x16
        do
            grep -q "^CONFIG_${sym}=y$" "$config" ||
                die "bring-up CONFIG_${sym} did not resolve to y"
        done
    else
        grep -q '^# CONFIG_FRAMEBUFFER_CONSOLE is not set$' "$config" ||
            die "normal profile unexpectedly enables framebuffer console"
    fi

    # These were required built-in by the known-good 6.6 fast-boot profile.
    for sym in ARCH_AT91 SOC_SAMA5D2 DRM DRM_FBDEV_EMULATION DRM_ATMEL_HLCDC DRM_PANEL_SIMPLE \
               MFD_ATMEL_HLCDC FB FB_SIMPLE BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM PWM PWM_ATMEL_HLCDC_PWM \
               DMADEVICES AT_XDMAC ATMEL_SSC SND_ATMEL_SOC_SSC SND_ATMEL_SOC_SSC_DMA \
               SND_AUDIO_GRAPH_CARD2 TI_ADS131A
    do
        grep -q "^CONFIG_${sym}=y$" "$config" || die "CONFIG_${sym} did not remain built-in"
    done

    # QSPI, SPI-NAND, UBI and UBIFS are intentionally built in.  This permits
    # Linux to mount root=ubi0:rootfs without an initramfs while retaining the
    # current SD-root boot as the recovery path.
    for sym in SPI_ATMEL_QUADSPI MTD_SPI_NAND MTD_UBI UBIFS_FS UBIFS_FS_LZO
    do
        grep -q "^CONFIG_${sym}=y$" "$config" || die "CONFIG_${sym} did not resolve to y"
    done

    grep -q '^CONFIG_MODULES=y$' "$config" || die "CONFIG_MODULES is required for delayed WILC loading"
    grep -q '^CONFIG_WILC1000_SPI=m$' "$config" || die "CONFIG_WILC1000_SPI did not resolve to m"
    grep -q '^CONFIG_WILC1000=m$' "$config" || die "CONFIG_WILC1000 core did not resolve to m"

    KERNELRELEASE="$(make_kernel -s kernelrelease)"
    [ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] || die "unexpected kernel release: $KERNELRELEASE"

    show_config
}

build_dtb()
{
    make_kernel -j"$JOBS" microchip/nextgen.dtb
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] || die "nextgen.dtb was not produced"
}

build_fast()
{
    make_kernel -j"$JOBS" zImage microchip/nextgen.dtb modules
    [ -f "$OUT/arch/arm/boot/zImage" ] || die "zImage was not produced"
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] || die "nextgen.dtb was not produced"
}

case "$ACTION" in
    clean) rm -rf "$OUT"; echo "Removed $OUT" ;;
    config) configure_fast ;;
    dtb) configure_fast; build_dtb ;;
    rebuild) rm -rf "$OUT"; configure_fast; build_fast ;;
    build) configure_fast; build_fast ;;
    *) echo "Usage: $0 [build|rebuild|config|dtb|clean] [normal|bringup]" >&2; exit 2 ;;
esac
