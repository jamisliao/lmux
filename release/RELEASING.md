# Releasing lmux

Checklist for cutting a public release of lmux. Development happens in the
private repo `sooftware/lmux-dev`; the public product lives in a separate
repo, `sooftware/lmux`, which starts from a single clean commit (see
"Publishing the public repo" below) — it has no dev history, scratch files,
or local paths in it.

## 0. Prerequisites (one-time)

- [ ] **Apple Developer Program membership** ($99/yr) — https://developer.apple.com/programs/
      Required for a Developer ID (and for notarization). Without it you can
      only ad-hoc sign, which Gatekeeper blocks for everyone else (see
      "What users see without notarization" below).
- [ ] **Developer ID Application certificate** — in Xcode: Settings ›
      Accounts › your Apple ID › Manage Certificates › + › "Developer ID
      Application". Or via the Apple Developer portal (Certificates, IDs &
      Profiles). Check it's usable locally:
      ```sh
      security find-identity -v -p codesigning
      ```
      You want a line like `"Developer ID Application: Your Name (TEAMID)"`.
      `release/package.sh` reads this identity from `LMUX_SIGN_IDENTITY`.
- [ ] **App Store Connect API key or app-specific password, stored for
      notarytool** — one-time setup:
      ```sh
      xcrun notarytool store-credentials "lmux-notary" \
        --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
      ```
      (or `--key`/`--key-id`/`--issuer` for an App Store Connect API key).
      The profile name (`"lmux-notary"` above) goes in `LMUX_NOTARY_PROFILE`.
- [ ] A `gh` login for the **personal** GitHub account that owns the public
      repo (`sooftware`), separate from any work account:
      ```sh
      gh auth login   # if sooftware isn't already one of `gh auth status`'s accounts
      gh auth status  # confirms it's there
      ```
      Releases and repo creation under `sooftware/lmux` use
      `GH_TOKEN=$(gh auth token --user sooftware)` (see step 4) rather than
      switching the active `gh` account, so this never disturbs a different
      active account (e.g. a work one) in the same shell.

## 1. Publishing the public repo (first release only, or after a reset)

`sooftware/lmux` doesn't exist yet. It is created once from a clean export
of the dev tree — no `.omc/`, no build artifacts, no scratch/design previews,
no local paths — never by pushing `lmux-dev`'s history.

```sh
release/publish.sh --dry-run        # prints the file list + a secret/private-path
                                     # scan; writes nothing
release/publish.sh                  # writes release/out/lmux-public/, only if the
                                     # scan found nothing
```

What ships: `App/`, `Core/`, `assets/` (minus `assets/fonts/*.ttc`, see below),
`.github/` (workflows, actions, issue templates), `docs/` (if present),
`release/`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE*`,
`GHOSTTY_COMMIT`, `scripts/bootstrap.sh` (see "Build from source"),
`scripts/bench.sh` + `scripts/BENCH.md` + `scripts/install-git-hooks.sh`.
Nothing else from the dev tree — notably not `PLAN.md`, `REQUIREMENTS.md`,
`DESIGN.md`, or `design/` (internal planning/UX notes that aren't kept in
sync with what actually shipped, and aren't useful to a public contributor).

What the scan flags, in the text files that would ship (binary files such as
the WOFF fonts and GIFs are skipped, `grep -I`; `release/` itself is not
scanned since it contains the patterns it searches for):

- **`/Users/<name>` paths**, except the made-up test fixture homes listed in
  `PATH_FIXTURES` in `publish.sh` (`/Users/me`, `/Users/x`), matched exactly:
  `/Users/me2` or a second, real path on the same line is still a finding.
- **`/private/tmp/claude-<digits>` scratch paths** — a literal uid/pid right
  after `claude-` (a real leaked agent-session path). Code that builds the
  same prefix at runtime with a non-digit there, e.g.
  `App/scripts/e2etest.sh`'s `"/private/tmp/claude-$(id -u)"` (looking up a
  sandboxed Claude Code session's own transcript dir), is not a finding.
- **Token / key shapes**: `ghp_` and other GitHub tokens, `sk-ant-`, `sk-live-`,
  AWS `AKIA`/`ASIA` key ids, Google `AIza` keys, Slack `xox?-` tokens, PEM
  private key headers.
- **Email addresses**, except RFC 2606 `*.example` domains.

With the current tree the scan finds nothing. The one remaining issue before
the first public release is not a scan finding but a warning (not `release/`'s
job to fix — `release/` only reads the tree):

- There is **no `LICENSE` file** at the repo root, even though the README's
  badge says MIT. Add one (e.g. the standard MIT license text) before
  publishing — `release/publish.sh` will warn about this but won't block on
  it by itself.

### Build from source (what the public repo needs)

`App/Frameworks/GhosttyKit.xcframework` is a symlink into `vendor/ghostty`,
which is not part of the repo. `scripts/bootstrap.sh` makes it:

```sh
scripts/bootstrap.sh --dry-run   # prints the plan, runs nothing
scripts/bootstrap.sh             # clone ghostty-org/ghostty at GHOSTTY_COMMIT into vendor/ghostty,
                                 # Zig 0.17.0 into .tools/zig (sha256 checked),
                                 # zig build -Demit-xcframework=true -Dxcframework-target=native
                                 #   -Demit-macos-app=false -Doptimize=ReleaseFast
App/scripts/bundle.sh            # then build lmux.app as usual
```

To move to another Ghostty commit: update `vendor/ghostty`, then write its
`git -C vendor/ghostty rev-parse HEAD` into `GHOSTTY_COMMIT` (and the Zig
version/sha256 in `bootstrap.sh` if its `build.zig.zon` asks for another one).

The D2Coding `.ttc` (`assets/fonts/`) doesn't ship either: the app bundles
WOFFs made from it (`App/Resources/Fonts`). To remake them without the .ttc,
`App/scripts/make-fonts.py <missing path> App/Resources/Fonts` downloads the
official naver/d2codingfont VER1.3.3 zip (URL and sha256 pinned in the
script, the .ttc inside checked too) and gives byte-identical WOFFs.

Once the scan is clean (or you've confirmed every finding is an intentional
fixture and passed `--force`), `release/publish-to-public.sh` takes over —
`publish.sh` itself never runs git, never pushes, and never touches
`sooftware/lmux`.

```sh
release/publish-to-public.sh --dry-run                     # prints the snapshot, the scan,
                                                             # and the exact commands; pushes nothing
release/publish-to-public.sh --replace-initial --yes       # force-pushes ONE commit, "Initial
                                                             # commit" (author sooftware), replacing
                                                             # sooftware/lmux's existing history
```

Both flags are required together for the real push; without them (or with
`--dry-run`) it only prints what it would do. `--force` (forwarded to
`publish.sh`) overrides the scan the same way it does there.

### Updating the public repo after the first release

Every release after the first is a normal sync, not a history rewrite:

```sh
release/publish-to-public.sh --update --dry-run   # clones sooftware/lmux, shows the diff a
                                                   # sync would push; pushes nothing
release/publish-to-public.sh --update             # clones sooftware/lmux's main, replaces its
                                                   # tracked content with a fresh snapshot, commits
                                                   # "Sync from dev <short dev sha>", pushes normally
```

### Public repo hygiene (labels, security settings)

One-time, and safe to re-run any time (idempotent, never touches visibility):

```sh
GH_TOKEN=$(gh auth token --user sooftware) release/setup-public-repo.sh --dry-run
GH_TOKEN=$(gh auth token --user sooftware) release/setup-public-repo.sh
```

Sets up labels, private vulnerability reporting, Dependabot alerts +
automated security updates, secret scanning + push protection, and a branch
ruleset on `main` requiring the `core` and `app` CI checks plus a pull
request. Some of these (private vulnerability reporting; secret scanning +
push protection; the branch ruleset) only take effect once `sooftware/lmux`
is public — the script detects that, skips them with a note instead of
failing, and prints the re-run command for after launch.

### The `release` environment (CI signing secrets)

`.github/workflows/release.yml` runs its job in a GitHub Environment named
`release`, so the signing/notarization/tap secrets are environment secrets
that only that job can read. Configure it once on the public repo
(Settings › Environments › New environment › `release`):

- **Required reviewers**: yourself (`sooftware`). Every release run then
  waits for an explicit approval before any secret is exposed.
- **Deployment branches and tags**: "Selected branches and tags", with only
  the tag rule `v*` (plus `main`, for the `workflow_dispatch` draft runs).
  Pair it with a tag ruleset that restricts creating `v*` tags to admins.
- **Environment secrets** (move them out of repository secrets):
  `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`,
  `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`, `TAP_GITHUB_TOKEN`.

The release job also builds GhosttyKit from source (`use-cache: 'false'` on
`setup-lmux`) instead of restoring the cache other workflows write, and
every third-party action is pinned to a full commit SHA (Dependabot,
`.github/dependabot.yml`, proposes the bumps).

## 2. Cutting a release

From `sooftware/lmux` (or any checkout that already has a built app):

```sh
# 1. Build (NOT release/package.sh's job — build it yourself first):
App/scripts/bundle.sh
# App/scripts/bundle.sh ad-hoc signs App/build/lmux.app as a side effect;
# release/package.sh works from a COPY and re-signs properly, so that's fine.

# 2. Package: stamp the version, sign, (optionally) notarize, zip + dmg + sha256.
export LMUX_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export LMUX_NOTARY_PROFILE="lmux-notary"
release/package.sh --version 0.2.0

# 3. Verify the artifacts.
release/check.sh release/out/lmux-0.2.0-arm64.zip
release/check.sh release/out/lmux-0.2.0-arm64.dmg
```

Without `LMUX_SIGN_IDENTITY`/`LMUX_NOTARY_PROFILE` set, `package.sh` still
produces a zip/dmg (ad-hoc signed) with a loud warning — useful for local
testing, not for a public release (see below).

## 3. GitHub release

The repo is **private during development**; it becomes `sooftware/lmux`
(public) at publish time (step 1). Releases are always created on the
public repo, through the personal `sooftware` account:

```sh
GH_TOKEN=$(gh auth token --user sooftware) \
  gh release create v0.2.0 \
    release/out/lmux-0.2.0-arm64.zip \
    release/out/lmux-0.2.0-arm64.dmg \
    release/out/lmux-0.2.0-arm64.sha256.txt \
    release/out/lmux-arm64.dmg \
    --repo sooftware/lmux \
    --title "v0.2.0" \
    --notes "…"
```

`lmux-arm64.dmg` is the same dmg without the version in its name. The
README's download button links to `releases/latest/download/lmux-arm64.dmg`,
so every release needs it; leave it out and that link 404s. `latest` skips
drafts and prereleases, so the button only works once a notarized release
is out.

Using `GH_TOKEN=$(gh auth token --user sooftware)` (rather than `gh auth
switch`) scopes the release-create call to that account's token without
changing which `gh` account is active for the rest of the shell/session.

What users of the previous version need to know goes in `release/notes.md`:
the release workflow appends it to the notes (pass it with `--notes-file` by
hand). Empty it after the release.

## 4. Homebrew cask

```sh
release/update-cask.sh 0.2.0     # fills release/lmux.rb's version + sha256
                                  #   from release/out/lmux-0.2.0-arm64.sha256.txt
```

**Where the cask lives — two options:**

- **Your own tap, `sooftware/homebrew-tap`** (do this first; no notability
  bar). One-time: create that repo, add `Casks/lmux.rb` (copy of
  `release/lmux.rb`). Each release: re-run `update-cask.sh`, copy the
  updated `release/lmux.rb` into the tap repo as `Casks/lmux.rb`, commit,
  push. Users install with:
  ```sh
  brew install --cask sooftware/homebrew-tap/lmux
  ```
- **Submitting to `homebrew/cask`** (the main repo, `brew install --cask
  lmux` with no tap prefix) — later, once lmux has real-world traction.
  homebrew/cask requires the project to be "notable" (roughly: real GitHub
  stars/forks/usage, not just "it exists") before it'll be accepted; see
  https://docs.brew.sh/Acceptable-Casks. Don't bother submitting until
  `sooftware/lmux` has some.

## 5. What users see without notarization

Being honest about this, because it's the default state if you skip the
Apple Developer Program step:

- **Ad-hoc signed (no `LMUX_SIGN_IDENTITY`)**: Gatekeeper refuses to open the
  app at all — `"lmux.app" is damaged and can't be opened. You should move
  it to the Trash.` (this is Gatekeeper's generic message for "no usable
  signature it can check," not an actual integrity problem).
- **Developer ID signed but not notarized** (`LMUX_SIGN_IDENTITY` set,
  `LMUX_NOTARY_PROFILE` not): a less scary but still blocking dialog —
  `"lmux" cannot be opened because the developer cannot be verified.`

**The workaround, for either case**, which is what a cask install or a
direct download both need until the app is notarized:

- Right-click (or Control-click) `lmux.app` in Finder → Open → Open anyway in
  the dialog. After doing this once, macOS remembers and future launches are
  normal. (Finder's own double-click won't offer this; the right-click menu
  has to be used, or System Settings › Privacy & Security has an "Open
  Anyway" button that appears after a blocked launch attempt.)
- Or strip the quarantine flag from the command line:
  ```sh
  xattr -dr com.apple.quarantine /Applications/lmux.app
  ```
  (`-r` because Homebrew/manual installs can quarantine nested files too.)

Neither of these is something you can ask a Homebrew cask to do
automatically — `brew install --cask` does not bypass Gatekeeper, and
scripting a Gatekeeper bypass into the cask itself would be inappropriate.
The only real fix is notarization (step 2, with both env vars set), at which
point `lmux.app` opens exactly like any App Store app.
