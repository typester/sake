# sake

An open source macOS app for running Windows games on Apple silicon — MIT-licensed, with a
GUI, so none of it takes a terminal.

![The library window: a bottle in the sidebar with the titles in it, one selected, with a Play button and the arguments it starts with](assets/library.png)

## What runs

### Verified by me

- **Diablo IV** (Battle.net) — start it from the Battle.net launcher
- **Stardew Valley** (Steam)
- **Minecraft Dungeons II** (Steam, 0.2.0+) — party codes work

That is one person on one Mac, an Apple M5 on macOS 27. The Battle.net and Steam clients
themselves install, sign in and run.

### Verified by the community

Nothing yet — [report it](https://github.com/typester/sake/issues/new?template=compatibility.yml)!
A game that runs is worth hearing about, and so is one that does not.

## What it does

The setup wizard walks seven steps, one screen each. The first checks this Mac — Apple
silicon, Rosetta 2, the Command Line Tools, Apple's Game Porting Toolkit, room on disk — and
the other six build everything else:

1. download the sources and check them against known hashes
2. unpack them and build the tools and libraries Wine is configured against
3. build CrossOver's Wine itself, with the patches in `patches/`
4. guide Apple's D3DMetal in from an image you mounted, and unmount it again
5. build what games made with Microsoft's GDK load in place of Xbox Gaming Services
6. make a bottle — one Wine prefix, which is where a game lives

After that the library is where you live. A game goes into a bottle through its own
installer, the one you downloaded, run inside the bottle. A bottle holds titles you added; a
title is a program in that bottle, its name, the arguments it starts with and any environment
of its own. Picking a program that carries `libcef.dll` fills those arguments in with what a
Chromium client needs, because that is the one thing this stack is known to require and easy
to forget. A title's name and arguments can be changed afterwards, a bottle can be renamed or
thrown away, and the app menu has an Uninstall that takes the engine, the bottles and the
caches away. All of it goes to the Trash, so it can be put back.

## Requirements

- Apple silicon with Rosetta 2
- macOS 15 or newer
- The Xcode Command Line Tools
- Apple's Game Porting Toolkit dmg — a free Apple ID is enough
- ~10 GB for sources and build output, plus whatever the game needs

Nothing is installed into `/usr/local`, `/opt/local` or `/nix`. sake keeps the engine and
the bottles under `~/Library/Sake`, and its build output under `~/Library/Caches/Sake`.

## Getting it

```sh
brew tap typester/sake
brew install --cask typester/sake/sake
```

Apple silicon and macOS 15 or newer; the cask refuses to install anywhere else. The app is
ad-hoc signed and not notarised, so Gatekeeper will stop it on first launch — allow it in
System Settings > Privacy & Security, or install with `--no-quarantine`. Nobody here has
run that first launch on a second Mac.

Or build it yourself:

```sh
git clone https://github.com/typester/sake.git
cd sake
./scripts/build-app.sh --release
```

That leaves `target/Sake.app`, which you can drag to `/Applications`. It is the path this
repository has actually taken.

## Using it

Open the app. The setup wizard comes up until the seven steps are first finished, and stays out
of the way afterwards: when an update leaves a step to do again, the sidebar says so instead.
It runs for tens of minutes, mostly compiling, and sends you to Apple's download page once, for
the toolkit.

When it is done, the library has a bottle in it. Select the bottle and **Install from an
Installer…** runs the game's installer inside it, with Rename and Delete alongside. Once
the game is installed, **Add a Title…** is what puts it in the library: pick its `.exe`
inside the bottle, keep or change the arguments that were filled in, and it appears with a
Play button.

For a launcher like Battle.net, start the launcher and press Play inside it. sake
deliberately does not offer a button that starts Diablo IV directly: the client only hands
out a login token after that press, so a direct start reaches the game and then fails on the
token. [`docs/runtime.md`](docs/runtime.md#pressing-play-does-two-separable-things) has the
measurements behind that.

**[`docs/getting-started.md`](docs/getting-started.md) walks one game through all of this
with screenshots** — Diablo IV, from a Mac with nothing on it to a character on screen.
When something goes wrong, [Troubleshooting](docs/troubleshooting.md) is where to look.

## Why build Wine at all

The piece that makes DirectX 12 work on macOS is Apple's closed D3DMetal, and the Wine-side
glue it plugs into lives in `dlls/winemac.drv/d3dmetal.c`. That glue is LGPL, so CodeWeavers
publish it, and that is what makes "build the same Wine yourself" a real option rather than
wishful thinking. Upstream Wine does not have it.

**D3DMetal itself is not redistributable**, so sake will never ship it, download it for you,
or take it out of an installed CrossOver — it guides you through downloading Apple's Game
Porting Toolkit yourself, mounts the image inside it, copies out the part it needs, and
unmounts it again. See [`docs/licensing.md`](docs/licensing.md).

## What is here

| | |
|---|---|
| `Sources/SakeKit/` | the layout, a subprocess runner, the preflight checks, the source fetcher, the prefix build, the Wine build, the patch step, the D3DMetal step, the GDK runtime's build and placing it, the bottle, the import, the installer, the titles, starting one, the Xbox sign-in for GDK titles, how big a tree is, and the uninstall |
| `Sources/sake/` | the SwiftUI app — two windows, kept thin |
| `patches/` | the changes sake makes to Wine's own code — LGPL-2.1-or-later, not MIT; `patches/README.md` says where each came from |
| `xgameruntime/` | the DLL games built on Microsoft's GDK load in place of Xbox Gaming Services — C++, which setup compiles; its `README.md` says what it answers |
| `docs/` | how the thing actually has to work, what breaks when it doesn't, and how to play one game |
| `assets/` | the app icon, the code that draws it, the screenshot above, and the guide's under `getting-started/` |
| `scripts/build-app.sh` | builds `target/Sake.app` |
| `scripts/make-icon.sh` | redraws `assets/Sake.icns` |
| `scripts/test.sh` | runs the tests |

## Building

Requires the Xcode Command Line Tools. Xcode is not needed, and there is no Xcode project.

```sh
./scripts/build-app.sh            # target/Sake.app
./scripts/build-app.sh --release  # plus a zip
./scripts/test.sh                 # the tests
```

On macOS 27 the Command Line Tools default to the macOS 27.0 SDK, which SwiftUI cannot be
built against without a macro plugin the CLT do not ship. `build-app.sh` detects this and
falls back to a macOS 26 SDK, printing what it did. Override with `SDKROOT` if needed. See
[`CLAUDE.md`](CLAUDE.md) for the full story.

## Documentation

Using sake:

- [Getting started](docs/getting-started.md) — Diablo IV from an empty Mac to a character on screen, with screenshots
- [Troubleshooting](docs/troubleshooting.md) — where the logs are, and what the known problems look like

How it works:

- [How sake works](docs/how-it-works.md) — engine, bottles and titles, the setup steps, what Play does, and what sake changes in Wine
- [Licensing](docs/licensing.md) — what sake may not ship or fetch for you, and why D3DMetal cannot be avoided
- [Where files live](docs/layout.md) — the on-disk layout, and why nothing mutable goes in the app

Working on sake:

- [Building Wine](docs/wine-build.md) — CrossOver's sources, the patches, and the configure flags that must stay
- [Running games](docs/runtime.md) — the settings every run needs, and what each patch fixes
- [GDK titles](docs/gdk.md) — the runtime and the Xbox sign-in sake provides in place of Gaming Services
- [Debugging](docs/debugging.md) — telling failure states apart, and the instruments that found things
- [Roadmap](docs/roadmap.md) — where it stands, what is next, and the questions still open
- [Releasing](docs/releasing.md) — how a release is cut

Most of what `docs/` says about Wine was first measured in the shell prototype sake replaced;
each claim says whose measurement it is and when.

## Licence

MIT, except `patches/`: patches against Wine's own source are derivatives of LGPL code and
are LGPL-2.1-or-later. See [`docs/licensing.md`](docs/licensing.md).
