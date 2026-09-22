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

If this checkout does not yet have a `.config`, seed it once from the current
known-good meter kernel configuration:

```sh
KERNEL_BASE_CONFIG=/path/to/linux-at91/.config ./build-fast.sh
```

The script uses `arm-linux-gnueabihf-` from `PATH` by default and uses
`ccache` automatically when available. It has no Buildroot dependency.

No DTS nodes or device drivers are removed in stage 1. Display/video is also
left completely unchanged for this baseline. Probe deferral/removal and display
ownership changes come only after this baseline has been built and timed.


## Stage 2: deferred modules

`build-fast-deferred.sh` starts from the same known-good NextGen configuration
and keeps LZ4, but converts selected drivers from built-in to modules only when
they were built-in in the supplied base config.

The first deferred set is intentionally conservative:

- `MACB` and `WILC_SPI`
- `SPI_ATMEL_QUADSPI`, `MTD_SPI_NAND`, and `MTD_SPI_NOR`
- `APDS9300` and `SENSORS_SHT4x`
- `IIO_ST_PRESS` and `IIO_ST_PRESS_I2C`
- `INPUT_DRV260X_HAPTICS`
- `KXCJK1013`

It deliberately keeps the SD/MMC rootfs path, ext4, console, display/video,
Goodix touch, USB, and the complete Atmel SSC/ADS131A audio path built-in.

The output is separate from the control build:

```sh
KERNEL_BASE_CONFIG=/path/to/workingconfig ./build-fast-deferred.sh config
KERNEL_BASE_CONFIG=/path/to/workingconfig ./build-fast-deferred.sh build
```

Artifacts are placed in `build-fast-deferred/`. The script prints the zImage
size reduction relative to `build-fast/` and stages all generated modules
under `build-fast-deferred/mods/lib/modules/<release>/`.

The matching Buildroot fast branch packages the complete module tree when one
exists. eudev module loading and kmod tools are enabled so DT modaliases can
load deferred drivers after userspace starts.
