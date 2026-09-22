# NextGen kernel fast-boot work

This branch starts from the imported current NextGen kernel snapshot and owns
kernel fast-boot changes directly. Buildroot only packages the resulting
`zImage` and `nextgen.dtb`.

## Stage 1: LZ4 baseline

The first stage changes only the self-decompressing ARM `zImage` compression
from gzip to LZ4. U-Boot still uses `bootz`; it does not need LZ4 support
because the ARM kernel decompressor handles the payload inside `zImage`.

Run:

```sh
./build-fast.sh
```

Seed the build from the configuration extracted from the deployed known-good
kernel image. That embedded config is the authoritative baseline:

```sh
./scripts/extract-ikconfig /path/to/known-good/zImage > /tmp/nextgen-known-good.config
KERNEL_BASE_CONFIG=/tmp/nextgen-known-good.config ./build-fast.sh
```

The saved `workingconfig` and checkout `.config` are not authoritative for
this recovery because they do not match the deployed kernel's display options.
The build scripts refuse a base config that lacks the deployed HLCDC DRM/fbdev
stack.

The script uses `arm-linux-gnueabihf-` from `PATH` by default and uses
`ccache` automatically when available. It has no Buildroot dependency.

No DTS nodes or device drivers are removed in stage 1. Display/video is also
left completely unchanged for this baseline. Probe deferral/removal and display
ownership changes come only after this baseline has been built and timed.


## Stage 2: deferred modules

`build-fast-deferred.sh` starts from the same known-good NextGen
configuration and keeps LZ4, but converts selected non-critical drivers from
built-in to modules only when they were built-in in the supplied base config.

The current deferred set is deliberately conservative:

- networking: `MACB`, `WILC_SPI`, and `WILC_SDIO`
- USB host/class support only: USB audio, ACM/USB-serial host drivers,
  mass-storage, SCSI and `BLK_DEV_SD`
- CAN: Atmel CAN and M_CAN support
- camera capture: Atmel ISI and Microchip ISC
- flash media/controller drivers: Atmel QSPI, SPI NAND and SPI NOR
- unused SoC/peripheral drivers: legacy Atmel MCI, SoC ADC, crypto engines,
  AT24 EEPROM and unused PWM blocks
- application-owned/absent clients: APDS9300, DRV260x and KXCJK1013

The boot-critical and measurement paths are explicitly checked after
`olddefconfig` and must remain built in:

- SDMMC0/rootfs plus ext4
- XDMAC
- HLCDC DRM/fbdev, panel and backlight/PWM
- Goodix touch
- SHT4x and LPS22HB pressure/temperature sensor paths
- the complete Atmel SSC/ADS131A ALSA path
- the USB gadget/Atmel UDC plus configfs ACM, NCM and FunctionFS support used
  by the application's existing `USBDeviceRun()` path

Generic kernel Bluetooth is disabled with `CONFIG_BT=n`. The legacy vendor
WILC source, including its old Bluetooth implementation, is intentionally left
unchanged because the longer-term direction is a newer Microchip WILC
driver/kernel rather than maintaining a fork of the legacy vendor code.

WILC Wi-Fi is application-on-demand in the deferred Buildroot profile. The
WILC interface modules are blacklisted from eudev alias autoloading, then the
application explicitly modprobes WILC at its existing delayed Wi-Fi stage
before starting NetworkManager. Other deferred DT modules can still be loaded
normally by eudev/kmod.

The output is separate from the LZ4 control build:

```sh
KERNEL_BASE_CONFIG=/tmp/nextgen-known-good.config ./build-fast.sh build
KERNEL_BASE_CONFIG=/tmp/nextgen-known-good.config ./build-fast-deferred.sh build
```

Artifacts are placed in `build-fast-deferred/`. The deferred build stages all
generated modules under
`build-fast-deferred/mods/lib/modules/<release>/` and reports the exact zImage
byte and percentage delta against `build-fast/arch/arm/boot/zImage` when the
control image exists.

The matching Buildroot `chatgpt/fast-boot` branch packages the complete module
tree, enables eudev module loading and kmod tools, and selects the matched
deferred zImage/DTB when `build-nextgen-image.sh deferred` is used.


## Display ownership

The NextGen ST7789 is initialised into RGB666 mode by U-Boot. Linux does not
reconfigure the panel over SPI. Linux does, however, own the SAMA5D27 HLCDC
once the kernel starts.

The deployed known-good kernel image confirms the Linux display path uses the
HLCDC DRM/KMS driver with fbdev emulation. The fast-boot kernel must keep these
built in:

- `CONFIG_DRM=y`
- `CONFIG_DRM_FBDEV_EMULATION=y`
- `CONFIG_DRM_ATMEL_HLCDC=y`
- `CONFIG_DRM_PANEL_SIMPLE=y`
- `CONFIG_MFD_ATMEL_HLCDC=y`
- `CONFIG_FB=y`
- `CONFIG_FB_SIMPLE=y`

DRM is kernel-side plumbing here. `DRM_FBDEV_EMULATION` keeps the existing
userspace ABI by creating `/dev/fb0`; the NextGen application does not need
to use DRM userspace APIs.

The HLCDC PWM/backlight path must also remain built-in. If PWM probes while
the DRM display stack is absent, Linux can change the inherited U-Boot
backlight state without ever creating `/dev/fb0`, leaving the display dark.
