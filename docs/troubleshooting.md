# Troubleshooting

What to do when something goes wrong. Whether a game is known to run at all is in the
[README](../README.md#what-runs); if nothing here helps, [report it](#reporting-a-problem).

## First, read the log

Every run writes a log in `~/Library/Caches/Sake/build`, and sake's window shows only its last
line:

- `title-<id>.log` for a title
- `install-<name>.log` for an installer
- `tool-<name>.log` for one of Wine's tools

The names do not include the bottle yet, so a run in one bottle overwrites the log of the same
title or installer in another ([#14](https://github.com/typester/sake/issues/14)).

**Wine Tools**, on a bottle, opens Wine's own winecfg, regedit, uninstaller and task manager in
that bottle.

## Setting up

- **A step shows a lock.** Something it needs is not done yet, and the step says which: This
  Mac's checks, or a step before it. This Mac needs all five to pass — Apple silicon, Rosetta 2
  (`softwareupdate --install-rosetta`), the Command Line Tools (`xcode-select --install`), the
  Game Porting Toolkit, and 10 GB free — and until it does, every step not yet done is locked.
  Install what is missing or make room, then press **Check Again**.
- **The sidebar says Setup needs attention.** A step is not done any more: an update to sake
  changed what it builds, or This Mac no longer passes its checks, such as with less than 10 GB
  free. Click it: the wizard opens on the first step not done and says why. Building Wine again
  takes minutes and the GDK Runtime seconds; D3DMetal is then one press, from the copy sake
  kept, with no need for the toolkit's image.
- **Gatekeeper stops sake the first time.** The app is not notarised. Allow it in System
  Settings > Privacy & Security, or install it with
  `brew install --cask --no-quarantine typester/sake/sake`.
- **The D3DMetal step waits for the toolkit.** Download Game Porting Toolkit 4.0 beta 2 from
  <https://developer.apple.com/download/all/>, open the `.dmg`, then press **Install**. sake
  copies what it needs and unmounts the image it mounted; you need the image only once.

## Starting a game

- **Battle.net's login form never appears, or its GPU process keeps exiting.** The title needs
  its arguments: `--use-gl=angle --use-angle=vulkan --in-process-gpu`. sake fills them in when
  it finds `libcef.dll` beside the program or one folder below it; if they are gone, put them
  back in the title's Options.
- **Diablo IV says "There was a problem logging in. (Code 7)"** It was started directly. Start
  the Battle.net launcher and press Play inside it: the client hands out the game's login token
  only after that press.
- **A game built on Microsoft's GDK, such as Minecraft Dungeons II.** The first time it signs
  in, sake shows a code and opens `microsoft.com/link` in your browser; type the code there and
  sign in. Later starts sign in without asking.
  - **Keep sake running while you play.** The game asks sake for its tokens. With sake not
    running, it waits ten seconds and goes on without a user.
  - **Play with friends by party code.** One Xbox service the game uses, multiplayer activity,
    refuses sake's sign-in, so anything in the game that depends on it does not work.
- **A game on an external disk resets its settings every time it starts.** On a disk formatted
  exFAT, macOS writes a `._` file beside nearly every file, and a game can read one as its own
  settings. sake's Wine leaves those files out; if the sidebar says Setup needs attention, build
  Wine again.
- **A game seems to hang, or never gets going.** Before deciding a build is broken, read
  [Debugging](debugging.md#telling-failure-states-apart): it tells four failure states apart by
  thread count, memory and Metal mappings.

## Bottles

- **A bottle has a `D:` drive that leads nowhere.** The bottle was made while the Game Porting
  Toolkit's image was mounted, and Wine mapped it. It is harmless.
- **Import from CrossOver refuses.** Importing clones the game instead of copying it, which
  works only when the CrossOver bottle is on the same disk as `~/Library/Sake`.
- **Deleting a bottle with an imported game gives back almost no space**, even once the Trash
  is emptied: the game's data is shared with the CrossOver install it came from, which still
  has it.
- **A bottle cannot be renamed while a game runs in it.** Stop the game first. Deleting a
  bottle stops what runs in it, and the confirmation says so.
- **Wine's own settings**, such as the Windows version, DLL overrides, drives and the audio
  device, are in winecfg, under Wine Tools. Changing the Windows version can break a game.

## Controllers

Nothing to set up. The engine is built with SDL2, which knows device-specific protocols such as
the Switch Pro Controller's, so a controller should work. If yours is not seen, report it.

## After you quit

- **The Dock still shows sake after it has quit.** Something sake started is still running.
  **Stop** on a title takes down everything in its bottle, not only the game. In a bottle that
  is a symlink to another disk, Stop does not find what runs there
  ([#15](https://github.com/typester/sake/issues/15)).

## Removing sake

**Uninstall sake…** in the app menu moves `~/Library/Sake` and `~/Library/Caches/Sake` to the
Trash: the engine, the bottles and the games in them, your Xbox sign-in, and the build cache
with sake's copy of D3DMetal. Until you empty the Trash, it can all be put back. Sake.app
itself stays; drag it to the Trash, or run `brew uninstall --cask sake`. Three small files are
left behind: `~/Library/Preferences/dev.typester.sake.plist`,
`~/Library/HTTPStorages/dev.typester.sake` and `~/Library/Caches/dev.typester.sake`.

## Reporting a problem

[Open an issue](https://github.com/typester/sake/issues/new) with your Mac, your macOS version
and sake's version (About Sake, in the app menu), and attach the log from
`~/Library/Caches/Sake/build`; paths in it show your macOS user name. For whether a game runs,
working or not, use the
[compatibility form](https://github.com/typester/sake/issues/new?template=compatibility.yml).
