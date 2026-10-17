#!/bin/sh
# Build the signed apt and dnf repositories plus the landing page into <site-dir>.
# Usage: scripts/build-repos.sh <assets-dir> <site-dir>
#   <assets-dir>  npad_*_<arch>.deb and npad-*.<arch>.rpm for the architectures in
#                 config.env (see fetch-releases.sh)
# Environment:
#   GPG_FPR              fingerprint of the signing key in the active keyring
#                        (GNUPGHOME selects the keyring)
#   GPG_PASSPHRASE_FILE  optional file holding the key's passphrase
# Needs: apt-ftparchive (apt-utils), createrepo_c, rpmsign (rpm), gpg, gzip.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/config.env"
assets=${1:?usage: build-repos.sh <assets-dir> <site-dir>}
site=${2:?usage: build-repos.sh <assets-dir> <site-dir>}
: "${GPG_FPR:?GPG_FPR must name the signing key}"

# Absolute paths: the apt part below changes directory
assets=$(cd "$assets" && pwd)
mkdir -p "$site"
site=$(cd "$site" && pwd)

gpgsign() {
	gpg --batch --yes --pinentry-mode loopback --local-user "$GPG_FPR" \
		${GPG_PASSPHRASE_FILE:+--passphrase-file "$GPG_PASSPHRASE_FILE"} "$@"
}

rm -rf "${site:?}"/*
mkdir -p "$site/apt" "$site/rpm"

# --- site files: the templates in site-src/ with the public values filled in
host=${BASE_URL#*://}
host=${host%%/*}
fpr_spaced=$(printf '%s' "$GPG_FPR" | sed 's/\(....\)/\1 /g; s/ $//')
for f in index.html install.sh npad.sources npad.repo; do
	sed -e "s|@BASE_URL@|$BASE_URL|g; s|@HOST@|$host|g; s|@FINGERPRINT@|$fpr_spaced|g" \
		-e "s|@DEB_ARCHES@|$DEB_ARCHES|g; s|@RPM_ARCHES@|$RPM_ARCHES|g" \
		"$here/site-src/$f" >"$site/$f"
done
chmod 644 "$site"/index.html "$site"/install.sh "$site"/npad.sources "$site"/npad.repo
# Informational under Pages' GitHub Actions source (the domain is set in the
# repository settings), but it keeps the domain beside BASE_URL.
printf '%s\n' "$host" >"$site/CNAME"
gpg --armor --export "$GPG_FPR" >"$site/npad.asc"
[ -s "$site/npad.asc" ] || {
	echo "ERROR: could not export the public key $GPG_FPR" >&2
	exit 1
}

# --- apt: suite stable, component main, one binary-<arch> index per DEB_ARCHES
# entry over a single shared pool
pool=$site/apt/pool/main/n/npad
mkdir -p "$pool"
for arch in $DEB_ARCHES; do
	for deb in "$assets"/npad_*_"$arch".deb; do
		if [ -e "$deb" ]; then cp "$deb" "$pool/"; fi
	done
done
(
	cd "$site/apt"
	for arch in $DEB_ARCHES; do
		mkdir -p "dists/stable/main/binary-$arch"
		# --arch keeps each index to its own architecture's packages; an
		# architecture with none gets an empty (still valid, still signed) one
		apt-ftparchive --arch "$arch" packages pool >"dists/stable/main/binary-$arch/Packages"
		gzip -9 -n -k "dists/stable/main/binary-$arch/Packages"
		echo "apt binary-$arch: $(grep -c '^Package:' "dists/stable/main/binary-$arch/Packages" || true) packages"
	done
	apt-ftparchive \
		-o APT::FTPArchive::Release::Origin=npad \
		-o APT::FTPArchive::Release::Label=npad \
		-o APT::FTPArchive::Release::Suite=stable \
		-o APT::FTPArchive::Release::Codename=stable \
		-o "APT::FTPArchive::Release::Architectures=$DEB_ARCHES" \
		-o APT::FTPArchive::Release::Components=main \
		-o "APT::FTPArchive::Release::Description=npad text editor packages" \
		release dists/stable >"$site/.Release.tmp"
	mv "$site/.Release.tmp" dists/stable/Release
	gpgsign --clearsign --output dists/stable/InRelease dists/stable/Release
	gpgsign --armor --detach-sign --output dists/stable/Release.gpg dists/stable/Release
)

# --- dnf: every RPM_ARCHES rpm in one tree (dnf installs only those its machine
# runs); sign each rpm, then the repository metadata
for arch in $RPM_ARCHES; do
	for rpm in "$assets"/npad-*."$arch".rpm; do
		if [ -e "$rpm" ]; then cp "$rpm" "$site/rpm/"; fi
	done
done
extra="--batch --pinentry-mode loopback"
[ -z "${GPG_PASSPHRASE_FILE:-}" ] || extra="$extra --passphrase-file $GPG_PASSPHRASE_FILE"
# rpm's default gpg is /usr/bin/gpg2, which Debian and Ubuntu do not ship
rpmsign \
	--define "__gpg $(command -v gpg)" \
	--define "_gpg_name $GPG_FPR" \
	--define "_gpg_digest_algo sha256" \
	--define "_gpg_sign_cmd_extra_args $extra" \
	--addsign "$site"/rpm/*.rpm
createrepo_c --quiet --no-database --general-compress-type gz "$site/rpm"
gpgsign --armor --detach-sign --output "$site/rpm/repodata/repomd.xml.asc" "$site/rpm/repodata/repomd.xml"

echo "Built repositories in $site"
