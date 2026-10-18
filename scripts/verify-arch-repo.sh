#!/bin/sh
# Check the pacman part of a built site the way a client would, using only the
# published public key. Fails (non-zero) on the first problem. Called by
# verify-repos.sh; also runnable on its own.
# Usage: scripts/verify-arch-repo.sh <site-dir>
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/config.env"
site=$(cd "${1:?usage: verify-arch-repo.sh <site-dir>}" && pwd)
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

# pacman: optional (a release may predate the Arch packages). Where an
# architecture is published, its database and files list verify, the served
# npad.db are the signed archives themselves, every package has a signature
# that verifies, and the database vouches for each package it lists with the
# checksum of the file that is served. Needs tar with zstd support.
total=0
for arch in $ARCH_ARCHES; do
	dir=$site/arch/$arch
	[ -d "$dir" ] || continue
	for f in db files; do
		gpgv --keyring "$tmp/keyring.gpg" "$dir/npad.$f.tar.zst.sig" "$dir/npad.$f.tar.zst" 2>/dev/null ||
			fail "arch/$arch/npad.$f.tar.zst signature"
		gpgv --keyring "$tmp/keyring.gpg" "$dir/npad.$f.sig" "$dir/npad.$f" 2>/dev/null ||
			fail "arch/$arch/npad.$f signature"
		cmp -s "$dir/npad.$f" "$dir/npad.$f.tar.zst" || fail "arch/$arch/npad.$f is not npad.$f.tar.zst"
	done
	n=0
	for pkg in "$dir"/*.pkg.tar.zst; do
		[ -e "$pkg" ] || continue
		gpgv --keyring "$tmp/keyring.gpg" "$pkg.sig" "$pkg" 2>/dev/null || fail "$(basename "$pkg") signature"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || fail "arch/$arch has a database but no packages"
	# Every package the database lists is served, with the listed checksum
	listed=0
	mkdir "$tmp/db-$arch"
	tar --zstd -xf "$dir/npad.db.tar.zst" -C "$tmp/db-$arch"
	for desc in "$tmp/db-$arch"/*/desc; do
		[ -e "$desc" ] || continue
		file=$(awk '$0 == "%FILENAME%" { getline; print; exit }' "$desc")
		want=$(awk '$0 == "%SHA256SUM%" { getline; print; exit }' "$desc")
		have_arch=$(awk '$0 == "%ARCH%" { getline; print; exit }' "$desc")
		[ -f "$dir/$file" ] || fail "arch/$arch/npad.db lists $file, which is not served"
		[ "$(sha256sum "$dir/$file" | cut -d' ' -f1)" = "$want" ] || fail "arch/$arch/npad.db has the wrong checksum for $file"
		[ "$have_arch" = "$arch" ] || fail "arch/$arch/npad.db lists $file for $have_arch"
		listed=$((listed + 1))
	done
	[ "$listed" -gt 0 ] || fail "arch/$arch/npad.db lists no packages"
	echo "pacman $arch: database and files list verify; $n packages signed, $listed listed"
	total=$((total + n))
done
if [ "$total" -eq 0 ]; then
	echo "pacman: no Arch packages published yet"
	[ ! -d "$site/arch" ] || fail "arch/ exists but holds no packages"
fi
