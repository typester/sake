# How sake works

sake builds Wine from the sources CodeWeavers publish for CrossOver, adds Apple's D3DMetal from
a Game Porting Toolkit you download yourself, and runs Windows games in Wine prefixes it calls
bottles. Everything it builds lives in your home folder; nothing is installed system-wide. This
page is the map, and the files it links to have the detail and the measurements.

## Engine, bottles and titles

- **The engine** is one per Mac, in `~/Library/Sake/engine`: Wine, the libraries it loads,
  Apple's D3DMetal and the runtime GDK titles load, about 1.1 GB. Setup builds it once.
- **A bottle** is one Wine prefix, in `~/Library/Sake/bottles/<name>`: a Windows environment of
  its own, about 1 GB empty, and the place a game is installed. There can be as many as you
  like, and the name you type is the directory's name.
- **A title** is a program in a bottle that the library shows with a Play button: a name, the
  executable, the arguments it starts with and any environment of its own. Titles are kept in
  `sake-titles.json` inside the bottle, so a bottle renamed or thrown away takes its titles
  with it.

Where everything else lives, and why, is [layout.md](layout.md).

## Setup: seven steps

| step | what it does | what it leaves |
|---|---|---|
| This Mac | checks for Apple silicon, Rosetta 2, the Command Line Tools, the Game Porting Toolkit and 10 GB free | nothing |
| Sources | downloads eleven archives, ten of them checked against hashes sake carries | `~/Library/Caches/Sake/dl` |
| Libraries | unpacks the toolchain and builds the nine tools and libraries Wine is configured against | the engine |
| Wine | builds CrossOver's Wine with the nine patches in `patches/` | the engine |
| D3DMetal | mounts the evaluation environment inside the toolkit's image, copies Apple's `redist/lib` out of it, unmounts what it mounted, and installs it | the engine, and a copy in `~/Library/Caches/Sake/d3dmetal` |
| GDK Runtime | fetches libHttpClient and builds `xgameruntime.dll` | `engine/lib/xgameruntime` |
| Bottle | makes the first bottle, `default` | `~/Library/Sake/bottles/default` |

[wine-build.md](wine-build.md) says what each library is for and which configure flags must
stay; [licensing.md](licensing.md) says why D3DMetal is copied from an image you opened rather
than fetched.

**A finished step can come back.** The Wine step counts as done only while the engine was built
from the patches this copy of sake carries, and the GDK Runtime step only while the runtime was
built from the source it carries. An update that changes either leaves that step to do again,
and the library's sidebar says **Setup needs attention**; the wizard opens by itself only until
setup is first finished. A Wine rebuild takes D3DMetal out with it, because `make install` puts
Wine's own DLLs back, so the D3DMetal step is then one press again, from sake's own copy.

## Pressing Play

1. **The GDK runtime goes into the bottle.** Before sake starts a title or an installer, it puts
   its `xgameruntime.dll`, with libHttpClient's licence, in the bottle's `system32`. A copy of
   sake's own that differs from the engine's is replaced; a copy that is not sake's, such as a
   community stand-in, is left alone. Nothing but a GDK title loads it.
2. **The environment is composed.** Five variables are sake's on every run: `WINEPREFIX`,
   `WINEDLLOVERRIDES=mscoree,mshtml=d`, `WINEDEBUG=-all`, `WINE_SIMULATE_WRITECOPY=1` and
   `CX_APPLEGPTK_LIBD3DSHARED_PATH`. A title's own variables go in underneath them, so a title
   cannot take any of the five away.
3. **The program starts from its own folder, by its bare name**, with the title's arguments.
   Wine turns that into `start.exe /exec`, so in `ps` sake's own launch shows as `start.exe`.
4. **sake watches for the title's process**: the one whose `argv[0]`, cut at its first `.exe`,
   ends with the title's executable.
5. **Stop takes the whole bottle down**, not only the game: `wineserver -k`, then whatever is
   still running in that prefix, found through the directory wineserver keeps its socket in.

[runtime.md](runtime.md) has why each of these is the way it is.

A launcher, such as Battle.net or Steam, is a title like any other, and its games are started
from inside it. For Diablo IV that is not only convenient: Battle.net hands out the game's login
token only after its own Play button
([runtime.md](runtime.md#pressing-play-does-two-separable-things)).

## What sake changes in Wine

sake carries nine patches against Wine's own code, in `patches/`. They are LGPL-2.1-or-later,
not MIT ([licensing.md](licensing.md#wine-and-the-patches)), and each file's header says where
it came from and why. A Wine built without them configures, installs and passes every check,
and then cannot start a game, so setup refuses to build one with none.

| patch | without it | from |
|---|---|---|
| 0001 ntdll: find `libd3dshared` without its variable | Diablo IV deadlocks when a launcher composed its environment | sake |
| 0002 ntdll: read `BOOLEAN` syscall arguments as Windows defines them | Diablo IV stalls when Battle.net's Play starts it | sake |
| 0003, 0004 winemac.drv: Metal swapchains across processes | Steam's window stays black | upstream Wine, wine-11.11 |
| 0005 winemac.drv: the same for child windows | Steam's window stays black | the patch attached to Wine bug 60263 |
| 0006 winemac.drv: a hosted swapchain for D3DMetal | Steam's GPU process crashes on every start | sake |
| 0007, 0008 winhttp: accept two options XCurl sets | a GDK title's sign-in never reaches its service | upstream Wine, wine-11.4 and wine-11.7 |
| 0009 ntdll: leave macOS's `._` files out of listings | on exFAT, a game reads them as its own files | sake |

[runtime.md](runtime.md) has what each one fixes and how to tell that it worked, and
[patches/README.md](../patches/README.md) the rules for the directory. The four upstream
commits are carried only until CrossOver's sources contain them: once the tarball sake builds
is based on wine-11.11 or later, they are deleted rather than rebased.

## GDK titles

A game built on Microsoft's GDK expects Xbox Gaming Services, which Wine does not have. sake
provides the two things such a game needs from them: a runtime DLL it builds itself, and an
Xbox sign-in it performs with the game's own app ID. The first time the game wants a token, sake
shows a code and opens `microsoft.com/link`; after that it signs in without asking. The
sign-in is kept in `~/Library/Sake/sign-ins`, in a file only you can read, which any program
you run can read too, Windows programs in bottles included. Minecraft Dungeons II plays this way,
online included. One service refuses sake's token: Xbox's multiplayer activity, which needs a
title token sake cannot get, and what a player loses without it has not been tried.
[gdk.md](gdk.md) has the design, the measurements and what is still open.

## Why CrossOver's Wine, and why you supply D3DMetal

DirectX 12 on a Mac goes through Apple's D3DMetal, and the Wine code it plugs into,
`dlls/winemac.drv/d3dmetal.c`, is in the sources CodeWeavers publish for CrossOver and not in
upstream Wine. It is LGPL, which is why they publish it and why sake can build the same Wine.
D3DMetal itself is not redistributable: sake never ships it, downloads it for you, or takes it
out of an installed CrossOver. It walks you through downloading Apple's toolkit; from the image
you open, it mounts the evaluation environment inside, copies out the part it needs, and
unmounts what it mounted.
[wine-build.md](wine-build.md#why-crossovers-sources-and-not-upstream-wine) has the build side,
and [licensing.md](licensing.md) the line sake stays inside and why D3DMetal cannot simply be
avoided.

## The app

There are two windows, because setting sake up is done once and playing is done every day.

- **The library** lists the bottles, each with its titles, beside a detail pane rather than a
  row per game: a row per game means a Play button per game, and the pane is where a title's
  own settings go. A row is a name and nothing else. A bottle can be selected in its own right,
  not only through its titles, because a bottle just made has nothing in it and a heading alone
  would be a dead end. A bottle's own actions are on the bottle's pane: Install from an
  Installer, Add a Title, Import from CrossOver when there is a CrossOver bottle to take from,
  Rename, Delete and Wine Tools. The sidebar's menu keeps only what is about the library as a
  whole.
- **The setup wizard** is a window of its own, one step per screen with the whole list beside
  it, because it runs for tens of minutes, can fail part way, and sends you to a browser. A
  wizard showing only the current card would leave you not knowing where you were. Importing
  finishes in under a second, so it is a sheet on the library instead.

Choices worth knowing before changing them:

- **Renaming a bottle with a game running is refused; deleting one stops the game.** Nobody
  changing a label asked for their game to stop, whereas throwing a bottle away already means
  stopping what is in it. The guard knows only what sake started itself, so `Bottle` takes the
  prefix down regardless.
- **Deleting and uninstalling go to the Trash**, so both can be undone. A bottle whose game was
  imported from CrossOver returns almost none of its size even once the Trash is emptied, and
  the confirmation says so ([layout.md](layout.md#removing-a-bottle-returns-almost-nothing)).
- **Uninstall is in the app menu**, because it is about the app rather than either window. It
  takes `~/Library/Sake` and `~/Library/Caches/Sake` to the Trash and leaves Sake.app, which is
  running at the time and yours to drag away.
- **A bottle hands over Wine's own tools rather than growing settings of sake's.** The engine
  ships fourteen of Wine's programs, and the bottle offers the four that mean something to a
  bottle with a game in it: winecfg, regedit, the uninstaller and the task manager. The rest are
  either not useful here or better done on the macOS side. What they set lives in the bottle's
  registry, which wineserver writes out lazily ([runtime.md](runtime.md#a-bottle)), so a copy
  in sake would be a second copy that lies. They are offered, not recommended: winecfg's
  Windows-version setting can break a game, and sake reimplementing it would not make it safer,
  only harder to keep true.
- **Import from CrossOver appears only when there is a CrossOver bottle to take from**
  (`CrossOverBottle.available()`): a button whose sheet can say nothing but why it cannot work
  is worse than no button.
- **A row carries no glyph.** Every row under a bottle is a title, so a glyph would tell them
  apart from nothing, and `gamecontroller`, the widest of the symbols tried, its ink filling a
  22×14 pt box, pushed each name 27 pt right of its heading (sake, 2026-09-21). What would earn
  a column back is state the pane can only show one title at a time: running, or not installed.
- **A detail pane scrolls, and keeps its `.fixedSize`.** The modifier,
  `.fixedSize(horizontal: false, vertical: true)` on a `Text`, is there so a long value wraps
  instead of being truncated. In a pane that does not scroll it demands more height than the
  window has; the `NavigationSplitView` is then laid out taller than the window and centred in
  it, so the content leaves the visible area upwards and the window draws empty while the
  accessibility tree still reports every string (sake, 2026-09-21). Scrolling bounds what the
  demand can do. The setup wizard had scrolled from the start.

In the code, `SakeKit` is meant to hold every decision that is not a view, because the tests
reach only it: which setup step is current, and what blocks each one, are there rather than in
the wizard. Some judgements have drifted into the app target's `AppModel` instead
([roadmap.md](roadmap.md#open-questions)). The `sake` target is the SwiftUI app and stays thin.
Which bottles exist, and whether a typed
name can be used, are answered on `Bottle` and tested there rather than in the sheet that asks.
Renaming and deleting a bottle are methods on `Bottle` beside `stop()`, rather than anything a
caller assembles, because each has to take that prefix down first. Swift owns configuration, progress, errors
and state, and subprocesses run what only they can: configure, make and wine. Why the line is
there is in [roadmap.md](roadmap.md#the-swiftsubprocess-boundary).
