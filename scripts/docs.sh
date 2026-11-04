#!/bin/sh
# Regenerates the terraform-docs section of the root module README, between the
# BEGIN_TF_DOCS and END_TF_DOCS markers. Downloads a pinned, checksummed
# terraform-docs into the user cache on first use.
#
#   ./docs.sh [--check]
#
# --check fails when the README is out of date instead of rewriting it.
set -eu

readonly LOG_PREFIX="docs"
readonly TERRAFORM_DOCS_VERSION="v0.24.0"

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"

_sha256_for() {
  case "$1" in
  darwin-amd64) echo 3c3f7f18f908457fd1209cbe341418f7f6bae78c08126cfbe8de0d1b06aa8781 ;;
  darwin-arm64) echo f6b114f4b032f3f9202ab6c23bfd28c3c8e68aeeb8a8f12fc118bf2073081d71 ;;
  linux-amd64) echo 9005daf969de0b50134493a2c00078b49f5f5b39d021cda7c89bf4d4f3d776d3 ;;
  linux-arm64) echo d12bd7b73c1fc9c64efc79f8157dd713dabd559f1ecf3cfc0f42e32279a155fd ;;
  *) die "no terraform-docs checksum for platform: $1" ;;
  esac
}

_platform() {
  _platform_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  _platform_arch="$(uname -m)"
  case "$_platform_arch" in
  x86_64) _platform_arch=amd64 ;;
  aarch64) _platform_arch=arm64 ;;
  esac
  echo "$_platform_os-$_platform_arch"
}

_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# Prints the path of the pinned terraform-docs binary, downloading it if absent.
_ensure_terraform_docs() {
  _ensure_dir="${XDG_CACHE_HOME:-$HOME/.cache}/terraform-aws-thelounge/terraform-docs-$TERRAFORM_DOCS_VERSION"
  _ensure_bin="$_ensure_dir/terraform-docs"
  if [ ! -x "$_ensure_bin" ]; then
    require curl tar
    _ensure_platform="$(_platform)"
    _ensure_want="$(_sha256_for "$_ensure_platform")"
    _ensure_archive="terraform-docs-$TERRAFORM_DOCS_VERSION-$_ensure_platform.tar.gz"
    mkdir -p "$_ensure_dir"
    log "downloading $_ensure_archive"
    curl -fsSL -o "$_ensure_dir/$_ensure_archive" \
      "https://github.com/terraform-docs/terraform-docs/releases/download/$TERRAFORM_DOCS_VERSION/$_ensure_archive"
    [ "$(_sha256_of "$_ensure_dir/$_ensure_archive")" = "$_ensure_want" ] ||
      die "checksum mismatch for $_ensure_archive"
    tar -xzf "$_ensure_dir/$_ensure_archive" -C "$_ensure_dir" terraform-docs
    rm -f "$_ensure_dir/$_ensure_archive"
  fi
  echo "$_ensure_bin"
}

main() {
  _main_check=""
  case "$#:${1:-}" in
  0:) ;;
  1:--check) _main_check="--output-check" ;;
  *) usage ;;
  esac
  _main_bin="$(_ensure_terraform_docs)"
  # shellcheck disable=SC2086 # empty _main_check must expand to nothing
  "$_main_bin" --config "$REPO_ROOT/.terraform-docs.yml" $_main_check "$REPO_ROOT"
}

main "$@"
