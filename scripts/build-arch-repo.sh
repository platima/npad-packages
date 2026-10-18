#!/bin/sh
# Build the signed pacman repository into <site-dir>/arch/<arch>/ for every
# architecture in config.env's ARCH_ARCHES that has packages in <assets-dir>.
# Usage: scripts/build-arch-repo.sh <assets-dir> <site-dir>
#   <assets-dir>  npad-<version>-1-<arch>.pkg.tar.zst (see fetch-releases.sh)
# Environment:
#   GPG_FPR              fingerprint of the signing key in the active keyring
#                        (GNUPGHOME selects the keyring)
#   GPG_PASSPHRASE_FILE  optional file holding the key's passphrase
# Prints "arch repository: <n> packages" (0 when nothing was built, which is
# not an error: releases before the Arch packages have none).
# Needs: repo-add (pacman), or docker to run it in the official archlinux
# image - ubuntu runners have no pacman; gpg.
#
# Layout, as pacman expects for `Server = $BASE_URL/arch/$arch`:
#   arch/<arch>/npad.db  npad.db.sig  npad.files  npad.files.sig   the signed
#                        database (copies of the .tar.zst files, since Pages
#                        does not serve symlinks)
#   arch/<arch>/npad-<version>-1-<arch>.pkg.tar.zst and its .sig     every
#                        package kept, each with a detached signature
#
# repo-add --sign would do the signing, but it calls gpg without a loopback
# pinentry, which a passphrase-protected key in CI cannot answer. So repo-add
# runs unsigned and the same detached signatures it would write are made here
# with the build's own gpgsign. The container only ever sees the packages,
# never the key.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/config.env"
assets=${1:?usage: build-arch-repo.sh <assets-dir> <site-dir>}
site=${2:?usage: build-arch-repo.sh <assets-dir> <site-dir>}
: "${GPG_FPR:?GPG_FPR must name the signing key}"
assets=$(cd "$assets" && pwd)
site=$(cd "$site" && pwd)

gpgsign() {
	gpg --batch --yes --pinentry-mode loopback --local-user "$GPG_FPR" \
		${GPG_PASSPHRASE_FILE:+--passphrase-file "$GPG_PASSPHRASE_FILE"} "$@"
}

# repo-add in the current directory
run_repo_add() {
	if command -v repo-add >/dev/null 2>&1; then
		repo-add "$@"
	elif command -v docker >/dev/null 2>&1; then
		docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
			-v "$PWD:/repo" -w /repo archlinux:latest repo-add "$@"
	else
		echo "ERROR: need repo-add (pacman) or docker to build the pacman repository" >&2
		exit 1
	fi
}

total=0
for arch in $ARCH_ARCHES; do
	# Skip an architecture without packages: a pacman repository with an
	# empty database for it would be valid, but would tell pacman there is
	# nothing to install where the truth is "not published yet"
	found=0
	for pkg in "$assets"/npad-*-1-"$arch".pkg.tar.zst; do
		[ -e "$pkg" ] && found=$((found + 1))
	done
	[ "$found" -gt 0 ] || continue

	dir=$site/arch/$arch
	mkdir -p "$dir"
	for pkg in "$assets"/npad-*-1-"$arch".pkg.tar.zst; do
		cp "$pkg" "$dir/"
		gpgsign --detach-sign --output "$dir/$(basename "$pkg").sig" "$pkg"
	done
	(
		cd "$dir"
		# repo-add keeps the newest version of each package in the database
		# and skips older ones, so every release stays downloadable while
		# the database offers only the latest
		run_repo_add npad.db.tar.zst npad-*-1-"$arch".pkg.tar.zst
		for part in db files; do
			# Real files, not repo-add's symlinks, and signed
			rm -f "npad.$part" "npad.$part.tar.zst.old"
			cp "npad.$part.tar.zst" "npad.$part"
			gpgsign --detach-sign --output "npad.$part.tar.zst.sig" "npad.$part.tar.zst"
			cp "npad.$part.tar.zst.sig" "npad.$part.sig"
		done
	)
	echo "arch $arch: $found package(s), database signed"
	total=$((total + found))
done
echo "arch repository: $total packages"
