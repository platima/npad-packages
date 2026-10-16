#!/bin/sh
# Set up the npad package repository (@BASE_URL@) and install npad.
#
#   curl -fsSL @BASE_URL@/install.sh | sudo sh
#   curl -fsSL @BASE_URL@/install.sh | sudo sh -s -- --repo-only
#
# Debian, Ubuntu, Linux Mint and relatives get an apt source; Fedora and
# relatives get a dnf repository. With --repo-only the repository is added and
# nothing is installed. Read it before you run it - it is short.
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
[ "$(uname -m)" = x86_64 ] || die "only x86_64 (amd64) packages are published"
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
esac
if [ -z "$mode" ]; then
	if command -v apt-get >/dev/null 2>&1; then
		mode=apt
	elif command -v dnf >/dev/null 2>&1; then
		mode=dnf
	else
		die "unsupported distribution (need apt or dnf)"
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
esac

echo "npad repository ready ($mode)."
