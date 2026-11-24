#!/data/data/com.termux/files/usr/bin/bash
# Copyright (c) 2026 Joshua Almeida
#
# Built-in `grok` command for this Termux fork.
# Installs and runs the official xAI Grok Build (https://x.ai/cli), unmodified.
# This is not the third-party grok-termux package.
#
# Why this wrapper fetches the official linux artifact itself:
#   - npm package @xai-official/grok is official, but its "os" field is
#     ["darwin","linux","win32"]. npm on Termux reports platform "android",
#     so `npm i -g @xai-official/grok` is refused.
#   - The official installer (https://x.ai/cli/install.sh) uses uname (Linux +
#     aarch64/x86_64) and downloads grok-${version}-linux-aarch64 from
#     https://x.ai/cli (fallback: storage.googleapis.com/grok-build-public-artifacts/cli).
#     It then runs the binary with --version outside a chroot, and prepends
#     ~/.grok/bin to PATH, which would bypass this wrapper (and termux-chroot).
#   So this script uses the same official download URLs and channel pointer as
#   install.sh, verifies the artifact, stores the unmodified binary off PATH,
#   and runs it in a termux-chroot/proot environment so the static musl binary
#   can read /etc/resolv.conf. Arguments are passed through as a real argv
#   (termux-chroot itself uses `sh -c "$*"`, which breaks quoted args).
#
# `grok login` always adds --device-auth unless it is already present.
# Channel pointer is https://x.ai/cli/stable (1.0.92 at wrapper authorship).

set -eu
set -o pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"
OFFICIAL_DIR="${TERMUX_HOME}/.grok/official"
OFFICIAL_BIN="${OFFICIAL_DIR}/grok"
CHANNEL="${GROK_CHANNEL:-stable}"
BASE_URL_PRIMARY="https://x.ai/cli"
BASE_URL_FALLBACK="https://storage.googleapis.com/grok-build-public-artifacts/cli"
# Official installer caps decompressed binaries at 512 MiB.
MAX_BYTES=$((512 * 1024 * 1024))
MIN_BYTES=$((10 * 1024 * 1024))

log() { printf '%s\n' "$*" >&2; }
die() { log "grok: $*"; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ensure_pkg() {
    local pkg="$1"
    if need_cmd "$pkg"; then
        return 0
    fi
    if ! need_cmd pkg; then
        die "missing '$pkg' and 'pkg' is not available to install it"
    fi
    log "grok: installing Termux package '$pkg'..."
    pkg install -y "$pkg" || die "failed to install '$pkg'"
}

official_platform() {
    local machine
    machine="$(uname -m 2>/dev/null || true)"
    case "$machine" in
        aarch64|arm64|ARM64) printf '%s\n' "linux-aarch64" ;;
        x86_64|amd64|AMD64) printf '%s\n' "linux-x86_64" ;;
        *) die "official Grok Build has no Termux binary for architecture '$machine' (needs aarch64 or x86_64)" ;;
    esac
}

expected_elf_machine() {
    # ELF e_machine as a decimal value (od -tu2), little-endian.
    case "$1" in
        linux-aarch64) printf '%s\n' "183" ;;  # 0xB7
        linux-x86_64) printf '%s\n' "62" ;;    # 0x3E
        *) die "internal error: unknown platform $1" ;;
    esac
}

download_to() {
    local url="$1" dest="$2"
    if need_cmd curl; then
        curl -fL --progress-bar -o "$dest" "$url"
    elif need_cmd wget; then
        wget -O "$dest" "$url"
    else
        die "curl or wget is required to download the official Grok Build"
    fi
}

download_stdout() {
    local url="$1"
    if need_cmd curl; then
        curl -fsSL "$url"
    elif need_cmd wget; then
        wget -q -O - "$url"
    else
        die "curl or wget is required to download the official Grok Build"
    fi
}

url_exists() {
    local url="$1" code
    if need_cmd curl; then
        code="$(curl -o /dev/null -sSL -w '%{http_code}' --head "$url" || true)"
    else
        return 1
    fi
    [ "$code" != "404" ] && [ "$code" != "000" ] && [ -n "$code" ]
}

fetch_channel_version() {
    local base="$1" raw
    raw="$(download_stdout "${base}/${CHANNEL}" || true)"
    printf '%s' "$raw" | tr -d '\r' | head -n1 | tr -d '[:space:]'
}

resolve_base_and_version() {
    local version="" base=""
    version="$(fetch_channel_version "$BASE_URL_PRIMARY" || true)"
    if [ -n "$version" ]; then
        base="$BASE_URL_PRIMARY"
    else
        log "grok: ${BASE_URL_PRIMARY} unreachable, trying official GCS fallback..."
        version="$(fetch_channel_version "$BASE_URL_FALLBACK" || true)"
        base="$BASE_URL_FALLBACK"
    fi
    [ -n "$version" ] || die "failed to fetch latest ${CHANNEL} version from ${BASE_URL_PRIMARY}/${CHANNEL} and ${BASE_URL_FALLBACK}/${CHANNEL}"
    case "$version" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) die "official channel pointer returned invalid version: $version" ;;
    esac
    printf '%s %s\n' "$base" "$version"
}

# Verify an official ELF in-place. Does not modify the file bytes.
verify_official_elf() {
    local path="$1" platform="$2" size machine_le expected
    [ -s "$path" ] || die "downloaded official binary is empty"
    size="$(wc -c < "$path" | tr -d ' ')"
    if [ "$size" -lt "$MIN_BYTES" ] || [ "$size" -gt "$MAX_BYTES" ]; then
        die "official binary size ${size} is outside the expected range"
    fi
    # ELF magic \x7fELF
    [ "$(od -An -N4 -tx1 "$path" | tr -d ' \n')" = "7f454c46" ] || die "official artifact is not an ELF binary"
    # EI_CLASS=2 (64-bit), EI_DATA=1 (little endian)
    [ "$(od -An -j4 -N1 -tu1 "$path" | tr -d ' ')" = "2" ] || die "official artifact is not a 64-bit ELF"
    [ "$(od -An -j5 -N1 -tu1 "$path" | tr -d ' ')" = "1" ] || die "official artifact is not little-endian"
    # e_type at offset 16: ET_EXEC = 2
    [ "$(od -An -j16 -N2 -tu2 "$path" | tr -d ' ')" = "2" ] || die "official artifact is not a static ET_EXEC binary"
    # e_machine at offset 18: AArch64=183 (0xB7), x86_64=62 (0x3E)
    machine_le="$(od -An -j18 -N2 -tu2 "$path" | tr -d ' ')"
    expected="$(expected_elf_machine "$platform")"
    [ "$machine_le" = "$expected" ] || die "official artifact architecture is ${machine_le}, expected ${expected} for ${platform}"
    # PT_INTERP is program header type 3. A static musl binary has none.
    local phnum phoff phentsize i off p_type
    phoff="$(od -An -j32 -N8 -tu8 "$path" | tr -d ' ')"
    phentsize="$(od -An -j54 -N2 -tu2 "$path" | tr -d ' ')"
    phnum="$(od -An -j56 -N2 -tu2 "$path" | tr -d ' ')"
    i=0
    while [ "$i" -lt "$phnum" ]; do
        off=$((phoff + i * phentsize))
        p_type="$(od -An -j"$off" -N4 -tu4 "$path" | tr -d ' ')"
        if [ "$p_type" = "3" ]; then
            die "official artifact is dynamically linked; expected a static musl-style binary"
        fi
        i=$((i + 1))
    done
}

install_official_grok() {
    local platform base version artifact_base tmpdir work unpacked
    platform="$(official_platform)"
    # shellcheck disable=SC2086
    set -- $(resolve_base_and_version)
    base="$1"
    version="$2"
    artifact_base="${base}/grok-${version}-${platform}"

    log "grok: installing official xAI Grok Build ${version} (${platform})"
    log "grok: source ${artifact_base}"
    log "grok: npm @xai-official/grok is not used because it refuses the Android/Termux platform."

    ensure_pkg curl
    mkdir -p "$OFFICIAL_DIR" "$OFFICIAL_DIR/tmp"
    tmpdir="$(mktemp -d "${OFFICIAL_DIR}/tmp/dl.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    work="${tmpdir}/artifact"
    unpacked="${tmpdir}/grok"
    if url_exists "${artifact_base}.zst"; then
        ensure_pkg zstd
        log "grok: downloading official zstd artifact..."
        download_to "${artifact_base}.zst" "${work}.zst"
        zstd -q -dc "${work}.zst" > "$unpacked" || die "failed to decompress official .zst artifact"
    elif url_exists "${artifact_base}.gz"; then
        log "grok: downloading official gzip artifact..."
        download_to "${artifact_base}.gz" "${work}.gz"
        gzip -dc "${work}.gz" > "$unpacked" || die "failed to decompress official .gz artifact"
    else
        log "grok: downloading official uncompressed artifact..."
        download_to "$artifact_base" "$unpacked"
    fi

    verify_official_elf "$unpacked" "$platform"
    chmod +x "$unpacked"
    # Replace the installed official binary atomically. Never patch its bytes.
    mv -f "$unpacked" "$OFFICIAL_BIN"
    printf '%s\n' "$version" > "${OFFICIAL_DIR}/version"
    printf '%s\n' "$platform" > "${OFFICIAL_DIR}/platform"
    printf '%s\n' "${artifact_base}" > "${OFFICIAL_DIR}/source"
    log "grok: installed official Grok Build ${version} to ${OFFICIAL_BIN} (unmodified)"
    trap - RETURN
    rm -rf "$tmpdir"
}

ensure_resolv_conf() {
    # Inside termux-chroot, $PREFIX/etc/resolv.conf is /etc/resolv.conf, which
    # a static musl binary uses for DNS. Create a default if Termux has none.
    local resolv="${PREFIX}/etc/resolv.conf"
    if [ -s "$resolv" ]; then
        return 0
    fi
    mkdir -p "${PREFIX}/etc"
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$resolv"
    log "grok: wrote ${resolv} so musl DNS works under termux-chroot"
}

ensure_proot() {
    if [ ! -x "${PREFIX}/bin/proot" ]; then
        ensure_pkg proot
    fi
    [ -x "${PREFIX}/bin/proot" ] || die "proot is required to run official Grok under a termux-chroot environment"
}

# Same filesystem layout as termux-chroot, but exec the official binary with a
# real argv so arguments pass through. See packages/proot/termux-chroot.
run_under_termux_chroot() {
    local args
    args=(--kill-on-exit -b /system:/system)
    if [ -d /vendor ]; then
        args+=(-b /vendor:/vendor)
    fi
    args+=(-b /data:/data)
    if [ -d /sbin ] && [ -d /root ]; then
        args+=(-b /sbin:/sbin -b /root:/root)
    fi
    if [ -d /apex ]; then
        args+=(-b /apex:/apex)
    fi
    if [ -e /linkerconfig/ld.config.txt ]; then
        args+=(-b /linkerconfig/ld.config.txt:/linkerconfig/ld.config.txt)
    fi
    if [ -f /property_contexts ]; then
        args+=(-b /property_contexts:/property_contexts)
    fi
    if [ -d /storage ]; then
        args+=(-b /storage:/storage)
    fi
    args+=(-b "${PREFIX}:/usr")
    local f
    for f in bin etc lib share tmp var; do
        args+=(-b "${PREFIX}/${f}:/${f}")
    done
    args+=(-b /dev:/dev -b /proc:/proc)
    # Keep the caller's cwd, as termux-chroot does when given a command.
    args+=(--cwd=. -r "${PREFIX}/..")

    local bin_abs
    bin_abs="$(readlink -f "$OFFICIAL_BIN" 2>/dev/null || printf '%s' "$OFFICIAL_BIN")"
    [ -x "$bin_abs" ] || die "official Grok binary is missing at ${OFFICIAL_BIN}"

    # HOME=/home is what termux-chroot exports; it maps to $TERMUX_HOME.
    HOME=/home exec "${PREFIX}/bin/proot" "${args[@]}" "$bin_abs" "$@"
}

adjust_login_args() {
    # If the command is `login`, require --device-auth.
    if [ "${1-}" != "login" ]; then
        return 0
    fi
    local arg found=0
    for arg in "$@"; do
        if [ "$arg" = "--device-auth" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        shift
        set -- login --device-auth "$@"
    fi
    # Promote the adjusted argv to the caller.
    ADJUSTED_ARGS=("$@")
}

if [ ! -x "$OFFICIAL_BIN" ]; then
    install_official_grok
fi

ensure_proot
ensure_resolv_conf

ADJUSTED_ARGS=("$@")
adjust_login_args "$@"
if [ "${#ADJUSTED_ARGS[@]}" -gt 0 ]; then
    run_under_termux_chroot "${ADJUSTED_ARGS[@]}"
else
    run_under_termux_chroot
fi
