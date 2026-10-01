# CLAUDE.md

Conventions for this repository. Personal and machine-specific ones live in
`CLAUDE.local.md`, which is not tracked.

## Language

- Generated artifacts must be in English: code, comments, documentation, commit messages,
  UI strings.
- User-facing prose follows the language of the session — this includes **plans**, not just
  chat. If the user writes in Japanese, reply in Japanese; in an English session, stay in
  English.

## Code Style

- Keep comments minimal. Only add comments where the logic is genuinely unclear.
- Never add comments that merely restate what the immediately following code does.
- Comments that survive here earn their place by recording a trap, not by narrating.

## Commit messages

Conventional Commits, because `release-please` reads them to decide the next version:
`feat:` and `fix:` move it, everything else (`docs:`, `ci:`, `refactor:`, `chore:`) does
not. The prose this repository writes goes after the prefix, unchanged —
`fix: keep the wizard shut when there is nothing to set up, because it was opening on`.

The version lives in `VERSION`, and release-please owns it. Do not edit it by hand, and do
not tag by hand: a push to `main` opens or updates a release pull request, and merging that
pull request is what tags, releases and builds.

**Changes arrive on `main` by squash merge, so the pull request title is the commit
message** — it carries the prefix and it is what release-please reads. The body of the
pull request becomes the body of the commit, so what belongs in one belongs in the other,
and the commits on the branch are working notes that do not survive.

**A branch carries the prefix of the pull request it becomes** — `feat/…`, `fix/…`,
`docs/…` — because the branch name is read before a title exists, and it is the only
thing that says what the branch is for until one does.

## Package Naming

The bundle identifier is `dev.typester.sake`. **Not `com.typester.*`** — `typester.com` is
not a domain the user owns; `dev.typester` is.

## Build Environment

**Xcode is not required.** The Command Line Tools are enough — but the SDK has to be pinned.

On macOS 27, the CLT ship both the macOS 27.0 and 26.5 SDKs and default to 27.0. SDK 27.0's
SwiftUI declares `@State` as a macro backed by `SwiftUIMacros`, and the CLT ship no
`libSwiftUIMacros.dylib`, so any view using `@State` fails with:

```
external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
```

Three things measured about this on 2026-09-18 (CLT 27.0, Swift 6.4, macOS 27.0):

- **Pinning to a macOS 26 SDK builds with the CLT alone.** `scripts/build-app.sh` does this
  automatically when the default SDK is 27.x and says so when it does.
- **`-Xswiftc -sdk` does not work.** SwiftPM passes its own `-sdk` and wins. Use `SDKROOT`.
- **Borrowing Xcode 26.4's plugin for SDK 27.0 does not work either** — its expansion wants
  `State._makeStorage_v0`, which SDK 27.0's `State` does not have. SDK 27.0 is currently
  unusable by any route, so the fallback is not a preference, it is the only path.

Delete the fallback once the CLT ship the plugin or an Xcode with the 27 SDK exists.

Not every macro is in that state: **Observation's is one the CLT do expand.** `@Observable`
type-checks against the 26.5 SDK with the Command Line Tools alone (measured 2026-09-19),
so the app uses it. It is only SwiftUI's own macros on SDK 27 that have no plugin.

`swift build` compiles; `./scripts/build-app.sh` assembles `target/Sake.app` and ad-hoc
signs it. There is no Xcode project and none should be added. The version lives in `VERSION`
and is substituted into `Info.plist.template`.

The icon is `assets/Sake.icns`, committed, and `Info.plist` points at it by name — there is
no asset catalog, because that would want the Xcode project this repository does not have.
`assets/icon.swift` draws it and `./scripts/make-icon.sh` regenerates the `.icns`; run that
by hand after changing the drawing, since the build only copies the result. That script does
**not** source `sdk-env.sh`: the SDK pinning above exists for SwiftUI's macros, and a
CoreGraphics renderer needs none of it — measured 2026-09-20, `swift assets/icon.swift` runs
on the default SDK 27.0 with the Command Line Tools alone.

## Tests

`./scripts/test.sh`. It needs two overrides, neither of which is discoverable from the error
messages. Measured 2026-09-19 (CLT 27.0, Swift 6.4, macOS 27.0):

- **The Command Line Tools ship no XCTest.** `import XCTest` fails with `unable to resolve
  module dependency: 'XCTest'`, so the tests are swift-testing.
- **swift-testing's macro plugin sits where SwiftPM does not look.** The CLT do ship
  `libTestingMacros.dylib`, but in `usr/lib/swift/host/plugins/testing/` — one level below
  the `plugins/` directory SwiftPM scans. Without help every `@Test` fails with `plugin for
  module 'TestingMacros' not found`, which is the same shape of error as the SwiftUI one
  above and a different cause. `-Xswiftc -plugin-path -Xswiftc <that directory>` fixes it.

## Package layout

`SakeKit` holds everything that is not a view; the `sake` target is the SwiftUI app and
stays thin. The tests exercise `SakeKit`, so logic that drifts into a view is logic that
stops being tested.

`xgameruntime/` is not Swift and SwiftPM does not build it: it is the Windows DLL that GDK
titles load in place of Gaming Services, C++ compiled with the engine's llvm-mingw by its own
`Makefile`. `scripts/build-app.sh` copies it into the bundle, and setup runs that `Makefile`
from there; its `README.md` has the commands for a build by hand. `scripts/test.sh` runs the
`Makefile` with a stand-in compiler, which pins the variables the app hands it and nothing the
C++ does; a title in a bottle is what tests that, and `docs/gdk.md` records what it measured.

## Deployment target

macOS 15, in both `Package.swift` and `Info.plist.template` — keep them in step. The
reasoning is in `docs/layout.md`; the short version is that `UtilityWindow` is
`@available(macOS 15.0, *)` and nothing is gained by going higher.

Because the build uses the 26.5 SDK and deploys to 15.0, **any macOS 26+ API needs an
`@available` guard**.

## Where the knowledge lives

`docs/` is not background reading; it is the specification. Read the relevant file before
implementing anything it covers.

| file | what it covers |
|---|---|
| `docs/getting-started.md` | Diablo IV from an empty Mac to a keypress; instructions for using sake |
| `docs/troubleshooting.md` | what to do when something goes wrong; instructions, like getting-started |
| `docs/how-it-works.md` | the overview: engine, bottles, titles, the setup steps, what Play does, the patches at a glance |
| `docs/roadmap.md` | where the project stands, what is next, open questions, and the settled Swift/subprocess boundary |
| `docs/wine-build.md` | building Wine; the configure flags that must not be removed |
| `docs/runtime.md` | the settings every run needs, starting and stopping a title, controllers, and what each patch fixes and how to tell |
| `docs/gdk.md` | GDK titles: the runtime DLL and the sign-in sake provides in place of Gaming Services |
| `docs/debugging.md` | telling failure states apart, and the instruments and techniques that found things |
| `docs/licensing.md` | what may not be redistributed, and what the app may not do for the user |
| `docs/layout.md` | on-disk layout, why nothing mutable goes in the bundle, relocatability |
| `docs/releasing.md` | how a release is cut, and the three things it needs that are not in this repository |

Standing rules about that content:

- **`docs/` is written for people first.** An AI reads it too, but it is laid out for somebody
  who opens one file to find one thing. A section's first sentence is the rule, the fact or
  what to do; the measurement behind it comes after. One topic has one home, and other files
  link to it. There is no revision history: a correction replaces the wrong sentence, git keeps
  the old one, and a wrong answer that looks right stays only as a trap worth naming. An
  answered question leaves Open questions, and its answer goes where the topic lives.
- **Claims in `docs/` carry their source and date**, as a tag at the end —
  `(sake, 2026-09-19)`, `(prototype, 2026-09-17)`, `(the owner's report, 2026-09-20)`,
  `(read in CrossOver 26.3.0's sources, 2026-09-29)` — or once, in an italic line under the
  heading, when a whole section was measured in one sitting. Most findings were measured in
  the prototype and not in sake; do not restate those as sake's own, and date what you add.
- **Do not relitigate the Swift/subprocess boundary** without new information;
  `docs/roadmap.md` records why it is where it is.
- **`docs/getting-started.md` and `docs/troubleshooting.md` are instructions, and stay that
  way.** They are written for somebody using sake rather than building it: steps rather than
  prose, and **no dated claims at all** — what has been run here, what has not, and on which
  hardware belongs in the files that already carry it, because a page people follow is where
  that goes stale first. Screenshots go in `assets/getting-started/`.
- **`runtime.md` and `gdk.md` keep their names.** `patches/*.patch` names the first and
  `xgameruntime/src/` the second, and neither can follow a rename: a patch's bytes are the
  engine's fingerprint and `xgameruntime/` but its README is the runtime's stamp, so every
  user's setup would ask for a rebuild. Keep what those comments point at in the file they name.
- **The README's "Verified by me" is the owner's**: a game goes there once the owner has
  played it. A community entry comes from a report and links it.

## Licence boundary

`docs/licensing.md` is binding, not advisory. In particular: sake must never ship Apple's
D3DMetal, download it on the user's behalf, or copy it out of an installed CrossOver. Any
patch against Wine's own source is LGPL-2.1-or-later regardless of this repository's MIT
licence.
