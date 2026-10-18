#!/bin/sh
# Download the .deb/.rpm/Arch package assets (and their .sha256 files) of the newest stable
# npad releases and verify every checksum.
# Usage: scripts/fetch-releases.sh <assets-dir>
# Needs the GitHub CLI (gh) authenticated via GH_TOKEN or `gh auth login`.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/config.env"
out=${1:?usage: fetch-releases.sh <assets-dir>}

rm -rf "$out"
mkdir -p "$out"

# Newest first; drafts and pre-releases never reach the repositories.
tags=$(gh api "repos/$SOURCE_REPO/releases?per_page=50" \
	--jq '[.[] | select(.draft == false and .prerelease == false)] | .[].tag_name' |
	head -n "$KEEP_RELEASES")
[ -n "$tags" ] || {
	echo "ERROR: no stable releases found in $SOURCE_REPO" >&2
	exit 1
}

# gh's --pattern list: each published architecture's package and the .sha256
# beside it (positional parameters, so the shell never globs the patterns)
set --
for arch in $DEB_ARCHES; do
	set -- "$@" --pattern "npad_*_$arch.deb*"
done
for arch in $RPM_ARCHES; do
	set -- "$@" --pattern "npad-*.$arch.rpm*"
done
# Arch packages: npad-<version>-1-<arch>.pkg.tar.zst
for arch in $ARCH_ARCHES; do
	set -- "$@" --pattern "npad-*-1-$arch.pkg.tar.zst*"
done

for tag in $tags; do
	echo "== $tag"
	# A release without Linux packages (older ones, or an interrupted build)
	# is skipped, not fatal: the others still publish. Any other failure
	# (network, auth) is fatal, so a flaky download cannot drop a version.
	# A release that predates an architecture simply has no file for it.
	if ! gh release download "$tag" --repo "$SOURCE_REPO" --dir "$out" --clobber \
		"$@" 2>"$out/.err"; then
		if grep -q 'no assets match' "$out/.err"; then
			echo "   no Linux packages attached to $tag; skipping"
		else
			cat "$out/.err" >&2
			exit 1
		fi
	fi
done

# Every package must have a matching checksum that verifies; a package that
# cannot be verified is an error, never silently dropped.
rm -f "$out/.err"
cd "$out"
count=0
for pkg in npad_*.deb npad-*.rpm npad-*.pkg.tar.zst; do
	[ -e "$pkg" ] || continue
	if [ ! -f "$pkg.sha256" ]; then
		echo "ERROR: $pkg has no $pkg.sha256 on its release" >&2
		exit 1
	fi
	sha256sum -c "$pkg.sha256"
	count=$((count + 1))
done
[ "$count" -gt 0 ] || {
	echo "ERROR: no npad packages found on the newest $KEEP_RELEASES releases" >&2
	exit 1
}
for arch in $DEB_ARCHES; do
	echo "deb $arch: $(ls npad_*_"$arch".deb 2>/dev/null | wc -l)"
done
for arch in $RPM_ARCHES; do
	echo "rpm $arch: $(ls npad-*."$arch".rpm 2>/dev/null | wc -l)"
done
for arch in $ARCH_ARCHES; do
	echo "arch $arch: $(ls npad-*-1-"$arch".pkg.tar.zst 2>/dev/null | wc -l)"
done
ls npad_*.deb >/dev/null 2>&1 || {
	echo "ERROR: no .deb found; refusing to publish an empty apt repository" >&2
	exit 1
}
ls npad-*.rpm >/dev/null 2>&1 || {
	echo "ERROR: no .rpm found; refusing to publish an empty dnf repository" >&2
	exit 1
}
# Arch packages are optional: the newest releases may predate them (v0.35.0
# has none), in which case build-repos.sh publishes apt and dnf only
ls npad-*.pkg.tar.zst >/dev/null 2>&1 || echo "note: no Arch packages on these releases; no pacman repository will be published"
echo "Fetched $count packages"
