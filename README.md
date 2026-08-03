# Debian mini.iso Builder (multiple firmware)

Membangun custom Debian netboot mini.iso dengan multiple firmware
(bnx2x + qlogic) di-inject ke dalam initrd. Berjalan di dalam Podman/Docker container
— tidak perlu Debian server.

## Prasyarat

- Podman (atau Docker)

## Build image

```bash
cd debian-iso-builder
podman build -t debian-iso-builder .
```

## Penggunaan

### Build semua versi (buster, bullseye, bookworm)

```bash
mkdir -p output
podman run --rm -v "$(pwd)/output:/output:Z" debian-iso-builder
```

### Build versi tertentu

```bash
podman run --rm -v "$(pwd)/output:/output:Z" debian-iso-builder bookworm
podman run --rm -v "$(pwd)/output:/output:Z" debian-iso-builder buster bullseye
```

### Custom mirror / firmware

```bash
podman run --rm -v "$(pwd)/output:/output:Z" \
  -e MIRROR=http://my-mirror/debian \
  -e FIRMWARE_URL=https://my-mirror/firmware-bnx2x.deb \
  debian-iso-builder bookworm
```

> **Note:** `:Z` pada volume mount diperlukan jika SELinux dalam mode Enforcing
> (default di RHEL/Rocky/AlmaLinux). Tanpa `:Z`, container tidak dapat menulis
> ke direktori output. Jika SELinux disabled/permissive, `:Z` tidak diperlukan.

## Output

Custom ISO tersimpan di `output/` directory:

```
debian-10-custom-YYYYMM.iso
debian-11-custom-YYYYMM.iso
debian-12-custom-YYYYMM.iso
```

## Environment variables

| Variable         | Default                                                                 |
|------------------|-------------------------------------------------------------------------|
| `MIRROR`         | `http://mirror.biznetgio.com/debian`                                   |
| `ARCHIVE_MIRROR` | `http://archive.debian.org/debian` (untuk EOL releases seperti buster) |
| `FIRMWARE_URL`   | Pin specific firmware-bnx2x .deb URL (default: auto-detect latest)     |
| `OUTPUT_DIR`     | `/output`                                                              |

## Yang dilakukan container

1. Download mini.iso dari mirror (fallback ke archive untuk EOL releases)
2. Download firmware packages (firmware-bnx2x + firmware-qlogic, auto-detect versi terbaru)
3. Extract initrd.gz dari ISO (via xorriso, tanpa mount)
4. Unpack initrd (zcat + cpio, --no-preserve-owner untuk rootless)
5. Inject firmware ke initrd (dpkg-deb -x, dengan path fix usr→lib)
6. Repack initrd (cpio + gzip)
7. Rebuild ISO dengan initrd baru (xorriso, preserve boot config)
