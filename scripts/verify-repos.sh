#!/bin/sh
# Check a built site the way a client would, using only the published public
# key: signatures on the apt and dnf metadata, package checksums, and rpm
# signatures. Fails (non-zero) on the first problem, so a broken or unsigned
# repository is never deployed.
# Usage: scripts/verify-repos.sh <site-dir>
set -eu
site=$(cd "${1:?usage: verify-repos.sh <site-dir>}" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "VERIFY FAILED: $*" >&2
	exit 1
}

# A keyring that holds only the published key, as a client would have
GNUPGHOME=$tmp/gnupg
export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$site/npad.asc" 2>/dev/null
gpg --batch --quiet --export >"$tmp/keyring.gpg"

# apt: InRelease and Release.gpg both verify, and Release matches what is served
apt=$site/apt/dists/stable
gpgv --keyring "$tmp/keyring.gpg" "$apt/InRelease" 2>/dev/null || fail "InRelease signature"
gpgv --keyring "$tmp/keyring.gpg" "$apt/Release.gpg" "$apt/Release" 2>/dev/null || fail "Release.gpg signature"
sum=$(sha256sum "$apt/main/binary-amd64/Packages" | cut -d' ' -f1)
grep -q "$sum" "$apt/Release" || fail "Release does not list the Packages checksum"
sum=$(sha256sum "$apt/main/binary-amd64/Packages.gz" | cut -d' ' -f1)
grep -q "$sum" "$apt/Release" || fail "Release does not list the Packages.gz checksum"
n=0
for deb in "$site"/apt/pool/main/n/npad/*.deb; do
	sum=$(sha256sum "$deb" | cut -d' ' -f1)
	grep -q "^SHA256: $sum" "$apt/main/binary-amd64/Packages" || fail "Packages does not list $deb"
	n=$((n + 1))
done
[ "$n" -gt 0 ] || fail "no debs in the pool"
echo "apt: InRelease and Release.gpg verify; $n packages listed"

# dnf: repomd.xml.asc verifies and every rpm carries a signature that checks
gpgv --keyring "$tmp/keyring.gpg" "$site/rpm/repodata/repomd.xml.asc" "$site/rpm/repodata/repomd.xml" 2>/dev/null ||
	fail "repomd.xml.asc signature"
mkdir "$tmp/rpmdb"
rpmkeys --dbpath "$tmp/rpmdb" --import "$site/npad.asc"
n=0
for rpm in "$site"/rpm/*.rpm; do
	out=$(rpmkeys --dbpath "$tmp/rpmdb" --checksig "$rpm") || fail "$out"
	case $out in
	*"signatures OK"*) ;;
	*) fail "rpm signature not verified: $out" ;;
	esac
	n=$((n + 1))
done
[ "$n" -gt 0 ] || fail "no rpms"
echo "dnf: repomd.xml.asc verifies; $n rpms signed"
