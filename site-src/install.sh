#!/bin/sh
# Set up the npad package repository (@BASE_URL@) and install npad.
#
#   curl -fsSL @BASE_URL@/install.sh | sudo sh
#   curl -fsSL @BASE_URL@/install.sh | sudo sh -s -- --repo-only
#
# Debian, Ubuntu, Linux Mint and relatives get an apt source; Fedora and
# relatives get a dnf repository; Arch Linux (also Arch Linux ARM and Arch
# RISC-V) and relatives get a [npad] section in /etc/pacman.conf and the
# signing key in pacman's keyring. With --repo-only the repository is added
# and nothing is installed. Read it before you run it - it is short.
set -eu

BASE_URL=@BASE_URL@
install_pkg=1
for arg in "$@"; do
	case $arg in
	--repo-only) install_pkg=0 ;;
	-h | --help)
		echo "usage: install.sh [--repo-only]"
		exit 0
		;;
	*)
		echo "unknown option: $arg" >&2
		exit 2
		;;
	esac
done

die() {
	echo "install.sh: $*" >&2
	exit 1
}

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		die "run as root, or install sudo"
	fi
}

[ "$(uname -s)" = Linux ] || die "this repository is for Linux"
case $(uname -m) in
x86_64 | aarch64 | riscv64) ;;
*) die "packages are published for x86_64, aarch64 (arm64) and riscv64, not $(uname -m)" ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is required"

ids=" "
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	ids=" ${ID:-} ${ID_LIKE:-} "
fi

mode=
case $ids in
*" debian "* | *" ubuntu "*) mode=apt ;;
*" fedora "* | *" rhel "* | *" centos "*) mode=dnf ;;
*" arch "* | *" archarm "*) mode=pacman ;;
esac
if [ -z "$mode" ]; then
	if command -v apt-get >/dev/null 2>&1; then
		mode=apt
	elif command -v dnf >/dev/null 2>&1; then
		mode=dnf
	elif command -v pacman >/dev/null 2>&1; then
		mode=pacman
	else
		die "unsupported distribution (need apt, dnf or pacman)"
	fi
fi

case $mode in
apt)
	as_root install -d -m 0755 /etc/apt/keyrings
	curl -fsSL "$BASE_URL/npad.asc" | as_root tee /etc/apt/keyrings/npad.asc >/dev/null
	curl -fsSL "$BASE_URL/npad.sources" | as_root tee /etc/apt/sources.list.d/npad.sources >/dev/null
	as_root apt-get update
	[ "$install_pkg" -eq 0 ] || as_root apt-get install -y npad
	;;
dnf)
	curl -fsSL "$BASE_URL/npad.repo" | as_root tee /etc/yum.repos.d/npad.repo >/dev/null
	[ "$install_pkg" -eq 0 ] || as_root dnf install -y npad
	;;
pacman)
	# The repository appears with the first npad release that has Arch
	# packages; say so rather than leaving pacman to fail on a 404
	curl -fsI "$BASE_URL/arch/$(uname -m)/npad.db" >/dev/null 2>&1 ||
		die "no Arch repository for $(uname -m) at $BASE_URL yet - install the .pkg.tar.zst from the GitHub release with pacman -U"
	# pacman trusts a key only once it is in its keyring and locally signed
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	key=$tmp/npad.asc
	curl -fsSL "$BASE_URL/npad.asc" -o "$key"
	# A scratch keyring: reading the key must not create ~/.gnupg
	mkdir -m 700 "$tmp/gnupg"
	fpr=$(GNUPGHOME=$tmp/gnupg gpg --batch --show-keys --with-colons "$key" | awk -F: '$1 == "fpr" { print $10; exit }')
	[ -n "$fpr" ] || die "could not read the fingerprint of the signing key"
	# A fresh install, or a container image, may have no keyring master key
	# to sign trust with yet
	if [ -z "$(as_root gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null)" ]; then
		as_root pacman-key --init
		as_root pacman-key --populate
	fi
	as_root pacman-key --add "$key"
	as_root pacman-key --lsign-key "$fpr"
	# Once only: a second run leaves pacman.conf as it is
	if ! grep -q '^\[npad\]' /etc/pacman.conf; then
		printf '\n[npad]\nSigLevel = Required DatabaseRequired\nServer = %s/arch/$arch\n' "$BASE_URL" |
			as_root tee -a /etc/pacman.conf >/dev/null
	fi
	if [ "$install_pkg" -eq 1 ]; then
		# `pacman -Sy <package>` alone can leave a system half-upgraded, which
		# Arch does not support. npad needs only GTK 3, so when that is
		# already installed refreshing the databases is enough; otherwise
		# bring the whole system up to date, as Arch expects
		if pacman -Qq gtk3 >/dev/null 2>&1; then
			as_root pacman -Sy --noconfirm npad
		else
			as_root pacman -Syu --noconfirm npad
		fi
	fi
	;;
esac

echo "npad repository ready ($mode)."
