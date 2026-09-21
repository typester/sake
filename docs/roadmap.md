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

None of its code is here, deliberately. What came across is the reasoning, in
`wine-build.md`, `runtime.md`, `licensing.md` and `layout.md`. Every claim in those files
says where and when it was measured. Most of it is still the prototype's; where sake has
since measured something itself, the section says so and carries its own date.

## Phases

### Phase 1 — the skeleton (done)

An app that builds, launches and does nothing. Repository conventions, and the prototype's
knowledge written down.

### Phase 2 — the build pipeline in Swift (done)

Download, verify, configure, `make`, install — driven from Swift, reporting progress the UI
can render. This is where `wine-build.md` became code.

The chain ran end to end on 2026-09-19: the preflight checks (Apple silicon, Rosetta 2, the
Command Line Tools, the Game Porting Toolkit, disk space), the two pieces the rest sits on
(the on-disk layout as a value type, and a subprocess runner that streams output and can be
cancelled), fetching the eleven sources against pinned hashes, building the tools and
libraries into the engine prefix, building Wine itself against them — configure, the
`@loader_path` soname rewrite, make, install, and a check that this is CrossOver's tree and
not upstream's — and guiding Apple's D3DMetal in from an image the user mounted. That leaves
a 1.1 GB engine.

What it does not do is **run** a game. Starting Wine at all needs a prefix, and that is
Phase 3.

### Phase 3 — bottles and titles (under way)

Creating prefixes, importing an existing install, per-title settings. This is also where the
prototype's two ntdll patches have to land, and where the three settings in `runtime.md`
stop being something only the prototype has tried. The per-title knowledge
is pure data (executable path, arguments, environment, how to recognise its process), so it
belongs in a declarative form the GUI can read and edit — not in code.

**Creating a prefix is done, as of 2026-09-19**, and it is the first thing here that runs
what the earlier phases built: wineboot, the wait, the checks that WoW64 came up and that
Wine found the engine's own libraries, and the crash dialog turned off before anything can
put one up. `runtime.md` has what that measured.

**Importing is done too, the same day.** A game already installed under CrossOver is cloned
in rather than copied, which costs no disk at all, and what comes across is decided by
difference against a fresh prefix — so no title is named in the code. `layout.md` has the
measurement and `licensing.md` the line it stays inside.

**Starting a title is done, also 2026-09-19**, and with it the first end-to-end evidence
that any of this works: the Battle.net client comes up in sake's own bottle and loads its
login page. What a title is — executable, arguments, how to recognise its process — is a
value, not code.

**The two patches landed the same day, and with them a game runs.** Diablo IV starts behind
a live parent process and reaches 92 threads, 1982 MB and 103 Metal/AGX mappings, where the
unpatched build stalls flat at 12. `runtime.md` has both measurements and what they are
against; `licensing.md` has why `patches/` is not MIT. The Play button itself was pressed on
2026-09-20 and the game was played; the probe reproduced the check it trips over, and then
the button turned out to agree.

**A game can be put in without CrossOver, as of 2026-09-20.** An installer the user
supplies runs in a chosen bottle, and anything already in a bottle can be added to the
library by hand — name, arguments, and the executable relative to `drive_c`, kept in
`sake-titles.json` inside the prefix so that a rename and a delete stay what `layout.md`
measured them to be. `licensing.md` has why sake runs an installer but never fetches one.
**A real installer has been through it, on 2026-09-20**, run through the app by the person
this was built for rather than by the machine that wrote it. `Battle.net-Setup.exe` is
`PE32 … Intel 80386` — a 32-bit installer, which until then was only inferred to work
from a populated `syswow64` — and it installed a client that is PE32 too. The run left a
57 KB log under `build/`. Later the same day that client signed in, Play was pressed in it,
and Diablo IV was playable with a keyboard and mouse — **the whole of it, from a Mac with
no CrossOver on it to a game somebody played.** A Switch Pro Controller over USB played it
too, and Steam went on to sign in and run Stardew Valley — both the owner's word rather than
a trace, and `runtime.md` says which is which. What nobody has written down yet is a second
machine.

**sake ships no titles of its own, as of 2026-09-20.** It knew Battle.net once — an
executable path, its flags, and a row that appeared when that path existed. What the row
carried is now general: the flags come from looking for `libcef.dll` beside the program,
and a process is recognised by the executable the title names. The cost is that a bottle is
empty until somebody adds something to it, whether the game arrived from an installer or
out of a CrossOver bottle.

**Steam was the second title, on 2026-09-20, and the first the engine could not show at
all.** Its installer ran through the app, the client updated itself and came up as a black
700×440 window on every start, whatever flags it was given. The cause was not in the title
and not in the flags: the client's browser process owns the window and its GPU process draws
into it, and the winemac.drv in CrossOver 26.3.0's Wine 11.0 has no way to carry rendering
across that line — D3DMetal's shim was handed a NULL window record and dereferenced it,
Vulkan drew into a view nothing hosted, and software compositing drew from the wrong
process. Upstream Wine solved the top-level half in wine-11.11; sake carries that, the
child-window half from Wine bug 60263, and its own change to the D3DMetal glue, as four
patches in `patches/`. `runtime.md` has the measurement and what to look for.

What the second title taught about profiles: Steam needed **nothing** per-title once the
engine could host a swapchain across processes — no flags, no environment, no registry. The
three Chromium flags sake offers are Battle.net's, measured on its 32-bit CEF, and Steam's
client cannot even take them. So a title profile was name, executable and arguments until
2026-09-21, when it gained an environment of its own — `runtime.md` has what that may and
may not set —
and the argument suggestion is a heuristic for one launcher rather than a rule for Chromium.
Nothing yet knows that starting Diablo IV directly fails on the token — `runtime.md` says
so, the app does not.

### Phase 4 — the GUI proper (under way)

Setup flow, library, per-title configuration, uninstall. `layout.md` covers where things go
and why uninstall has to be an explicit action.

**Started on 2026-09-19 by splitting the window in two.** Setting sake up is done once and
running a game is done every day, and one scrolling column had them interleaved. Now there
is a library window and a setup wizard, one step per screen with the whole list of steps
beside it — the list stays because a step here can take tens of minutes and fail, and a
wizard that shows only the current card leaves you with no idea where you were.

Which step is current, and what blocks each one, is in `SakeKit` rather than the wizard: it
is the only real decision the wizard makes, and logic in a view is logic that stops being
tested.

The library is a list with a detail pane rather than a row per game, for two reasons worth
keeping: a row per game means a Play button per game, and the detail pane is where per-title
settings go when they arrive. Importing is a sheet on that window rather than a window of
its own because it finishes in under a second. It used to be justified by belonging to one
bottle as well; that half came back on 2026-09-20, when the picker inside it went and the
way in became the bottle's own screen. The setup
wizard is a window instead precisely because it does not finish quickly: it runs for tens of
minutes and sends the user to a browser part way through.

A row is its name and nothing else: every row under a heading is a title, so a per-row
glyph tells them apart from nothing, and `gamecontroller` — the widest symbol of the ones
tried, ink filling its 22×14pt box — pushed each name 27pt right of its own heading.
Measured in sake on 2026-09-21. If that column is ever wanted back, what would earn it is
state the detail pane can only show for one title at a time: running, or not installed.

**More than one bottle followed on 2026-09-19.** The library is a section per bottle, and a
bottle is selectable in its own right rather than only through the games in it — a bottle
just made has nothing in it, so a heading alone would be a dead end. What the detail pane for
one offers is how a game gets in: the import, the game's own installer, and adding
something already there as a title. The import is offered only where there is a CrossOver
bottle to take from, from 2026-09-21: `CrossOverBottle.available()` already answers that,
and a button whose sheet can say nothing but why it cannot work is worse than no button.
Those are per-bottle actions and they live on the
bottle, which is where they moved on 2026-09-20 — the sidebar's menu keeps only what is
about the library rather than about one bottle in it.

Nothing in `SakeKit` had to change to allow it: `BottleBuilder`, `BottleImporter` and
`TitleLauncher` all already took a name. What was missing was a way to enumerate what is on
disk and a way to say whether a typed name can be used, both of which are on `Bottle` and
tested there rather than in the sheet that asks.

**Renaming and deleting one followed on 2026-09-19.** Both turned out to be directory
operations, because nothing inside a prefix names the prefix — `layout.md` has what that was
measured against. Both are methods on `Bottle` beside `stop()` rather than anything a caller
assembles, for the reason `stop()` is: each has to take this prefix's wineserver down first,
and the same command without a `WINEPREFIX` goes after `~/.wine` and exits 0.

Deleting moves the bottle to the Trash. It can be undone, which is worth having for a bottle
with a signed-in client in it, and it is honest about the one thing it cannot do: a bottle
whose game was imported returns almost none of its size even once the Trash is emptied,
because those blocks belong to the CrossOver install as well. `layout.md` has the figures,
and the confirmation says so rather than quoting the size as a promise.

**Taking the prefix down is why the two ask differently.** Renaming a bottle with a game
running in it is refused; deleting one is not. Nobody changing a label asked for their game
to stop, so a rename that did it anyway is a surprise with nothing gained — whereas throwing
a bottle away already means stopping what is in it, so there the confirmation says so and
goes ahead. The guard is only as good as what sake started itself, because nothing in `ps`
says which prefix a Wine process belongs to; `Bottle` taking the prefix down regardless is
what keeps the rest safe rather than merely quiet.

**Uninstall landed on 2026-09-19 and was run here for real.** It is in the app menu rather
than in either window, because it is about the app and not about what is on screen. It takes
the two directories `layout.md` names and nothing else, and it takes them to the Trash — the
same choice bottles made, and the reason the real run could be undone afterwards rather than
costing a rebuild.

What it deliberately does not do is delete Sake.app. `licensing.md`'s one standing promise
about the user's copy of D3DMetal — that it does not outlive the cache — is now a test rather
than a sentence.

Still to come: adding and editing titles, and taking the build cache away on its own, which
is what somebody who wants their 4 GB back but not to lose their games is asking for.
Two rough edges found on the way: the delete confirmation names the game twice when one is
running, and a bottle just created does not offer what could be imported into it until
something else surveys — `create` sets `importTarget` after the survey that would have used
it.

**A bottle hands over Wine's own tools rather than growing settings of its own, from
2026-09-21.** The Windows version, the DLL overrides, the drives and the audio device are
winecfg's panels, and what they set is the bottle's registry — which `runtime.md` records as
being flushed lazily by wineserver, so a copy of it in a SwiftUI form would be a second copy
that lies. The engine already ships fourteen of these programs; the bottle offers four of
them, the ones that mean something to a bottle with a game in it: winecfg, regedit, the
uninstaller and the task manager. The rest are either not useful here or better done on the
macOS side.

Offered, not recommended. winecfg's Windows-version dropdown can break a game, which is the
same objection the CrossOver-version knob has in the open questions below: exposing it
invites a combination nobody has run. The difference is that these are Wine's own surfaces
and sake reimplementing them would not make them safer, only harder to keep true.

The wineserver a tool starts is not something the rename guard knows about — it asks what
sake started, which is the narrowness the open question about prefixes already describes.
Running winecfg therefore does not refuse a rename the way a running game does.

**And one layout trap, found the same day.** A `Text` with
`.fixedSize(horizontal: false, vertical: true)` in a detail pane makes the pane demand a
height the window does not have to offer; the demand reaches the `NavigationSplitView`,
which is laid out taller than the window and centred in it, so the content leaves the
visible area upwards and the window draws empty while the accessibility tree still reports
every string. The panes scroll now, which keeps the modifier — it is there so a long value
wraps instead of being truncated — and bounds what the demand can do. The setup wizard had
been doing this from the start.

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

- **gnutls is the last `@loader_path` soname nothing has loaded.** As of 2026-09-19 a
  running Wine loads freetype, SDL2 and MoltenVK by the rewritten names; `bcrypt.so` opens
  gnutls only when something asks for TLS, and nothing has yet. See `layout.md`. (This used
  to be the whole question of whether Wine could load any of them, and path length before
  that. Both went away.)
- **A built engine does not pick up a change to a patch.** `bin/wine` existing is what says
  the Wine step is done, so changing something in `patches/` means deleting that by hand and
  rebuilding. ~~And the rebuild then fails to recognise stacked patches as applied.~~
  **Answered 2026-09-20**, the same day it was found: `WinePatcher` asked `patch` to reverse
  each one alone, which a patch under two others cannot do; it now treats patches on one
  file as a stack, reversed top-down on a copy of the files they touch. `wine-build.md` has
  the measurement. The D3DMetal half of this went away on 2026-09-19 — a rebuild now drops that
  step back to unfinished, because it asks whether the DLLs are Apple's rather than whether
  the framework is there — but nothing yet knows that a patch has changed under it.
- **How much to generalise beyond one title.** The prototype hard-coded Diablo IV in several
  places (launch arguments, process identification, which directories to import). One of
  those went away on 2026-09-19 — which directories to import is a difference, not a list —
  but launch arguments and process identification are still per-title, and one data point
  is thin.
- ~~**Nothing tells sake which prefix a running Wine process belongs to.**~~ **Answered
  2026-09-20**: the other half of `/tmp/.wine-<uid>/server-<dev>-<inode>` is the prefix
  directory's inode, and `lsof` against that directory names every process in the bottle —
  including the ones `ps` describes only as `C:\windows\system32\services.exe`. An inode
  survives a rename, so this holds across one. `runtime.md` has the measurement and what
  it cost to find out. What is left of the question: the guard that refuses to rename a
  bottle with a game in it still asks what sake started rather than asking the prefix, so
  it is narrower than it now needs to be.
- **`AppModel` has quietly become where decisions live, and the tests cannot reach it.**
  Whether a bottle may be renamed, which run a title's status belongs to, and what to forget
  after an uninstall are all judgements, and all in the app target — `scripts/test.sh` only
  reaches `SakeKit`. `CLAUDE.md` says logic in a view stops being tested; this is the same
  thing one layer down. Either these move behind types that do not know about SwiftUI, or
  the app target gets tests of its own. `typedEnvironment()`, added 2026-09-21, is another
  of these: which variable names a title may not set is a judgement, and it lives in the app
  target where the tests cannot reach it.
- **Two buttons say "Check Again" in the setup wizard.** The bottom bar adds one when the
  step is the machine step, and `primary` adds another because that step is not done, so
  both render the same verb. The comment above the first says it is there for the step
  "worth repeating after it has passed" — which is the condition the code does not check.
  Found 2026-09-21, not fixed.
- **Editing a title moves it to the end of the sidebar.** `TitleStore.add()` filters the id
  out and appends, so saving Options reorders the library. Harmless and confusing, and it
  cost a measurement on 2026-09-21: a row addressed by index was no longer the row it was.
- **Where the CrossOver version lives.** It is a knob users may need — a newer CrossOver may
  fix or break a given game — but exposing it invites them to pick a combination nobody has
  run. Steam gave the knob a concrete reason on 2026-09-20: two of sake's patches are
  upstream Wine commits that CrossOver's next Wine rebase will contain, and the day the
  tarball sake builds is based on wine-11.11 or later they are to be deleted, not rebased.
