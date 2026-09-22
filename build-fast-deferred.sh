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

    # Bluetooth is intentionally absent from the current NextGen product.
    # Bluetooth userspace is not currently used. Keep the legacy WILC vendor
    # driver itself unchanged for eventual replacement by the newer Microchip
    # driver; disabling the generic kernel Bluetooth stack still removes BlueZ/HCI
    # kernel support from this image.
    "$cfg" --file "$config" -d BT

    # debugfs is not part of the product ABI. Keeping it enabled pulls
    # development-only debug hooks into several otherwise boot-critical
    # subsystems (MMC, block, DRM, etc.) and the rootfs previously mounted it
    # unconditionally. The LZ4 control kernel remains available when these
    # diagnostics are needed.
    "$cfg" --file "$config" -d DEBUG_FS

    # Network devices not required to mount rootfs, initialise display or
    # start the measurement path.
    move_if_builtin MACB
    move_if_builtin WILC_SPI
    move_if_builtin WILC_SDIO

    # USB gadget setup is no longer part of the boot-critical path. Defer the
    # gadget core itself as well as the concrete Atmel UDC, configfs composite
    # layer and configfs filesystem until usbcontrol.sh selects a non-zero
    # runtime mask. The Buildroot deferred profile blacklists the UDC modalias
    # so eudev does not defeat this deferral.
    move_if_builtin USB_GADGET
    move_if_builtin USB_ATMEL_USBA
    move_if_builtin USB_CONFIGFS
    move_if_builtin CONFIGFS_FS

    # USB host/class drivers are also not required for application startup.
    move_if_builtin SND_USB_AUDIO
    move_if_builtin USB_ACM
    move_if_builtin USB_SERIAL_FTDI_SIO
    move_if_builtin USB_SERIAL_PL2303
    move_if_builtin USB_SERIAL
    move_if_builtin USB_STORAGE
    move_if_builtin BLK_DEV_SD
    move_if_builtin SCSI

    # No CAN controller is enabled by the NextGen device tree.
    move_if_builtin CAN_AT91
    move_if_builtin CAN_M_CAN_PLATFORM
    move_if_builtin CAN_M_CAN
    move_if_builtin CAN

    # Camera capture hardware is not present/enabled on NextGen.
    move_if_builtin VIDEO_ATMEL_ISI
    move_if_builtin VIDEO_MICROCHIP_ISC

    # Keep MTD/UBI core available for the future NAND-root production path,
    # but move the concrete SPI flash controller/media drivers out of zImage
    # on the current SD-root fast profile.
    move_if_builtin SPI_ATMEL_QUADSPI
    move_if_builtin MTD_SPI_NAND
    move_if_builtin MTD_SPI_NOR

    # The known-good kernel enabled legacy PCMCIA-era MTD block translators.
    # CONFIG_FTL in particular scans each MTD partition for an FTL header,
    # wasting hundreds of milliseconds on the SPI NAND. NextGen uses raw MTD
    # access for update/testing and UBI/UBIFS for the future NAND root.
    for sym in MTD_BLOCK MTD_BLOCK_RO FTL NFTL INFTL RFD_FTL SSFDC SM_FTL MTD_SWAP
    do
        "$cfg" --file "$config" -d "$sym"
    done

    # Root SD uses SAMA5D2 SDHCI, not the legacy Atmel MCI driver.
    move_if_builtin MMC_ATMELMCI

    # /boot is no longer mounted by mount -a. It is mounted on demand only
    # when the application accesses the U-Boot environment, so the VFAT stack
    # and its actual mount character sets are not boot-critical.
    move_if_builtin VFAT_FS
    move_if_builtin FAT_FS
    move_if_builtin NLS_CODEPAGE_437
    move_if_builtin NLS_ISO8859_1

    # Unused SoC peripherals. ADS131A/SSC measurement remains built in.
    move_if_builtin AT91_ADC
    move_if_builtin AT91_SAMA5D2_ADC
    move_if_builtin CRYPTO_DEV_ATMEL_AES
    move_if_builtin CRYPTO_DEV_ATMEL_TDES
    move_if_builtin CRYPTO_DEV_ATMEL_SHA
    move_if_builtin EEPROM_AT24
    move_if_builtin PWM_ATMEL
    move_if_builtin PWM_ATMEL_TCB

    # Application-owned or absent I2C clients.
    move_if_builtin APDS9300
    move_if_builtin INPUT_DRV260X_HAPTICS
    move_if_builtin KXCJK1013

    make_kernel olddefconfig

    grep -q '^CONFIG_KERNEL_LZ4=y$' "$config" ||
        die "CONFIG_KERNEL_LZ4 did not remain enabled"
    grep -q '^# CONFIG_BT is not set$' "$config" ||
        die "Bluetooth unexpectedly enabled"
    grep -q '^# CONFIG_DEBUG_FS is not set$' "$config" ||
        die "debugfs unexpectedly enabled"

    for sym in MTD_BLOCK MTD_BLOCK_RO FTL NFTL INFTL RFD_FTL SSFDC SM_FTL MTD_SWAP
    do
        grep -q "^# CONFIG_${sym} is not set$" "$config" ||
            die "legacy MTD translator CONFIG_${sym} unexpectedly enabled"
    done

    for sym in ARCH_AT91 SOC_SAMA5D2 MMC MMC_BLOCK MMC_SDHCI MMC_SDHCI_PLTFM MMC_SDHCI_OF_AT91 EXT4_FS \
               DRM DRM_FBDEV_EMULATION DRM_ATMEL_HLCDC DRM_PANEL_SIMPLE MFD_ATMEL_HLCDC FB FB_SIMPLE \
               BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM PWM PWM_ATMEL_HLCDC_PWM DMADEVICES AT_XDMAC \
               TOUCHSCREEN_GOODIX SENSORS_SHT4x IIO_ST_PRESS IIO_ST_PRESS_I2C \
               USB_CONFIGFS_ACM USB_CONFIGFS_NCM USB_CONFIGFS_F_FS \
               ATMEL_SSC SND_ATMEL_SOC SND_ATMEL_SOC_SSC SND_ATMEL_SOC_SSC_DMA \
               SND_SOC_ADS131A_CODEC SND_AUDIO_GRAPH_CARD2 TI_ADS131A
    do
        grep -q "^CONFIG_${sym}=y$" "$config" ||
            die "critical CONFIG_${sym} is no longer built-in"
    done

    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        grep -q "^CONFIG_${sym}=m$" "$config" ||
            die "requested deferred CONFIG_${sym} did not resolve to m"
    done < "$EXPECTED_MODULES_FILE"

    # USB_CONFIGFS remains the user-facing tristate while its selected
    # function implementations are hidden symbols.  Verify that the latter
    # follow the deferred module boundary rather than being pulled back into
    # zImage by Kconfig.
    for sym in USB_GADGET USB_ATMEL_USBA USB_CONFIGFS CONFIGFS_FS \
               USB_LIBCOMPOSITE USB_U_SERIAL USB_F_ACM USB_U_ETHER USB_F_NCM USB_F_FS
    do
        grep -q "^CONFIG_${sym}=m$" "$config" ||
            die "deferred gadget CONFIG_${sym} did not resolve to m"
    done

    KERNELRELEASE="$(make_kernel -s kernelrelease)"
    [ "$KERNELRELEASE" = "$EXPECTED_RELEASE" ] ||
        die "unexpected kernel release: $KERNELRELEASE"
}

build_deferred()
{
    make_kernel -j"$JOBS" zImage microchip/nextgen.dtb modules

    [ -f "$OUT/arch/arm/boot/zImage" ] ||
        die "zImage was not produced"
    [ -f "$OUT/arch/arm/boot/dts/microchip/nextgen.dtb" ] ||
        die "nextgen.dtb was not produced"

    rm -rf "$OUT/mods"
    make_kernel INSTALL_MOD_PATH="$OUT/mods" modules_install

    echo
    echo "NextGen deferred kernel output:"
    ls -lh "$OUT/arch/arm/boot/zImage"
    find "$OUT/mods/lib/modules" -type f -name '*.ko*' -printf '%s %p\n' 2>/dev/null |
        sort -nr | head -30 || true

    compare_zimages
}

compare_zimages()
{
    control="$ROOT/build-fast/arch/arm/boot/zImage"
    deferred="$OUT/arch/arm/boot/zImage"

    echo
    echo "zImage size comparison:"
    if [ ! -f "$control" ]; then
        echo "  control:  not available ($control)"
        echo "  deferred: $(wc -c < "$deferred" | tr -d '[:space:]') bytes"
        echo "  Build the LZ4 control with build-fast.sh to calculate the delta."
        return 0
    fi

    control_bytes="$(wc -c < "$control" | tr -d '[:space:]')"
    deferred_bytes="$(wc -c < "$deferred" | tr -d '[:space:]')"
    delta_bytes=$((control_bytes - deferred_bytes))

    printf '  control:   %d bytes\n' "$control_bytes"
    printf '  deferred:  %d bytes\n' "$deferred_bytes"

    if [ "$delta_bytes" -ge 0 ]; then
        permille=$((delta_bytes * 1000 / control_bytes))
        printf '  reduction: %d bytes (%d.%d%%)\n' \
            "$delta_bytes" "$((permille / 10))" "$((permille % 10))"
    else
        growth_bytes=$((-delta_bytes))
        permille=$((growth_bytes * 1000 / control_bytes))
        printf '  growth:    %d bytes (%d.%d%%)\n' \
            "$growth_bytes" "$((permille / 10))" "$((permille % 10))"
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
        ;;
    build)
        configure_deferred
        build_deferred
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|clean]" >&2
        exit 2
        ;;
esac
