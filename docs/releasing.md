# Releasing

Measured on 2026-09-21, cutting v0.1.0 — the first release, and the first run of every step
below.

## What happens

A push to `main` runs `Release`. `release-please` reads the Conventional Commits since the
last release and, if any of them moves the version, opens or updates a release pull request
carrying `VERSION` and `CHANGELOG.md`. Merging that pull request is the release: the same
workflow tags `v{VERSION}`, creates the GitHub release, builds the app, attaches
`Sake-arm64-{VERSION}.zip`, and sends the version and the zip's sha256 to
`typester/homebrew-sake`, whose own workflow rewrites the cask. Nobody tags by hand.

## Three things that make it work and are not in this repository

- **Actions must be allowed to open pull requests.** Settings → Actions → General →
  "Allow GitHub Actions to create and approve pull requests", or `gh api -X PUT
  repos/typester/sake/actions/permissions/workflow -F can_approve_pull_request_reviews=true`.
  It is off by default, and release-please does all of its work before hitting it: it
  creates the branch, writes the commit, and then fails the run with `GitHub Actions is not
  permitted to create or approve pull requests`, leaving a branch and no pull request.
  Turning it on and re-running the failed job carries on from there. v0.1.0 was cut that
  way, on 2026-09-21.
- **`HOMEBREW_DISPATCH_TOKEN`**, a repository secret with `contents: write` on the tap.
  Without it the cask job skips itself and says so in the log.
- **`CERTIFICATE_P12` and `CERTIFICATE_PASSWORD`**, which are optional. Without them the app
  is ad-hoc signed, which is what v0.1.0 is. That branch has never run with a certificate.

## A first release needs a commit that asks for one

release-please proposes a version only after a `feat:` or a `fix:`. To cut a release without
one — the first, or a re-release — put `Release-As: 0.1.0` in a commit body on `main`. That
is what v0.1.0 was cut with. It is the one footer this repository writes.

## After the tag exists, there is no undo

The tag and the release are public the moment release-please makes them, so a build that
fails afterwards leaves a release with nothing attached. `release.yml` takes a
`workflow_dispatch` with a tag name for that case: it builds against the tag and attaches
the app to the release that is already there. The tap has the same escape hatch, taking a
version and a sha256.

The tap checks that the url resolves before it commits, so a cask is never published
pointing at an asset that is not there.

## The tap is written once and bumped by a bot

`typester/homebrew-sake` holds the cask and the workflow that receives the dispatch. That
dispatch rewrites **two fields and nothing else** — `version` and `sha256`. Everything else
in `Casks/sake.rb` was typed by hand and nothing will ever update it on its own:

- `depends_on arch:` and `depends_on macos:`, which have to be moved by hand to follow
  `Package.swift` and `Info.plist.template`;
- the url, which has to follow the zip name `scripts/build-app.sh` builds;
- `caveats`, which tells the reader the app is ad-hoc signed. The day `CERTIFICATE_P12` is
  set, that text and the tap's README are both wrong, and neither is anywhere near this
  repository.

So anything a reader needs that can change belongs in this repository rather than in the
tap. The tap's own documentation is deliberately thin and points back here.

## Not verified

- **The cask has been installed once, on the owner's Mac**: 0.1.1, on 2026-09-21, without
  `--no-quarantine`, and it has run there since. What Gatekeeper showed on that first launch is
  not recorded, and no second Mac has installed it. Before that, `brew fetch --cask sake`
  downloaded v0.1.0 and the checksum matched.
- `brew audit --cask --online` has not been run: Homebrew refuses to start on the machine
  this was written on, wanting Xcode 27 where it finds 26.4.
- Neither `workflow_dispatch` recovery path has been used.
- One CI run on the release pull request failed at startup with no jobs and no log, and
  passed when re-run unchanged. Unexplained.
