#!/bin/bash
set -euo pipefail

# ============================================================
# Debian mini.iso builder with multiple firmware injection
# (firmware-bnx2x + firmware-qlogic)
# Runs inside a Podman container
# ============================================================

MIRROR="${MIRROR:-http://mirror.biznetgio.com/debian}"
ARCHIVE_MIRROR="${ARCHIVE_MIRROR:-http://archive.debian.org/debian}"
FIRMWARE_URL="${FIRMWARE_URL:-}"
FIRMWARE_DIR_URL="${MIRROR}/pool/non-free-firmware/f/firmware-nonfree"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

VALID_VERSIONS="buster bullseye bookworm"
declare -A CODENAME_TO_VERSION=(
    [buster]=10
    [bullseye]=11
    [bookworm]=12
)
FIRMWARE_PACKAGES=(
    firmware-bnx2x
    firmware-qlogic
)

usage() {
    cat <<EOF
Usage: $0 [buster|bullseye|bookworm] ...
  No args = build all three versions

Environment:
  MIRROR         Debian mirror (default: $MIRROR)
  ARCHIVE_MIRROR Debian archive mirror for EOL releases (default: $ARCHIVE_MIRROR)
  FIRMWARE_URL   Pin specific firmware-bnx2x .deb URL (default: auto-detect latest)
  OUTPUT_DIR     Output directory (default: /output)
EOF
    exit 0
}

[[ "${1:-}" =~ ^(-h|--help)$ ]] && usage

# Validate args
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

download_fw() {
    local workdir="$1"
    local pkg="$2"

    local file
    file=$(wget -q -O - "${FIRMWARE_DIR_URL}/" |
        grep -oP "href=\"${pkg}_[^\"]+_all\\.deb\"" |
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
    local ver="${CODENAME_TO_VERSION[$codename]}"
    local stamp
    stamp=$(date +%Y%m)
    local custom_name="debian-${ver}-custom-${stamp}.iso"

    echo
    echo "=========================================="
    echo " Building Debian ${codename}"
    echo "=========================================="

    local workdir
    workdir=$(mktemp -d)

    # --- 1. Download mini.iso ---
    echo -n "[1/7] Download mini.iso... "
    if ! wget -q -O "${workdir}/mini.iso" "$iso_url"; then
        if ! wget -q -O "${workdir}/mini.iso" "$archive_iso_url"; then
            echo "FAIL"
            echo "      Tried: $iso_url"
            echo "      Tried: $archive_iso_url"
            rm -rf "$workdir"
            return 1
        fi
        echo "archive ($(du -h "${workdir}/mini.iso" | cut -f1))"
    else
        echo "OK ($(du -h "${workdir}/mini.iso" | cut -f1))"
    fi

    # --- 2. Download firmware packages ---
    echo "[2/7] Download firmware packages..."
    for pkg in "${FIRMWARE_PACKAGES[@]}"; do
        echo -n "      ${pkg}... "
        # Pin specific URL for firmware-bnx2x if FIRMWARE_URL is set
        if [ "$pkg" = "firmware-bnx2x" ] && [ -n "$FIRMWARE_URL" ]; then
            if ! wget -q -O "${workdir}/${pkg}.deb" "$FIRMWARE_URL"; then
                echo "FAIL"
                rm -rf "$workdir"
                return 1
            fi
            echo "OK"
        else
            if ! download_fw "$workdir" "$pkg"; then
                echo "FAIL"
                rm -rf "$workdir"
                return 1
            fi
            echo "OK"
        fi
    done

    # --- 3. Extract ISO ---
    echo -n "[3/7] Extract ISO... "
    xorriso -osirrox on -indev "${workdir}/mini.iso" \
        -extract / "${workdir}/iso_content/" >/dev/null 2>&1 || {
        echo "FAIL (xorriso extract failed)"
        rm -rf "$workdir"
        return 1
    }
    echo "OK"

    # Locate initrd.gz
    local initrd_path
    initrd_path=$(find "${workdir}/iso_content" -name initrd.gz -type f | head -1)
    if [ -z "$initrd_path" ]; then
        echo "  FAIL: initrd.gz not found in ISO"
        rm -rf "$workdir"
        return 1
    fi
    local initrd_rel="${initrd_path#${workdir}/iso_content/}"

    # --- 4. Unpack initrd ---
    echo -n "[4/7] Unpack initrd... "
    mkdir -p "${workdir}/initrd_unpacked"
    (
        cd "${workdir}/initrd_unpacked"
        zcat "${initrd_path}" | cpio -idm --no-preserve-owner --quiet 2>/dev/null || true
    )
    # Validate unpack produced content
    if [ ! -d "${workdir}/initrd_unpacked/bin" ] && \
       [ ! -f "${workdir}/initrd_unpacked/lib" ] && \
       [ ! -d "${workdir}/initrd_unpacked/etc" ]; then
        echo "FAIL (initrd unpack produced no content)"
        rm -rf "$workdir"
        return 1
    fi
    echo "OK"

    # --- 5. Inject firmware ---
    echo "[5/7] Inject firmware..."
    for pkg in "${FIRMWARE_PACKAGES[@]}"; do
        echo "      extracting ${pkg}"
        dpkg-deb -x "${workdir}/${pkg}.deb" "${workdir}/initrd_unpacked/"
    done

    # Fix: firmware .deb uses usr/lib/firmware/, initrd expects lib/firmware/
    if [ -d "${workdir}/initrd_unpacked/usr/lib/firmware" ]; then
        mkdir -p "${workdir}/initrd_unpacked/lib"
        cp -a "${workdir}/initrd_unpacked/usr/lib/firmware" \
              "${workdir}/initrd_unpacked/lib/"
    fi

    local fwcount
    fwcount=$(find "${workdir}/initrd_unpacked/lib/firmware" -type f | wc -l)
    if [ "$fwcount" -eq 0 ]; then
        echo "  FAIL: no firmware files found after injection"
        rm -rf "$workdir"
        return 1
    fi
    echo "      firmware files: ${fwcount}"

    # --- 6. Repack initrd ---
    echo -n "[6/7] Repack initrd... "
    (
        cd "${workdir}/initrd_unpacked"
        find . -print0 | \
        cpio -0 -H newc -o --owner=0:0 --quiet 2>/dev/null | \
        gzip -c > "${workdir}/new_initrd.gz"
    )
    if [ ! -s "${workdir}/new_initrd.gz" ]; then
        echo "FAIL (repacked initrd is empty)"
        rm -rf "$workdir"
        return 1
    fi
    echo "OK ($(du -h "${workdir}/new_initrd.gz" | cut -f1))"

    # --- 7. Build ISO ---
    echo -n "[7/7] Build ISO... "
    local tmp_iso="${workdir}/${custom_name}"
    xorriso \
        -indev "${workdir}/mini.iso" \
        -outdev "${tmp_iso}" \
        -boot_image any keep \
        -map "${workdir}/new_initrd.gz" "/${initrd_rel}" \
        >/dev/null 2>&1 || {
        echo "FAIL (xorriso repack failed)"
        rm -rf "$workdir"
        return 1
    }

    if [ ! -s "$tmp_iso" ]; then
        echo "FAIL (xorriso produced empty ISO)"
        rm -rf "$workdir"
        return 1
    fi

    cp "$tmp_iso" "${OUTPUT_DIR}/" || {
        echo "FAIL (could not copy ISO to output volume)"
        rm -rf "$workdir"
        return 1
    }

    echo "OK ($(du -h "${OUTPUT_DIR}/${custom_name}" | cut -f1))"

    rm -rf "${workdir}"
    return 0
}

# ===== Main =====
PASS=0
FAIL=0
FAILED_VERSIONS=""

for v in "${VERSIONS[@]}"; do
    if build_iso "$v"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_VERSIONS="${FAILED_VERSIONS} ${v}"
    fi
done

echo
echo "=========================================="
echo " Summary: ${PASS} PASS, ${FAIL} FAIL"
if [ -n "$FAILED_VERSIONS" ]; then
    echo " Failed:${FAILED_VERSIONS}"
fi
echo "=========================================="

ls -lh "${OUTPUT_DIR}"/*.iso 2>/dev/null || echo "  (no ISO files)"
