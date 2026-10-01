# Debugging a game in a bottle

How to tell what state a failing run is in, and the instruments that answered questions here.

*Unless an entry says otherwise, it was learned in the d4-mac prototype on Diablo IV and
Battle.net, by 2026-09-18.*

## Telling failure states apart

Thread count separates the top three states and RSS the bottom two, and
`vmmap $pid | grep -icE 'Metal|AGX'` says whether graphics was ever reached: about 50 mappings
means never, 100 or more means rendering. RSS alone misleads, and a hang and a slow start look
nothing alike.

| state | threads | RSS | Metal/AGX maps |
|---|---|---|---|
| no Rosetta registration, or a mismatched-ABI module | 9-11 | 125-155 MB | ~50 |
| the `\DosDevices` loop (before the BOOLEAN fix) | 12 | 235-245 MB | ~50 |
| graphics up, waiting on the client | 17-19 | 390-410 MB | 74-81 |
| running and rendering | 83-98 | 1.7-4.6 GB | 100+ |

Four traps in that table, each of which produced a wrong conclusion:

- **Read the running row as "well past 40"**, not as a window to match. It read 83-90, then
  83-96, then 83-98, widened each time someone measured again.
- **The counts include the process row** (`ps -M -p $pid | tail -n +2 | grep -c .`). Count
  thread rows alone and everything reads one low: the stall comes out at 11, lands in the row
  above, and a reproducing hang gets reported as a dead build.
- **Threads do not separate the bottom two states**, 9-11 against 12. RSS does: 125-155 MB
  against 235-245 MB.
- **Sample, and keep the peak.** Looked at only at the end, a build that clears the check and
  then dies of something unrelated is identical to one that never cleared it.

Which process is the game is its own question, with its own traps:
[runtime.md](runtime.md#starting-and-recognising-a-title).

## Wine's own tracing

sake starts everything with `WINEDEBUG=-all`, so a trace is something added to one run.

- **`+loaddll` names the last DLL before a hang**, and is safe on its own. `+server`,
  `+syscall`, `+module`, `+seh` and `+file` are light enough to keep a failure reproducing.
- **`err+all` causes crashes rather than revealing them.** A failed `dlopen` of a missing dylib
  produces a `dlerror()` string long enough to overflow Wine's debug buffer; the exception
  cannot be dispatched and the process dies. Raising the log level turns a cleanly handled
  failure into a crash.
- **A whole-module relay trace can hide the bug.** `RelayFromInclude` on the loader logs about
  7M calls, and the game then starts fine. That was read as timing sensitivity and was not: the
  overhead changes what callees leave on the stack. A Heisenbug limits which instrument you may
  use; it is not evidence about the cause.
- **`+pid` before anything else when there is more than one process.** Without it every line
  is prefixed by a thread id, and four Chromium processes cannot be told apart (sake, on Steam,
  2026-09-20).
- **`<program>:+<channel>` traces one process.** An option with a name and a colon in front
  applies only where the executable has that name (`parse_options` in
  `dlls/ntdll/unix/debug.c`), so a game Steam starts can be traced without Steam's own
  processes. `-all,Dungeons-Win64-Shipping.exe:+pid,Dungeons-Win64-Shipping.exe:+file` in
  Steam's environment gave 24 MB by the time the game showed its first dialog (sake,
  2026-09-30).
- **`+macdrv_d3dmtl` is D3DMetal's half of the conversation**: the channel of
  `dlls/winemac.drv/d3dmetal.c`, the only Wine code D3DMetal calls. A `get_win_data` with no
  `create_metal_device` after it means winemac returned NULL, and the six calls of a
  swapchain's creation read like a checklist (sake, 2026-09-20).
- **`+win` names the owner of an HWND**, class and parent included, which is how "whose window
  is the GPU process drawing into" was answered (sake, 2026-09-20).
- **A fault inside a dylib has no module name in `+seh`.** `vmmap` a live process for the
  `__TEXT` ranges of `libd3dshared`, `D3DMetal` and `winemac.so`, then `objdump -d` the dylib
  at `rip` minus its start; `+loaddll` knows only PE modules (sake, 2026-09-20).
- **Crashpad eats the crash.** A CEF process never reaches `winedbg --auto`, so there is no
  backtrace to wait for, and `+seh` is the only view of where it died (sake, 2026-09-20).

## Looking from the Mac side

- **`vmmap` says what is loaded**, where `WINEDEBUG=+module` may not. The two `TRACE`s in
  `init_non_native_support` run only once something calls `pe_module_loaded`, which
  `wine cmd /c exit` never does, and during a real game start they did not reach a filter on
  wine's own stderr either. Two attempts went that way before the mapping was looked at, which
  took one command (sake, 2026-09-19).
- **Wine keeps its sockets in `wineserver`**, not in the Windows-side process. `lsof` against
  the Battle.net pid shows no connections while it talks to Blizzard happily, which produced
  three wrong network conclusions in a row.
- **`wineserver -k` without `WINEPREFIX` goes after `~/.wine`**, exits 0 and reports success
  having killed nothing. Even with it, it is only the first half of taking a bottle down
  ([runtime.md](runtime.md#taking-a-bottle-down)).
- **Attaching a debugger to Diablo IV is destructive.** The protected loader answers with an
  unhandled `0xc00000e5` and obfuscated registers, and the process drops from 58% CPU to 1.8%:
  the state you came to read is gone. `sample(1)` is safe, but cannot unwind through
  `__wine_syscall_dispatcher`.
- **A Wine window can be photographed behind the terminal.** With Screen Recording granted to
  the terminal, `screencapture -x -o -l <CGWindowID>` captures an occluded window;
  `CGWindowListCopyWindowInfo` gives the id, and Wine's windows have the owner `wine`. A
  full-screen capture shows whatever is in front, which here is always the terminal. Capturing
  by id is what turned "black" from a report into 100.00% of 1,232,000 pixels. **Not once the window
  hosts another process's layer**: then `-l` fails with "could not create image from window",
  and `-R` never worked here at all, so raise the window
  (`set frontmost of (first process whose unix id is …)` through System Events), take the full
  screen, crop to the window's bounds, and hand focus back to the terminal (sake, 2026-09-20).

## An application's own logs

- **Read them first.** Battle.net writes
  `drive_c/users/crossover/AppData/Local/Battle.net/Logs/{battle.net,libcef}-*.log`, and the
  libcef log named the real problem after a lot of guessing had not.
- **`--remote-debugging-port=9222`** tells "not painting" from "painting but not shown".
  Battle.net forwards arguments it does not know to CEF, and `Page.captureScreenshot` proved
  the renderer was drawing the login form perfectly while the window was black.
- **MoltenVK's `Created N swapchain images with size (W, H)` lines are a free instrument.**
  Comparing which surface sizes appear between runs exposed the missing content-sized surface,
  and then confirmed the fix.

## Method

- **Search first, then measure.** The `WINE_SIMULATE_WRITECOPY` fix is documented across
  Lutris, GamingOnLinux and CodeWeavers' own forum, and hours of first-principles crash analysis
  went in before anyone searched. The lesson was then ignored on the Play button and the same
  bill arrived, and that time the search found the game update rather than the cause: hence
  both halves.
- **Diff against a working implementation on the same machine.** With CrossOver installed and
  the tree built from its sources, anything that differs is configuration or build flags.
  Running CrossOver's binaries against the prototype's bottle answered "build or bottle?" in one
  command. Its Perl `bin/wine` is readable, and `--bottle NAME --ux-app /usr/bin/env` dumps the
  environment its launcher builds: bisect the environment from the side that works, rather than
  guessing single variables against a failing run.
- **Make the two candidates produce different observable output before believing either.** The
  Play button was blamed on `Agent.exe` not passing an environment variable. The variable
  arrives; that diagnosis stood only because the symptom it predicted was the symptom present.
- **Check that the control actually ran.** A control run whose log is zero bytes reproduced
  nothing; it failed to start.
