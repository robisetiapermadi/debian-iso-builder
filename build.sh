#!/bin/bash
set -euo pipefail

# ============================================================
# Debian mini.iso builder with multiple firmware injection
# (firmware-bnx2x + firmware-qlogic)
# Runs inside a Podman container
# ============================================================

MIRROR="${MIRROR:-http://mirror.biznetgio.com/debian}"
ARCHIVE_MIRROR="${ARCHIVE_MIRROR:-http://archive.debian.org/debian}"
FIRMWARE_DIR_URL="${MIRROR}/pool/non-free-firmware/f/firmware-nonfree"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

VALID_VERSIONS="buster bullseye bookworm"
FIRMWARE_PACKAGES=(
    firmware-bnx2x
    firmware-qlogic
)

usage() {
cat <<EOF
Usage: $0 [buster|bullseye|bookworm] ...

Environment:
  MIRROR
  ARCHIVE_MIRROR
  OUTPUT_DIR
EOF
exit 0
}

[[ "${1:-}" =~ ^(-h|--help)$ ]] && usage

if [ "$#" -gt 0 ]; then
    VERSIONS=("$@")
else
    VERSIONS=(buster bullseye bookworm)
fi

mkdir -p "$OUTPUT_DIR"

download_fw() {
    local workdir="$1"
    local pkg="$2"

    local file
    file=$(wget -q -O - "${FIRMWARE_DIR_URL}/" |
        grep -oP "href=\"${pkg}_[^\"]+_all\.deb\"" |
        sed 's/href="//;s/"//' |
        grep -v bpo |
        sort -V | tail -1)

    [ -n "$file" ] || return 1

    wget -q -O "${workdir}/${pkg}.deb" "${FIRMWARE_DIR_URL}/${file}"
}

build_iso() {
    local codename="$1"
    local iso_url="${MIRROR}/dists/${codename}/main/installer-amd64/current/images/netboot/mini.iso"
    local archive_iso_url="${ARCHIVE_MIRROR}/dists/${codename}/main/installer-amd64/current/images/netboot/mini.iso"
    local custom_name="debian-${codename}-firmware-custom.iso"

    echo
    echo "=========================================="
    echo " Building Debian ${codename}"
    echo "=========================================="

    local workdir
    workdir=$(mktemp -d)

    echo -n "[1/7] Download mini.iso... "
    if ! wget -q -O "${workdir}/mini.iso" "$iso_url"; then
        wget -q -O "${workdir}/mini.iso" "$archive_iso_url"
        echo "archive"
    else
        echo "OK"
    fi

    echo "[2/7] Download firmware packages..."
    for pkg in "${FIRMWARE_PACKAGES[@]}"; do
        echo -n "      ${pkg}... "
        download_fw "$workdir" "$pkg"
        echo OK
    done

    echo -n "[3/7] Extract ISO... "
    xorriso -osirrox on -indev "${workdir}/mini.iso" \
        -extract / "${workdir}/iso_content/" >/dev/null 2>&1
    echo OK

    local initrd_path
    initrd_path=$(find "${workdir}/iso_content" -name initrd.gz | head -1)
    local initrd_rel="${initrd_path#${workdir}/iso_content/}"

    echo -n "[4/7] Unpack initrd... "
    mkdir -p "${workdir}/initrd_unpacked"
    (
      cd "${workdir}/initrd_unpacked"
      zcat "${initrd_path}" | cpio -idm --no-preserve-owner --quiet 2>/dev/null || true
    )
    echo OK

    echo "[5/7] Inject firmware..."
    for pkg in "${FIRMWARE_PACKAGES[@]}"; do
        echo "      extracting ${pkg}"
        dpkg-deb -x "${workdir}/${pkg}.deb" "${workdir}/initrd_unpacked/"
    done

    if [ -d "${workdir}/initrd_unpacked/usr/lib/firmware" ]; then
        mkdir -p "${workdir}/initrd_unpacked/lib"
        cp -a "${workdir}/initrd_unpacked/usr/lib/firmware" \
              "${workdir}/initrd_unpacked/lib/"
    fi

    FWCOUNT=$(find "${workdir}/initrd_unpacked/lib/firmware" -type f | wc -l)
    echo "      firmware files: ${FWCOUNT}"

    echo -n "[6/7] Repack initrd... "
    (
      cd "${workdir}/initrd_unpacked"
      find . -print0 | \
      cpio -0 -H newc -o --owner=0:0 --quiet 2>/dev/null | \
      gzip -c > "${workdir}/new_initrd.gz"
    )
    echo OK

    echo -n "[7/7] Build ISO... "
    xorriso \
      -indev "${workdir}/mini.iso" \
      -outdev "${workdir}/${custom_name}" \
      -boot_image any keep \
      -map "${workdir}/new_initrd.gz" "/${initrd_rel}" \
      >/dev/null 2>&1

    cp "${workdir}/${custom_name}" "${OUTPUT_DIR}/"
    echo OK

    rm -rf "${workdir}"
}

PASS=0
FAIL=0

for v in "${VERSIONS[@]}"; do
    if build_iso "$v"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
done

echo
echo "PASS=${PASS} FAIL=${FAIL}"
ls -lh "${OUTPUT_DIR}"/*.iso 2>/dev/null || true
