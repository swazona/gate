#!/usr/bin/env bash
# install-tools.sh — the ONLY new YAML the rendered gate wrapper runs. Fetches
# (fetch mode, no arguments) or verifies (`verify --dir D --platform P
# --bin-out B`) the three release binaries for one platform against a pinned
# ed25519 signature and a byte-pinned SHA256SUMS manifest, before anything is
# ever executed. Every verification failure (manifest, signature, key id,
# sha256) marks `integrity=failed` on $GITHUB_OUTPUT so action.yml's Abort
# step treats it as loud in every mode, shadow included — tampering must
# fail the check, never degrade to neutral.
set -euo pipefail

# PINNED_RELEASE_KEY_HEX is substituted by gatedist render as
# SWZ_DIST_PUBKEY_HEX at the call site; this script trusts only its own
# arguments and the SWZ_DIST_* environment (never ambient state).
OPENSSL_CANDIDATES=(openssl /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl /usr/local/bin/openssl /usr/bin/openssl)

# CLEANUP_DIRS and the single EXIT trap below are process-wide on purpose:
# verify() and run_fetch() can both register a directory (the bin stage, the
# download dir) without one overwriting the other's `trap ... EXIT` — a
# per-function trap would silently drop an earlier function's cleanup.
CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

usage() {
  echo "::error::swazona-gate: usage: install-tools.sh [verify --dir D --platform P --bin-out B]" >&2
  exit 2
}

err() {
  echo "::error::swazona-gate: $1" >&2
  exit 1
}

err_integrity() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "integrity=failed" >> "$GITHUB_OUTPUT"
  fi
  echo "::error::swazona-gate: $1" >&2
  exit 1
}

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    err "required variable $name is not set"
  fi
}

# platform_for_runner maps RUNNER_OS/RUNNER_ARCH to one of this release's
# three asset-name platform suffixes.
platform_for_runner() {
  case "${RUNNER_OS:-}/${RUNNER_ARCH:-}" in
    Linux/X64) echo "linux-amd64" ;;
    Linux/ARM64) echo "linux-arm64" ;;
    macOS/ARM64) echo "darwin-arm64" ;;
    *) err "unsupported runner platform ${RUNNER_OS:-}/${RUNNER_ARCH:-} (supported: Linux X64, Linux ARM64, macOS ARM64)" ;;
  esac
}

# hex_decode reads a hex string from stdin and writes the raw bytes to $1.
# Binary-safe: the conversion never passes through a shell variable.
hex_decode() {
  local out="$1"
  if command -v xxd >/dev/null 2>&1; then
    xxd -r -p > "$out"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,binascii; sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read().strip()))' > "$out"
  else
    return 1
  fi
}

# find_ed25519_openssl prints the path to the first candidate that can
# actually perform an Ed25519 raw sign+verify round trip — a real capability
# probe, since macOS's stock /usr/bin/openssl (LibreSSL) has no Ed25519
# support at all despite running cleanly on every other subcommand.
find_ed25519_openssl() {
  local probe_dir found cand bin
  probe_dir="$(mktemp -d)"
  found=""
  for cand in "${OPENSSL_CANDIDATES[@]}"; do
    bin="$(command -v "$cand" 2>/dev/null || true)"
    [ -n "$bin" ] || continue
    if "$bin" genpkey -algorithm ed25519 -out "${probe_dir}/k.pem" >/dev/null 2>&1 \
      && "$bin" pkey -in "${probe_dir}/k.pem" -pubout -out "${probe_dir}/k.pub" >/dev/null 2>&1 \
      && printf 'probe' > "${probe_dir}/m" \
      && "$bin" pkeyutl -sign -rawin -inkey "${probe_dir}/k.pem" -in "${probe_dir}/m" -out "${probe_dir}/s" >/dev/null 2>&1 \
      && "$bin" pkeyutl -verify -rawin -pubin -inkey "${probe_dir}/k.pub" -sigfile "${probe_dir}/s" -in "${probe_dir}/m" >/dev/null 2>&1; then
      found="$bin"
      break
    fi
  done
  rm -rf "$probe_dir"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# sha256_of prints the lowercase hex sha256 of $1, trying sha256sum then
# shasum -a 256 (the two tools between them cover every supported runner).
sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    return 1
  fi
}

# verify is the single choke point every install — fetched or pre-staged —
# passes through. Every check in this function completes BEFORE anything is
# installed; the first failure stops the whole install with nothing in B.
verify() {
  local dir="$1" platform="$2" bin_out="$3"
  local sums_file="$dir/SHA256SUMS" sig_file="$dir/SHA256SUMS.sig"

  # (1) pinned pubkey is 64 lowercase hex.
  case "${SWZ_DIST_PUBKEY_HEX:-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) err_integrity "pinned public key is malformed" ;;
  esac

  # Private 0700 stage: the manifest and its signature are copied in ONCE,
  # right here, before anything parses or verifies them, and every check
  # below (the byte comparison, the signature line, pkeyutl, the version
  # header, every per-asset awk lookup) reads only these copies — $sums_file
  # and $sig_file are repointed at the stage and the original dir/SHA256SUMS*
  # path is never opened again. Reading the source path across multiple
  # separate checks, as a single early comparison followed by later re-reads
  # would do, leaves a window for the on-disk manifest to be swapped between
  # them; a one-time copy closes it the same way the per-asset copy below
  # already does for the binaries.
  local stage
  stage="$(mktemp -d "$(dirname "$bin_out")/.bin-stage.XXXXXX")"
  chmod 0700 "$stage"
  CLEANUP_DIRS+=("$stage")
  if [ -L "$sums_file" ]; then
    err_integrity "SHA256SUMS does not match the pinned manifest"
  fi
  if [ ! -f "$sums_file" ]; then
    err_integrity "SHA256SUMS does not match the pinned manifest"
  fi
  if ! cp "$sums_file" "${stage}/SHA256SUMS"; then
    err "install failed"
  fi
  if [ -L "$sig_file" ]; then
    err_integrity "SHA256SUMS.sig is malformed"
  fi
  if [ ! -f "$sig_file" ]; then
    err_integrity "SHA256SUMS.sig is malformed"
  fi
  if ! cp "$sig_file" "${stage}/SHA256SUMS.sig"; then
    err "install failed"
  fi
  sums_file="${stage}/SHA256SUMS"
  sig_file="${stage}/SHA256SUMS.sig"

  # (2) the staged SHA256SUMS is byte-identical to the pinned manifest baked
  # into action.yml at render time. SWZ_DIST_SHA256SUMS_FILE, when set, names
  # a file holding the exact pinned bytes — a caller comparing against an
  # on-disk manifest can pass it directly instead of going through a shell
  # variable, where a command substitution such as "$(cat file)" silently
  # strips the file's trailing newline and breaks the byte-exact comparison.
  # SWZ_DIST_SHA256SUMS (the literal content the rendered production
  # wrapper's env block carries) is the fallback.
  if [ -n "${SWZ_DIST_SHA256SUMS_FILE:-}" ]; then
    if [ ! -f "$SWZ_DIST_SHA256SUMS_FILE" ]; then
      err "required variable SWZ_DIST_SHA256SUMS_FILE names a file that does not exist"
    fi
    if ! cmp -s "$sums_file" "$SWZ_DIST_SHA256SUMS_FILE"; then
      err_integrity "SHA256SUMS does not match the pinned manifest"
    fi
  elif ! cmp -s "$sums_file" <(printf '%s' "${SWZ_DIST_SHA256SUMS:-}"); then
    err_integrity "SHA256SUMS does not match the pinned manifest"
  fi

  # (3) a capable OpenSSL, and xxd or python3, before any decoding.
  local openssl_bin
  if ! openssl_bin="$(find_ed25519_openssl)"; then
    err "no Ed25519-capable openssl found"
  fi
  if ! command -v xxd >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    err "need xxd or python3 to decode hex"
  fi

  # (4) the sig's first non-blank, non-# line: field 1 is 128 hex, field 2
  # equals the pinned key's first 8 hex chars (its key id).
  local sig_line sig_hex sig_keyid pinned_keyid
  sig_line="$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print; exit}' "$sig_file" 2>/dev/null || true)"
  sig_hex="$(printf '%s' "$sig_line" | awk '{print $1}')"
  sig_keyid="$(printf '%s' "$sig_line" | awk '{print $2}')"
  pinned_keyid="${SWZ_DIST_PUBKEY_HEX:0:8}"
  case "$sig_hex" in
    *[!0-9a-fA-F]*|"") err_integrity "SHA256SUMS.sig is malformed" ;;
  esac
  if [ "${#sig_hex}" -ne 128 ]; then
    err_integrity "SHA256SUMS.sig is malformed"
  fi
  if [ "$sig_keyid" != "$pinned_keyid" ]; then
    err_integrity "SHA256SUMS.sig names key $sig_keyid, not the pinned key"
  fi

  # (5) pkeyutl -verify -rawin over the exact downloaded SHA256SUMS bytes.
  local work
  work="$(mktemp -d)"
  if ! printf '302a300506032b6570032100%s' "$SWZ_DIST_PUBKEY_HEX" | hex_decode "${work}/pin.der"; then
    rm -rf "$work"
    err "need xxd or python3 to decode hex"
  fi
  if ! "$openssl_bin" pkey -pubin -inform DER -in "${work}/pin.der" -outform PEM -out "${work}/pin.pem" 2>/dev/null; then
    rm -rf "$work"
    err_integrity "pinned public key is malformed"
  fi
  if ! printf '%s' "$sig_hex" | hex_decode "${work}/sig.bin"; then
    rm -rf "$work"
    err "need xxd or python3 to decode hex"
  fi
  if ! "$openssl_bin" pkeyutl -verify -rawin -pubin -inkey "${work}/pin.pem" \
      -sigfile "${work}/sig.bin" -in "$sums_file" >/dev/null 2>&1; then
    rm -rf "$work"
    err_integrity "release signature verification failed"
  fi
  rm -rf "$work"

  # (6) manifest line 1 carries this release's version.
  local header
  header="$(head -n1 "$sums_file")"
  case "$header" in
    "# swazona-gate-release ${SWZ_DIST_VERSION:-} source="*) ;;
    *) err_integrity "manifest version is not ${SWZ_DIST_VERSION:-}" ;;
  esac

  # SWZ_TEST_AFTER_MANIFEST_VERIFY_HOOK is a test-only seam, never set in
  # production: if present, it names an executable run with ($dir)
  # immediately after signature verification and before the first asset
  # hash, so a test can rewrite the SOURCE manifest (and the asset it now
  # claims to cover) at the latest possible moment and prove the per-asset
  # lookups below still use the manifest copy staged above, not this edit.
  if [ -n "${SWZ_TEST_AFTER_MANIFEST_VERIFY_HOOK:-}" ]; then
    "${SWZ_TEST_AFTER_MANIFEST_VERIFY_HOOK}" "$dir"
  fi

  # (7)/(8) each of the 3 platform assets listed exactly once in the staged
  # SHA256SUMS; install destination must not already exist; then, for each
  # asset, copy the SOURCE into the private 0700 stage ONCE — refusing a
  # symlink or anything but a regular file — hash the COPY against the
  # manifest, and only then chmod it executable. The source is never
  # reopened after the copy: hashing the original and separately copying it
  # later would leave a window where the on-disk asset could be swapped (a
  # symlink repointed, a file replaced) between the hash check and the bytes
  # actually installed.
  if [ -e "$bin_out" ] || [ -L "$bin_out" ]; then
    err "install destination exists: $bin_out"
  fi
  local tool asset expected count got_sum source
  local tools_order=() stage_files=() expected_sums=()
  for tool in swazona-gate swazona-license-verify swazona-evidence; do
    asset="${tool}-${platform}"
    source="${dir}/${asset}"
    count="$(awk -v a="$asset" '$2 == a {n++} END{print n+0}' "$sums_file")"
    if [ "$count" -ne 1 ]; then
      err_integrity "$asset missing or listed twice in SHA256SUMS"
    fi
    expected="$(awk -v a="$asset" '$2 == a {print $1}' "$sums_file")"
    if [ -L "$source" ]; then
      err_integrity "$asset is a symlink, want a regular file"
    fi
    if [ ! -f "$source" ]; then
      err_integrity "$asset missing or listed twice in SHA256SUMS"
    fi
    if ! cp "$source" "${stage}/${tool}"; then
      err "install failed"
    fi
    # SWZ_TEST_AFTER_COPY_HOOK is a test-only seam, never set in production:
    # if present, it names an executable run with ($source, the stage copy)
    # immediately after the copy and before hashing, so a test can swap the
    # original source's bytes here and prove the hash and the installed
    # file still reflect the copy — the source is never reopened after it.
    if [ -n "${SWZ_TEST_AFTER_COPY_HOOK:-}" ]; then
      "${SWZ_TEST_AFTER_COPY_HOOK}" "$source" "${stage}/${tool}"
    fi
    if ! got_sum="$(sha256_of "${stage}/${tool}")"; then
      err "no sha256 tool found"
    fi
    if [ "$got_sum" != "$expected" ]; then
      err_integrity "sha256 mismatch for $asset"
    fi
    chmod 0755 "${stage}/${tool}"
    # SWZ_TEST_AFTER_HASH_HOOK is a test-only seam, never set in production:
    # if present, it names an executable run with (the stage copy) right
    # after its hash has already matched the manifest and before anything
    # is published, so a test can swap the STAGE copy itself here and prove
    # the re-check at publish time (below) catches it rather than letting a
    # late swap of the already-hashed bytes reach bin-out.
    if [ -n "${SWZ_TEST_AFTER_HASH_HOOK:-}" ]; then
      "${SWZ_TEST_AFTER_HASH_HOOK}" "${stage}/${tool}"
    fi
    tools_order+=("$tool")
    stage_files+=("${stage}/${tool}")
    expected_sums+=("$expected")
  done

  # SWZ_TEST_BEFORE_PUBLISH_HOOK is a test-only seam, never set in
  # production: if present, it names an executable run with ($bin_out) right
  # before the atomic publish below, so a test can race a decoy into
  # existence at the destination between the early absence check above and
  # publish, and prove the claim still refuses rather than overwriting or
  # running it.
  if [ -n "${SWZ_TEST_BEFORE_PUBLISH_HOOK:-}" ]; then
    "${SWZ_TEST_BEFORE_PUBLISH_HOOK}" "$bin_out"
  fi

  # Re-verify every staged file's hash immediately before publish: a swap of
  # the stage copy itself between its hash check and the move below (the
  # window SWZ_TEST_AFTER_HASH_HOOK probes) is caught here rather than
  # reaching bin-out.
  local i recheck_sum
  for i in "${!tools_order[@]}"; do
    if ! recheck_sum="$(sha256_of "${stage_files[$i]}")"; then
      err "no sha256 tool found"
    fi
    if [ "$recheck_sum" != "${expected_sums[$i]}" ]; then
      err_integrity "sha256 mismatch for ${tools_order[$i]}-${platform}"
    fi
  done

  # Atomic publish: mkdir is the atomic claim since it fails if $bin_out
  # already exists — checking existence first and then moving the whole
  # stage in second (as this used to) leaves a window a decoy can win by
  # creating the destination in between. Each verified file is then moved in
  # individually with `mv -n`, which refuses to clobber rather than silently
  # overwriting a file something else raced into place inside the freshly
  # claimed directory; the post-move existence check on the stage source
  # catches that no-clobber skip (mv -n exits 0 even when it refuses).
  if ! mkdir "$bin_out" 2>/dev/null; then
    err "install destination exists: $bin_out"
  fi
  for tool in "${tools_order[@]}"; do
    if ! mv -n "${stage}/${tool}" "${bin_out}/${tool}" 2>/dev/null || [ -e "${stage}/${tool}" ]; then
      rm -rf "$bin_out"
      err "install failed"
    fi
  done
}

# run_verify parses `verify --dir D --platform P --bin-out B` and nothing
# else — unrecognised or missing arguments are a usage error (exit 2), never
# a silent default.
run_verify() {
  local dir="" platform="" bin_out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="${2:-}"; shift 2 ;;
      --platform) platform="${2:-}"; shift 2 ;;
      --bin-out) bin_out="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ -z "$dir" ] || [ -z "$platform" ] || [ -z "$bin_out" ]; then
    usage
  fi
  verify "$dir" "$platform" "$bin_out"
}

# run_fetch is the no-argument entry point the rendered install step calls:
# download this platform's manifest, signature and 3 assets into a fresh
# temp directory, then run the exact same verify() a direct `verify` call
# would run — fetch is never a separate, weaker trust path.
run_fetch() {
  require_var RUN_DIR
  require_var RUNNER_OS
  require_var RUNNER_ARCH
  require_var SWZ_DIST_REPO
  require_var SWZ_DIST_VERSION
  require_var SWZ_DIST_PUBKEY_HEX
  if [ -z "${SWZ_DIST_SHA256SUMS:-}" ] && [ -z "${SWZ_DIST_SHA256SUMS_FILE:-}" ]; then
    err "required variable SWZ_DIST_SHA256SUMS is not set"
  fi

  local platform
  platform="$(platform_for_runner)"

  local dl_dir
  dl_dir="$(mktemp -d "${RUN_DIR}/dl.XXXXXX")"
  CLEANUP_DIRS+=("$dl_dir")

  local asset url
  for asset in SHA256SUMS SHA256SUMS.sig \
    "swazona-gate-${platform}" "swazona-license-verify-${platform}" "swazona-evidence-${platform}"; do
    url="https://github.com/${SWZ_DIST_REPO}/releases/download/${SWZ_DIST_VERSION}/${asset}"
    if ! curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --retry-delay 2 --max-time 120 \
        --output "${dl_dir}/${asset}" "$url"; then
      err "download failed: $asset"
    fi
    if [ ! -f "${dl_dir}/${asset}" ]; then
      err "$asset missing from download directory"
    fi
  done

  verify "$dl_dir" "$platform" "${RUN_DIR}/bin"
}

main() {
  if [ $# -eq 0 ]; then
    run_fetch
    return
  fi
  if [ "$1" = "verify" ]; then
    shift
    run_verify "$@"
    return
  fi
  usage
}

main "$@"
