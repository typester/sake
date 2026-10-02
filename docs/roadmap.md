# Roadmap

## The goal

Someone who has never opened a terminal can install sake, follow the app, and end up playing
a Windows game on their Mac. Every setting is in the GUI. Every long operation shows
progress. Every failure says what went wrong and what to do about it.

That is the bar. A tool that works only for people who can read a build script already
exists — see "Where this came from".

## Where this came from

The `d4-mac` prototype (a set of shell scripts, not in this repository) got Diablo IV
playable on 2026-09-17 by building CrossOver's Wine from CodeWeavers' published LGPL sources.
It proved the approach. It is unusable by anyone who will not read shell.

None of its code is here, deliberately. What came across is the reasoning, in `docs/`. Most
of the low-level findings there are still the prototype's, and each says whose it is.

## Where it stands

- **Phase 1 — the skeleton (done).** An app that builds and launches, the repository's
  conventions, and the prototype's knowledge written down.
- **Phase 2 — the build pipeline in Swift (done).** The preflight checks, the eleven sources,
  ten of them against pinned hashes, the libraries, Wine with its patches, and D3DMetal from an image the
  user mounted, driven from Swift with progress the UI can render. It first ran end to end on
  2026-09-19 and left a 1.1 GB engine.
- **Phase 3 — bottles and titles (under way).** Bottles are created, renamed and thrown away;
  a game comes in through its own installer or is cloned out of a CrossOver bottle; anything in
  a bottle can be added as a title, with its own arguments and environment. sake ships no titles
  of its own: a bottle shows what somebody added to it. Diablo IV through Battle.net was played
  on a Mac with no CrossOver on it on 2026-09-20, and Steam and Stardew Valley the same day
  (the owner's report); Minecraft Dungeons II on 2026-09-30.
- **Phase 4 — the GUI proper (under way).** The library and the setup wizard, Uninstall, and
  Wine's own tools on a bottle are in; [how-it-works.md](how-it-works.md#the-app) has why they
  look the way they do. What is left is below.
- **Phase 5 — GDK titles (under way).** A runtime and an Xbox sign-in of sake's own, built and
  placed by setup, so that a title built on Microsoft's GDK runs without Gaming Services or a
  community stand-in. The four steps it was planned in are done, and Minecraft Dungeons II plays
  on them; what needs a title token is out of reach ([gdk.md](gdk.md)).

## Next

- **Taking the build cache away on its own**, which is what somebody who wants their 4 GB back
  but not to lose their games is asking for.
- **Uninstall taking the three small files it leaves**: the preferences plist and two URLSession
  stores ([layout.md](layout.md#the-layout)).
- **A second Mac.** sake has run on one.

## Known rough edges

Found and not fixed; each was still in the code on 2026-09-30.

- **Two buttons say "Check Again" on the This Mac step.** The bottom bar adds one when the step
  is the machine step, and `primary` adds another because that step is not done, so both render
  the same verb. The comment above the first says it is there for the step "worth repeating
  after it has passed", which is the condition the code does not check (found 2026-09-21).
- **Editing a title moves it to the end of the sidebar.** `TitleStore.add()` filters the id out
  and appends, so saving Options reorders the library. Harmless and confusing, and it cost a
  measurement on 2026-09-21: a row addressed by index was no longer the row it was.
- **The delete confirmation names the game twice** when one is running.
- **A bottle just created does not offer what could be imported into it** until something else
  surveys: `create` sets `importTarget` after the survey that would have used it.

## The Swift/subprocess boundary

Settled during planning on 2026-09-18, recorded here so it is not relitigated.

- **Swift owns** configuration, orchestration, progress, error recovery, state and UI.
- **Subprocesses** run `configure`, `make`, `wine` and the rest. No design removes these;
  something has to start `make`.
- **The prototype's shell scripts are a reference, not a component.** They are not wrapped,
  vendored or shipped.

The argument for keeping the shell layer — that it is the thinnest possible wrapper and can
be run by hand when something breaks — assumes the user is someone who reads shell. That is
exactly the assumption this project exists to remove. Once settings must be editable in a
GUI, progress must be reportable step by step, and a failure must offer a next action, the
orchestration has to live where the UI can see it.

The knowledge those scripts carried in comments is not lost; it is in `docs/`, where it is
easier to read than it was interleaved with `configure` flags.

## Open questions

- **gnutls.** freetype, SDL2 and MoltenVK have been seen loading by their rewritten names
  (sake, 2026-09-19). HTTPS through Wine's own WinHTTP works in sake's bottles (sake, 2026-09-29
  and 2026-09-30), but nothing checked which library served it, so gnutls is still the one
  soname not seen loading by name ([layout.md](layout.md#relocatability)).
- **How much to generalise beyond one title.** The prototype hard-coded Diablo IV in several
  places: launch arguments, process identification, which directories to import. What to import
  is now a difference against a fresh prefix, and a process is recognised by the executable the
  title names; the arguments come from a heuristic for one launcher, `libcef.dll` beside the
  program, rather than a rule for Chromium. Nothing yet knows that starting Diablo IV directly
  fails on the token ([runtime.md](runtime.md#pressing-play-does-two-separable-things)).
- **The rename guard asks what sake started, not the prefix.** A prefix's processes can be found
  through its socket directory ([runtime.md](runtime.md#taking-a-bottle-down)), but the guard
  that refuses to rename a bottle with a game in it still asks what sake started, so it is
  narrower than it needs to be. A wineserver one of Wine's tools started is not something it
  knows about, so running winecfg does not refuse a rename the way a running game does.
- **`AppModel` has quietly become where decisions live, and the tests cannot reach it.** Whether
  a bottle may be renamed, which run a title's status belongs to, which variable names a title
  may not set (`typedEnvironment()`), and what to forget after an uninstall are all judgements,
  and all in the app target, where `scripts/test.sh` does not reach. `CLAUDE.md` says logic in a
  view stops being tested; this is the same thing one layer down. Either these move behind types
  that do not know about SwiftUI, or the app target gets tests of its own.
- **Where the CrossOver version lives.** It is a knob users may need — a newer CrossOver may fix
  or break a given game, and CodeWeavers keep several versions available — but exposing it
  invites them to pick a combination nobody has run. Four of sake's patches are upstream Wine
  commits that a later CrossOver will contain, and the day the tarball sake builds is based on
  wine-11.11 or later they are to be deleted, not rebased.
