# npad-packages

Signed **apt** and **dnf** repositories for [npad](https://github.com/platima/npad),
served from <https://pkg.npad.dev> by GitHub Pages.

This repository holds only the machinery and the signing secrets. The packages
themselves are never committed: the workflow downloads the `.deb` / `.rpm`
assets of the newest stable npad releases, builds and signs the repositories,
and deploys the result with `actions/deploy-pages`. GitHub Releases on
`platima/npad` remain the source of truth, and the signing key exists only in
this repository's secrets, so the code repository (and anyone with access to
it) cannot sign anything.

```
config.env                 BASE_URL, SOURCE_REPO, KEEP_RELEASES - the one place to change them
scripts/fetch-releases.sh  download + sha256-verify the release packages
scripts/build-repos.sh     build apt (apt-ftparchive) and dnf (createrepo_c, rpmsign), sign, fill the site
scripts/verify-repos.sh    re-check the result with the public key only, as a client would
site-src/                  index.html, install.sh, npad.sources, npad.repo (templates; @BASE_URL@ is filled in)
.github/workflows/publish.yml
```

What gets published at `$BASE_URL`:

| Path | Content |
| --- | --- |
| `/npad.asc` | public signing key (armored) |
| `/npad.sources`, `/npad.repo` | ready-made apt (deb822) and dnf configuration |
| `/install.sh` | detects apt or dnf, adds the repository, installs npad |
| `/apt/` | suite `stable`, component `main`, `binary-amd64`, `binary-arm64`, `binary-riscv64`: `dists/stable/{InRelease,Release,Release.gpg}`, one shared `pool/` |
| `/rpm/` | signed rpms for `x86_64`, `aarch64` and `riscv64` plus `repodata/` with `repomd.xml.asc` |

When it runs: when npad's release workflow sends a `repository_dispatch`
(`npad-release`), daily at 03:17 UTC as a backstop, on demand
(Actions > Publish repositories > Run workflow), and on pushes to `main` that
touch the scripts, site or config. Pre-releases and drafts are skipped.

## One-time setup (maintainer)

Do these once, in this order. Nothing here is done by the workflows.

### 1. Generate the signing key

On a machine you trust. The key is RSA 4096 (understood by every apt and rpm
in use), sign-only, and **does not expire**: clients keep a copy of the public
key, so an expiry date would silently break updates for everyone who had not
refreshed it. Protect it with a passphrase, and keep a revocation certificate
instead.

```bash
gpg --quick-generate-key "npad package signing <13729856+platima@users.noreply.github.com>" rsa4096 sign never
gpg --list-secret-keys --keyid-format long          # note the 40-hex fingerprint
FPR=<the fingerprint>

gpg --armor --export-secret-keys "$FPR" > npad-signing-private.asc   # -> GitHub secret, then delete
gpg --armor --export "$FPR" > npad.asc                                # public; the workflow re-exports it
gpg --gen-revoke --output npad-revoke.asc "$FPR"                      # keep offline, for emergencies
```

Put `npad-signing-private.asc`, the passphrase and `npad-revoke.asc` in your
password manager, then securely delete the plain files
(`shred -u npad-signing-private.asc` on Linux).

### 2. Create the `repo-signing` environment and add the secrets

Settings > Environments > New environment, named exactly `repo-signing`.

- **Deployment branches and tags**: *Selected branches and tags* > add `main`.
  This is the protection: no other branch or pull request can read the key.
- Leave *Required reviewers* off. With it on, every daily run would wait for
  an approval.

Add two **environment secrets** (not repository secrets):

| Secret | Value |
| --- | --- |
| `GPG_PRIVATE_KEY` | contents of `npad-signing-private.asc` |
| `GPG_PASSPHRASE` | the key's passphrase (omit if you made an unprotected key) |

Or from a shell with `gh`:

```bash
gh secret set GPG_PRIVATE_KEY --env repo-signing --repo platima/npad-packages < npad-signing-private.asc
gh secret set GPG_PASSPHRASE  --env repo-signing --repo platima/npad-packages
```

### 3. Turn on Pages and add the domain

1. Settings > Pages > **Build and deployment > Source: GitHub Actions**.
2. DNS for `npad.dev`: a `CNAME` record, host `pkg`, pointing to
   `platima.github.io`. (The website at the apex is a different repository's
   Pages site and is unaffected.)
3. Settings > Pages > **Custom domain**: `pkg.npad.dev`, Save. When the
   certificate is issued, tick **Enforce HTTPS**.
4. Recommended: verify the domain for your account (Account settings > Pages >
   Add a domain; add the `_github-pages-challenge-platima` TXT record), which
   stops anyone else claiming the subdomain if the CNAME is ever dangling.

### 4. Let npad's release workflow wake this repository

In `platima/npad`, the release workflow's last job (`notify-packages`) posts a
`repository_dispatch` here once a release's assets are attached and validated.
It needs a secret named **`NPAD_PACKAGES_TOKEN`** in `platima/npad`
(Settings > Secrets and variables > Actions > New repository secret):

- Create a **fine-grained personal access token**: *Resource owner* `platima`,
  *Repository access* > **Only select repositories** > `platima/npad-packages`.
- Repository permissions: **Contents: Read and write** (the dispatches API
  requires it) and Metadata: Read-only (added automatically). Nothing else.
- Set an expiry, and put the renewal date in your calendar. An expired token
  does not break releases: the job prints a warning and the daily run picks the
  release up within 24 hours.

### 5. First publish

The workflow refuses to deploy until the newest releases include both a `.deb`
and an `.rpm` (so the first publishable release is npad v0.36.0, the first
with the rpm). Once that release exists, run Actions > *Publish repositories* >
*Run workflow*. Check the deployment, then try it from a clean machine:

```bash
# Debian / Ubuntu / Mint
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://pkg.npad.dev/npad.asc -o /etc/apt/keyrings/npad.asc
sudo curl -fsSL https://pkg.npad.dev/npad.sources -o /etc/apt/sources.list.d/npad.sources
sudo apt update && apt policy npad

# Fedora
sudo curl -fsSL https://pkg.npad.dev/npad.repo -o /etc/yum.repos.d/npad.repo
sudo dnf install npad
```

## Day-to-day

- **Nothing to do for a normal release.** Tag in npad; its workflow attaches
  the packages and dispatches here. Remember not to tag in quick succession
  (see npad's `LESSONS.md`).
- **Retention.** The newest `KEEP_RELEASES` (5) stable releases stay in the
  repositories; older ones drop out of the pool on the next build but remain
  on GitHub Releases.
- **Changing the address.** Edit `BASE_URL` in `config.env` (the `CNAME` file
  and every page, source and repo file follow), then update the custom domain
  and DNS. Clients using the old address need the new `npad.sources` /
  `npad.repo`.
- **Moving hosting** (Cloudflare Pages, a bucket, a VPS): the site is plain
  static files built into `site/`; replace the two Pages steps in
  `publish.yml` with an upload and keep the rest.
- **Key compromise or rotation.** Publish the revocation certificate, generate
  a new key, replace the two secrets, and tell users to re-run the install
  steps (they need the new `npad.asc`). That is the cost of a non-expiring key.

## Things to know

- **Architectures**: amd64, arm64 and riscv64 (rpm: x86_64, aarch64,
  riscv64), from npad v0.35.0 on; older releases are amd64 only, so the arm64
  and riscv64 indexes start empty and fill as releases carry them. The list
  lives in `config.env` (`DEB_ARCHES`, `RPM_ARCHES`), which drives the fetch
  patterns, the apt indexes, the Release and `npad.sources` `Architectures`
  fields and the checks in `verify-repos.sh`. Adding one means building it in
  npad's release workflow and adding it there.
- **`npad.sources` must list every architecture, or none.** apt skips a
  deb822 source whose `Architectures` field does not include the machine's
  own, with only a notice, so the original `Architectures: amd64` made the
  repository invisible on arm64. Anyone who fetched that file on an Arm
  machine has to fetch it again (`install.sh` does).
- GitHub Pages caches for about ten minutes, so `apt update` can briefly report
  a size or hash mismatch right after a publish. Retrying a few minutes later
  fixes it.
- GitHub disables scheduled workflows after 60 days without repository
  activity. The `keepalive` job re-enables the workflow on every scheduled run
  to reset that clock, and release dispatches work regardless; if the daily run
  ever stops appearing in the Actions tab, re-enable it there.
- Package files in the release are unsigned. Trust comes from the repository
  signatures (`InRelease`, `repomd.xml.asc`) and, for dnf, the signature
  `rpmsign` adds to each rpm in the repository copy.
- The packages contain no repository configuration; users opt in with the
  steps above or `install.sh`.

## Testing the scripts locally

Everything runs with a throwaway key; no secrets involved. Needs `apt-utils`
(`apt-ftparchive`), `createrepo-c`, `rpm`, `gnupg`.

```bash
export GNUPGHOME=$(mktemp -d)
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key "test <t@example.invalid>" rsa4096 sign never
export GPG_FPR=$(gpg --list-secret-keys --with-colons | awk -F: '$1=="fpr"{print $10;exit}')
mkdir -p work/assets && cp /path/to/npad_*.deb /path/to/npad-*.rpm work/assets/
sh scripts/build-repos.sh work/assets site
sh scripts/verify-repos.sh site
```

To exercise apt against the result without touching the system, point an
`APT_CONFIG` at private `Dir::State`, `Dir::Cache` and `Dir::Etc::sourceparts`
directories whose `npad.sources` uses `URIs: file:///.../site/apt` and a
`Signed-By` path to your test `npad.asc`.
