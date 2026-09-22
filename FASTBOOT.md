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
