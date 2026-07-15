#!/bin/bash
set -euo pipefail

# ============================================================
# Debian mini.iso builder with bnx2x firmware injection
# Runs inside a Podman container — no Debian server needed
# ============================================================

MIRROR="${MIRROR:-http://mirror.biznetgio.com/debian}"
ARCHIVE_MIRROR="${ARCHIVE_MIRROR:-http://archive.debian.org/debian}"
FIRMWARE_URL="${FIRMWARE_URL:-}"
FIRMWARE_DIR_URL="${MIRROR}/pool/non-free-firmware/f/firmware-nonfree"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

VALID_VERSIONS="buster bullseye bookworm"

usage() {
    cat <<EOF
Usage: $0 [buster|bullseye|bookworm] ...
  No args = build all three versions

Environment:
  MIRROR         Debian mirror (default: $MIRROR)
  ARCHIVE_MIRROR Debian archive mirror for EOL releases (default: $ARCHIVE_MIRROR)
  FIRMWARE_URL   firmware-bnx2x .deb URL (default: auto-detect latest)
  OUTPUT_DIR     Output directory (default: /output)
EOF
    exit 0
}

# Parse args
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

if [ "$#" -gt 0 ]; then
    VERSIONS=("$@")
    for v in "${VERSIONS[@]}"; do
        if ! echo "$VALID_VERSIONS" | grep -qw "$v"; then
            echo "ERROR: Unknown version '$v' (valid: $VALID_VERSIONS)"
            exit 1
        fi
    done
else
    VERSIONS=(buster bullseye bookworm)
fi

mkdir -p "$OUTPUT_DIR"

build_iso() {
    local codename="$1"
    local iso_url="${MIRROR}/dists/${codename}/main/installer-amd64/current/images/netboot/mini.iso"
    local custom_name="debian-${codename}-bnx2x-custom.iso"

    echo ""
    echo "=========================================="
    echo " Building: Debian ${codename} + bnx2x"
    echo "=========================================="

    local workdir
    workdir=$(mktemp -d)

    # 1. Download mini.iso (try primary mirror, fall back to archive for EOL releases)
    echo -n "  [1/7] Download mini.iso... "
    if ! wget -q -O "${workdir}/mini.iso" "$iso_url" 2>&1; then
        # EOL releases like buster are moved to archive
        local archive_iso_url="${ARCHIVE_MIRROR}/dists/${codename}/main/installer-amd64/current/images/netboot/mini.iso"
        if ! wget -q -O "${workdir}/mini.iso" "$archive_iso_url" 2>&1; then
            echo "FAIL"
            echo "        Tried: $iso_url"
            echo "        Tried: $archive_iso_url"
            rm -rf "$workdir"
            return 1
        fi
        echo "OK from archive ($(du -h "${workdir}/mini.iso" | cut -f1))"
    else
        echo "OK ($(du -h "${workdir}/mini.iso" | cut -f1))"
    fi

    # 2. Download firmware deb (auto-detect latest if FIRMWARE_URL not set)
    echo -n "  [2/7] Download firmware-bnx2x.deb... "
    local fw_url="$FIRMWARE_URL"
    if [ -z "$fw_url" ]; then
        # Auto-detect latest firmware-bnx2x from mirror directory listing
        fw_url=$(wget -q -O - "$FIRMWARE_DIR_URL/" 2>/dev/null | \
            grep -oP 'href="firmware-bnx2x_[^"]+_all\.deb"' | \
            sed 's/href="//;s/"//' | \
            grep -v 'bpo' | \
            sort -V | tail -1)
        if [ -n "$fw_url" ]; then
            fw_url="${FIRMWARE_DIR_URL}/${fw_url}"
        fi
    fi
    if [ -z "$fw_url" ]; then
        echo "FAIL (could not auto-detect firmware URL)"
        rm -rf "$workdir"
        return 1
    fi
    echo -n "URL detected: ${fw_url##*/} ... "
    if ! wget -q -O "${workdir}/firmware-bnx2x.deb" "$fw_url" 2>&1; then
        echo "FAIL"
        echo "        URL: $fw_url"
        rm -rf "$workdir"
        return 1
    fi
    echo "OK ($(du -h "${workdir}/firmware-bnx2x.deb" | cut -f1))"

    # 3. Extract ISO contents
    echo -n "  [3/7] Extract ISO contents... "
    xorriso -osirrox on -indev "${workdir}/mini.iso" \
        -extract / "${workdir}/iso_content/" >/dev/null 2>&1
    if [ ! -d "${workdir}/iso_content" ]; then
        echo "FAIL (xorriso extract failed)"
        rm -rf "$workdir"
        return 1
    fi
    echo "OK"

    # Find initrd.gz (might be at root or in a subdir)
    local initrd_path
    initrd_path=$(find "${workdir}/iso_content/" -name "initrd.gz" -type f | head -1)
    if [ -z "$initrd_path" ]; then
        echo "  FAIL: initrd.gz not found in ISO"
        rm -rf "$workdir"
        return 1
    fi
    local initrd_rel="${initrd_path#${workdir}/iso_content/}"
    echo "        initrd at: /${initrd_rel}"

    # 4. Unpack initrd
    # --no-preserve-owner avoids mknod permission errors in rootless containers
    echo -n "  [4/7] Unpack initrd.gz... "
    mkdir -p "${workdir}/initrd_unpacked"
    (cd "${workdir}/initrd_unpacked" && \
     zcat "${initrd_path}" | cpio -idm --no-preserve-owner --quiet 2>/dev/null || true)
    if [ ! -f "${workdir}/initrd_unpacked/lib" ] && [ ! -d "${workdir}/initrd_unpacked/bin" ]; then
        echo "FAIL (initrd unpack produced no content)"
        rm -rf "$workdir"
        return 1
    fi
    echo "OK"

    # 5. Inject firmware
    echo -n "  [5/7] Inject firmware-bnx2x... "
    dpkg-deb -x "${workdir}/firmware-bnx2x.deb" "${workdir}/initrd_unpacked/"
    # Firmware .deb may use usr/lib/firmware/ while initrd expects lib/firmware/
    if [ -d "${workdir}/initrd_unpacked/usr/lib/firmware/bnx2x" ] && \
       [ ! -d "${workdir}/initrd_unpacked/lib/firmware/bnx2x" ]; then
        mkdir -p "${workdir}/initrd_unpacked/lib/firmware"
        cp -a "${workdir}/initrd_unpacked/usr/lib/firmware/bnx2x" \
              "${workdir}/initrd_unpacked/lib/firmware/"
    fi
    local fw_count
    fw_count=$(find "${workdir}/initrd_unpacked/lib/firmware/" -name "bnx2x*" 2>/dev/null | wc -l)
    if [ "$fw_count" -eq 0 ]; then
        echo "FAIL (no bnx2x firmware found after extraction)"
        rm -rf "$workdir"
        return 1
    fi
    echo "OK (${fw_count} bnx2x firmware files)"

    # 6. Repack initrd
    # --owner=0:0 --group=0:0 sets root ownership explicitly (needed in rootless)
    echo -n "  [6/7] Repack initrd.gz... "
    (cd "${workdir}/initrd_unpacked" && \
     find . -print0 | cpio -0 -H newc -o --owner=0:0 --quiet 2>/dev/null | \
     gzip -c > "${workdir}/new_initrd.gz")
    if [ ! -s "${workdir}/new_initrd.gz" ]; then
        echo "FAIL (repacked initrd is empty)"
        rm -rf "$workdir"
        return 1
    fi
    echo "OK ($(du -h "${workdir}/new_initrd.gz" | cut -f1))"

    # 7. Build custom ISO (preserve boot config, replace initrd)
    # Write to container-local temp first, then copy to output volume
    # (avoids permission/SELinux issues with bind-mounted volumes in rootless Podman)
    echo -n "  [7/7] Build custom ISO... "
    local tmp_iso="${workdir}/${custom_name}"
    xorriso \
        -indev "${workdir}/mini.iso" \
        -outdev "${tmp_iso}" \
        -boot_image any keep \
        -map "${workdir}/new_initrd.gz" "/${initrd_rel}" \
        >/dev/null 2>&1

    if [ -s "${tmp_iso}" ]; then
        cp "${tmp_iso}" "${OUTPUT_DIR}/${custom_name}" 2>/dev/null
        if [ -f "${OUTPUT_DIR}/${custom_name}" ]; then
            echo "OK ($(du -h "${OUTPUT_DIR}/${custom_name}" | cut -f1))"
        else
            echo "FAIL (could not copy ISO to output volume)"
            rm -rf "$workdir"
            return 1
        fi
    else
        echo "FAIL (xorriso repack failed)"
        rm -rf "$workdir"
        return 1
    fi

    rm -rf "$workdir"
    return 0
}

# ===== Main =====
PASS=0
FAIL=0
FAILED_VERSIONS=""

for ver in "${VERSIONS[@]}"; do
    if build_iso "$ver"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_VERSIONS="${FAILED_VERSIONS} ${ver}"
    fi
done

echo ""
echo "=========================================="
echo " Summary: ${PASS} PASS, ${FAIL} FAIL"
if [ -n "$FAILED_VERSIONS" ]; then
    echo " Failed:${FAILED_VERSIONS}"
fi
echo "=========================================="
echo ""
echo "Output files:"
ls -lh "${OUTPUT_DIR}"/*.iso 2>/dev/null || echo "  (no ISO files)"
