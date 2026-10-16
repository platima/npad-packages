#!/bin/sh
# Download the .deb/.rpm assets (and their .sha256 files) of the newest stable
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

for tag in $tags; do
	echo "== $tag"
	# A release without Linux packages (older ones, or an interrupted build)
	# is skipped, not fatal: the others still publish. Any other failure
	# (network, auth) is fatal, so a flaky download cannot drop a version.
	if ! gh release download "$tag" --repo "$SOURCE_REPO" --dir "$out" --clobber \
		--pattern 'npad_*_amd64.deb*' --pattern 'npad-*.x86_64.rpm*' 2>"$out/.err"; then
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
for pkg in npad_*_amd64.deb npad-*.x86_64.rpm; do
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
ls npad_*_amd64.deb >/dev/null 2>&1 || {
	echo "ERROR: no .deb found; refusing to publish an empty apt repository" >&2
	exit 1
}
ls npad-*.x86_64.rpm >/dev/null 2>&1 || {
	echo "ERROR: no .rpm found; refusing to publish an empty dnf repository" >&2
	exit 1
}
echo "Fetched $count packages"
