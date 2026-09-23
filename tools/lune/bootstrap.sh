#!/usr/bin/env bash
# Install the tools pinned in rokit.toml into tools/lune/.bin, without rokit.
# Each release archive is checked against tools/lune/tools.sha256 before anything is extracted; a missing or
# different checksum stops the install. Already-installed tools at the pinned version are left alone.
# Needs bash, curl, unzip and sha256sum (or shasum). Linux and macOS; on Windows use `rokit install`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bin="$here/.bin"
manifest="$root/rokit.toml"
sums="$here/tools.sha256"

case "$(uname -s)" in
	Linux) os=linux ;;
	Darwin) os=macos ;;
	*) echo "bootstrap.sh: unsupported OS '$(uname -s)'; install the tools with 'rokit install' instead" >&2; exit 1 ;;
esac
case "$(uname -m)" in
	x86_64 | amd64) arch=x86_64 ;;
	arm64 | aarch64) arch=aarch64 ;;
	*) echo "bootstrap.sh: unsupported CPU '$(uname -m)'" >&2; exit 1 ;;
esac

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# `name = "owner/repo@version"` lines of the [tools] table
tools="$(awk '/^\[tools\]/ { t = 1; next } /^\[/ { t = 0 } t && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
	gsub(/[[:space:]"]/, ""); split($0, kv, "="); print kv[1], kv[2] }' "$manifest")"
if [ -z "$tools" ]; then
	echo "bootstrap.sh: no tools found in $manifest" >&2
	exit 1
fi

mkdir -p "$bin"
while read -r name spec; do
	repo="${spec%@*}"
	version="${spec##*@}"
	project="${repo#*/}"
	target="$bin/$name"
	if [ -x "$target" ] && "$target" --version 2>/dev/null | grep -Eq "[[:space:]]$version\$"; then
		echo "bootstrap: $name $version already installed"
		continue
	fi
	asset="$project-$version-$os-$arch.zip"
	expected="$(awk -v a="$asset" '$2 == a { print $1 }' "$sums")"
	if [ -z "$expected" ]; then
		echo "bootstrap.sh: no pinned checksum for $asset in tools/lune/tools.sha256" >&2
		exit 1
	fi
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	url="https://github.com/$repo/releases/download/v$version/$asset"
	curl -fsSL --retry 3 -o "$tmp/$asset" "$url"
	actual="$(sha256 "$tmp/$asset")"
	if [ "$actual" != "$expected" ]; then
		echo "bootstrap.sh: checksum mismatch for $asset" >&2
		echo "  expected $expected (tools/lune/tools.sha256)" >&2
		echo "  got      $actual ($url)" >&2
		exit 1
	fi
	unzip -o -q "$tmp/$asset" -d "$tmp/x"
	install -m 755 "$tmp/x/$project" "$target"
	rm -rf "$tmp"
	trap - EXIT
	echo "bootstrap: installed $name $version from $asset (sha256 verified)"
done <<<"$tools"
