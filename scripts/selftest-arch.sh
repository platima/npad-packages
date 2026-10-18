#!/bin/sh
# Self-test of the pacman side, in a real Arch, with throwaway keys and fake
# packages: build the signed repository, verify it, serve it, and install from
# it with pacman's signature checking on - then check that a tampered package
# and database are refused. Touches no real signing key and needs no release.
# Usage: run as root in an archlinux container or machine (it installs python
# and gnupg, adds a [npad] repository to /etc/pacman.conf, and installs a fake
# npad), from a checkout of this repository:
#   docker run --rm -v "$PWD:/src:ro" archlinux:latest sh /src/scripts/selftest-arch.sh
# .github/workflows/selftest.yml does exactly that.
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || {
	echo "run as root, in a throwaway Arch" >&2
	exit 1
}

work=$(mktemp -d)
cp -r "$src" "$work/repo"
repo=$work/repo
# Windows checkouts may carry CRLFs
find "$repo" -type f \( -name '*.sh' -o -name '*.env' \) -exec sed -i 's/\r$//' {} +

# Containers lack what pacman's download sandbox wants (landlock, seccomp
# filters); the sandbox is not under test
sed -i -e 's/^#DisableSandbox/DisableSandbox/' -e 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
sandbox=
if pacman --help | grep -q -e --disable-sandbox; then sandbox=--disable-sandbox; fi
pacman -Sy --noconfirm $sandbox --needed python gnupg >/dev/null

# A cached npad of the same name, from another run or the real package, would
# be checked against the wrong database
rm -f /var/cache/pacman/pkg/npad-*

fail() {
	echo "SELFTEST FAILED: $*" >&2
	exit 1
}

# Fake packages: a script called npad that prints a version, for each
# architecture and two versions (the database must list only the newer)
mkpkg() { # <version> <arch>
	d=$work/pkgroot-$1-$2
	mkdir -p "$d/usr/bin"
	printf '#!/bin/sh\necho "npad %s (selftest)"\n' "$1" >"$d/usr/bin/npad"
	chmod 755 "$d/usr/bin/npad"
	cat >"$d/.PKGINFO" <<EOF
pkgname = npad
pkgbase = npad
pkgver = $1-1
pkgdesc = Lightweight Notepad-style text editor
url = https://npad.dev
builddate = $(date +%s)
packager = selftest
size = 64
arch = $2
license = MIT
EOF
	(cd "$d" && bsdtar --zstd -cf "$work/assets/npad-$1-1-$2.pkg.tar.zst" .PKGINFO usr)
}
mkdir -p "$work/assets"
for arch in x86_64 aarch64 riscv64; do mkpkg 0.35.1 "$arch"; done
mkpkg 0.35.0 x86_64

# A throwaway signing key, with a passphrase like the real one
GNUPGHOME=$work/gnupg
export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"
printf 'selftest' >"$work/pass"
gpg --batch --pinentry-mode loopback --passphrase selftest --quick-generate-key \
	"npad selftest <selftest@example.invalid>" rsa3072 sign never >/dev/null 2>&1
GPG_FPR=$(gpg --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')
export GPG_FPR GPG_PASSPHRASE_FILE=$work/pass
gpg --armor --export "$GPG_FPR" >"$work/npad.asc"

# Build and verify (the apt and dnf halves are tested by the real workflow)
mkdir "$work/site"
cp "$work/npad.asc" "$work/site/npad.asc"
sh "$repo/scripts/build-arch-repo.sh" "$work/assets" "$work/site"
sh "$repo/scripts/verify-arch-repo.sh" "$work/site"
[ "$(tar --zstd -tf "$work/site/arch/x86_64/npad.db.tar.zst" | grep -c '/desc$')" = 1 ] ||
	fail "the x86_64 database should list one package (the newest)"
tar --zstd -tf "$work/site/arch/x86_64/npad.db.tar.zst" | grep -q 'npad-0.35.1-1/desc' ||
	fail "the x86_64 database should list npad 0.35.1"

# An older release alone must not hide a newer one: a build without Arch
# packages publishes nothing under /arch, and says so
mkdir "$work/assets-none" "$work/site-none"
cp "$work/npad.asc" "$work/site-none/npad.asc"
out=$(sh "$repo/scripts/build-arch-repo.sh" "$work/assets-none" "$work/site-none")
case $out in *"arch repository: 0 packages"*) ;; *) fail "no Arch assets should give 0 packages, got: $out" ;; esac
[ ! -e "$work/site-none/arch" ] || fail "no Arch assets should publish no arch/ directory"
sh "$repo/scripts/verify-arch-repo.sh" "$work/site-none"

# Serve it and install with the real install.sh, signature checking on
port=$((20000 + $$ % 20000))
(cd "$work/site" && timeout 300 python -m http.server "$port" --bind 127.0.0.1 >"$work/http.log" 2>&1 &)
sleep 2
curl -fsI "http://127.0.0.1:$port/arch/x86_64/npad.db" >/dev/null || fail "the test server is not serving the repository"
sed "s|@BASE_URL@|http://127.0.0.1:$port|g" "$repo/site-src/install.sh" >"$work/install.sh"
sh "$work/install.sh"
[ "$(pacman -Q npad)" = "npad 0.35.1-1" ] || fail "npad 0.35.1-1 should be installed, got: $(pacman -Q npad)"
[ "$(pacman -Si npad | awk -F': *' '$1 ~ /^Repository/ { print $2 }')" = npad ] || fail "npad should come from the [npad] repository"
/usr/bin/npad | grep -q 0.35.1 || fail "the installed npad does not run"
sh "$work/install.sh"
[ "$(grep -c '^\[npad\]' /etc/pacman.conf)" = 1 ] || fail "a second install.sh run must not add [npad] twice"
grep -q '^SigLevel = Required DatabaseRequired' /etc/pacman.conf || fail "the [npad] section should require signatures"

# Tampering is refused
pacman -R --noconfirm npad >/dev/null
rm -f /var/cache/pacman/pkg/npad-*
pkg=$work/site/arch/x86_64/npad-0.35.1-1-x86_64.pkg.tar.zst
cp "$pkg" "$work/pkg.bak"
printf 'x' >>"$pkg"
if pacman -S --noconfirm $sandbox npad >"$work/tamper.log" 2>&1; then
	fail "a tampered package was installed"
fi
cp "$work/pkg.bak" "$pkg"
rm -f /var/cache/pacman/pkg/npad-*
db=$work/site/arch/x86_64/npad.db
cp "$db" "$work/db.bak"
printf 'x' >>"$db"
if pacman -Sy --noconfirm $sandbox >"$work/tamper.log" 2>&1; then
	fail "a tampered database was accepted"
fi
cp "$work/db.bak" "$db"
pacman -Sy --noconfirm $sandbox npad >/dev/null
[ "$(pacman -Q npad)" = "npad 0.35.1-1" ] || fail "npad should install again once the repository is intact"

echo "SELFTEST OK: signed pacman repository builds, verifies, installs and refuses tampering"
