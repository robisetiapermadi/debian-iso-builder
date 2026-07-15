# Debian mini.iso Builder (bnx2x firmware)

Membangun custom Debian netboot mini.iso dengan firmware bnx2x di-inject
ke dalam initrd. Berjalan di dalam Podman/Docker container — tidak perlu Debian server.

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
debian-buster-bnx2x-custom.iso
debian-bullseye-bnx2x-custom.iso
debian-bookworm-bnx2x-custom.iso
```

## Environment variables

| Variable         | Default                                                                 |
|------------------|-------------------------------------------------------------------------|
| `MIRROR`         | `http://mirror.biznetgio.com/debian`                                   |
| `ARCHIVE_MIRROR` | `http://archive.debian.org/debian` (untuk EOL releases seperti buster) |
| `FIRMWARE_URL`   | auto-detect latest dari mirror                                          |
| `OUTPUT_DIR`     | `/output`                                                              |

## Yang dilakukan container

1. Download mini.iso dari mirror (fallback ke archive untuk EOL releases)
2. Download firmware-bnx2x .deb (auto-detect versi terbaru)
3. Extract initrd.gz dari ISO (via xorriso, tanpa mount)
4. Unpack initrd (zcat + cpio)
5. Inject firmware bnx2x ke initrd (dpkg-deb -x, dengan path fix)
6. Repack initrd (cpio + gzip)
7. Rebuild ISO dengan initrd baru (xorriso, preserve boot config)
