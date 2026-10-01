# Running games: the settings every run needs, and what each patch fixes

A built Wine is not a working one. This file is what a game needs on top of the build — the
bottle, three settings, how a title is started and stopped — and the nine patches sake carries,
each with what it fixes and how to tell that it is working. Without the patches Wine still
configures, installs and passes every check, and fails only once a game starts, which is why
setup refuses to build it with none. [how-it-works.md](how-it-works.md#what-sake-changes-in-wine)
has the patches in one table, and [debugging.md](debugging.md) the instruments.

*A measurement without a tag is the d4-mac prototype's, made on one machine on 2026-09-17 and
2026-09-18; sake's own measurements and the owner's reports say so.*

## A bottle

**`wine wineboot --init` makes a prefix, and `wineserver -w` is where it finishes.** Wine's
processes outlive the command that started them, so returning from wineboot is not the end.

**`WINEDLLOVERRIDES="mscoree,mshtml=d"`, or wineboot never returns.** Without it wineboot puts
up the Wine Mono installer's dialog and waits for a click that never comes: 0% CPU inside
`CFRunLoopRun` → `mach_msg` forever, and `syswow64` is never populated (prototype, 2026-09-17).

**An empty `syswow64` is the one check worth making.** It means WoW64 did not initialise, so no
32-bit application will run, and Battle.net's launcher is 32-bit. Everything else about the
prefix looks finished when this is what happened. A populated one ran them: Battle.net's
installer is `PE32 … Intel 80386`, and run through the app it installed a client that is PE32
too and left a 57 KB log under `build/` (sake, 2026-09-20).

**Turn the crash dialog off before anything can crash**: `ShowCrashDialog=0` under
`HKCU\Software\Wine\WineDbg`. Otherwise a crash spawns `winedbg --auto`, which puts up a dialog
and holds the process until somebody clicks Close — an unattended command just blocks until it
times out — and resets `WINEDEBUG` on the way, so suppressed logging comes roaring back into
whatever was being debugged (prototype, 2026-09-18). Both halves showed up in sake: with the
value set, a run whose render process kept hitting a breakpoint carried on unattended instead
of stopping on a dialog, and `winedbg --auto` still ran and symbolised, spilling 880 lines of
`dbghelp_dwarf` fixmes into a run made with `WINEDEBUG=-all` (sake, 2026-09-19).

**wineserver keeps the registry in memory and writes it out lazily**, so `user.reg` read from
disk can be stale; take the server down first, then read the file (prototype, 2026-09-18).

*sake's first bottle, 2026-09-19: Apple M5, macOS 27.0, the engine built the same day.*

| | |
|---|---|
| `wineboot --init` | 17.2 s, first run, nothing warm |
| `wineserver -w`, the registry write, shutdown | 4.0 s |
| the bottle | 997 MB, 801 files in `system32` and 841 in `syswow64` |
| everything Wine printed | MoltenVK's three-line banner. No `err:`, no `fixme:`, nothing else |

Two things in a fresh bottle that a path in these files may not lead you to expect:

- **The Windows user is `crossover`,** not the account's short name: `drive_c/users/crossover`.
  CrossOver's tree does this, and the prototype's bottle has the same directory, so every
  `drive_c/users/…` path in these files means that one.
- **`dosdevices` maps whatever was mounted at the time.** A bottle created while Apple's Game
  Porting Toolkit is still mounted gets a `d:` pointing into `/Volumes`, which dangles as soon
  as it is ejected. Harmless, and worth recognising rather than debugging.

## Three settings every run needs

None is on by default, and no symptom resembles its cause.

**Two are environment and sake's to apply; one is Chromium's and is not.**
`WINE_SIMULATE_WRITECOPY` and `CX_APPLEGPTK_LIBD3DSHARED_PATH` are environment, so
`Bottle.environment` puts them on everything the engine runs. `--in-process-gpu` and the two
ANGLE flags beside it are **Chromium's**, and mean something only to a program built on CEF —
putting them on a game that reads its own `argv` is not free. sake therefore offers them when it
can see it is dealing with a Chromium app, and otherwise leaves the arguments empty.

What it looks for is `libcef.dll`, **beside the program or one directory below it**. A real
Battle.net install has its exe at `Battle.net/Battle.net.exe` and its CEF build at
`Battle.net/Battle.net.17821/libcef.dll`, so looking only beside the program would never offer
the flags to the one title known to need them (sake, 2026-09-20).

**The flags are Battle.net's, not Chromium's in general.** Steam's client takes none of them:
`steam.exe` consumes whatever it is given and passes nothing through to `steamwebhelper.exe`,
and Steam's own switch list has no in-process-GPU option left. Its `libcef.dll` sits three
directories down, so the heuristic never offers them for it — correctly, as it turns out. What
Steam needed was in the driver ([below](#steam-one-process-draws-another-owns-the-window))
(sake, 2026-09-20).

### `WINE_SIMULATE_WRITECOPY=1` — or Battle.net never fetches its login page

CodeWeavers' `CW Hack 22996`. With it, a page that has been `VirtualProtect`ed away from
`PAGE_WRITECOPY` is reported as already copied, which is what Windows does.

Without it, every CEF render process executes an `int3` within five seconds of starting, always
at the same address; `UAuth: begin loading` never appears and the login page is never even
requested (prototype). CodeWeavers told Battle.net users to set this by hand in 2023, and it is
still not automatic.

*Measured in sake on 2026-09-19, by starting the client twice with nothing different but this
variable:*

| | with it | without it |
|---|---|---|
| `wine: Unhandled exception 0x80000003` | none in 75 s | 11 in 60 s, every one at `6B0300E1` |
| `UAuth: begin loading` | present, then `finished loading. statusCode=200 state=Login` | never appears |
| `Battle.net.exe` processes | 4 | 3 |

`0x80000003` is `STATUS_BREAKPOINT`, which is the `int3`; the first arrives nine seconds in, and
then one every five seconds. Same bottle, same arguments, same other three variables: this one
line is the difference between a login page and a breakpoint.

### `--in-process-gpu` and ANGLE — or Battle.net's login form is drawn but never shown

With a separate GPU process the login web view never gets a compositor surface of its own.
MoltenVK reports swapchains for the window (348x646) and the chrome strip (348x50) but never one
the size of the page content (348x558); the view stays black while the renderer paints the form
perfectly. Folding the GPU into the browser process makes the content surface appear
(prototype).

This is not a graphics setting in disguise. Turning off Battle.net's own browser hardware
acceleration changes nothing, `--disable-direct-composition` changes nothing, and fonts are not
involved.

Battle.net also needs `--use-gl=angle --use-angle=vulkan`. Left alone, ANGLE tries its D3D11
backend, which gets nothing because D3DMetal has no 32-bit half, then SwANGLE, then gives up
with "GL is disabled", and the GPU process exits with `ACCESS_VIOLATION` (prototype).

### `CX_APPLEGPTK_LIBD3DSHARED_PATH` — or Diablo IV does not start at all

Apple's `libd3dshared.dylib` exports `register_non_native_code_region`, which is how Rosetta is
told a region of memory holds dynamically generated x86_64 code. Wine looks that symbol up only
when this variable points at the library (`init_non_native_support()` in
`dlls/ntdll/unix/loader.c`). CrossOver's launcher sets it on every run; nothing else does.

Blizzard's protected loader `diablo_iv_loader.dll` generates code at runtime and drives it with
fibers plus `SetThreadContext` on other threads. Without the registration the fiber switch does
not return where the loader expects, its scheduler loop re-enters, and it deadlocks
re-acquiring its own non-recursive SRW lock. What you see is 0.0% CPU, 122 MB resident, nine
threads, no window, and **not one byte** in the game's own `_FenrisDebug-*.txt`. Nothing in that
picture points at Rosetta (prototype).

The 32-bit client is structurally unaffected: `pe_module_loaded()` reaches
`init_non_native_support()` only on the 64-bit side, because the WoW64 entry point
`wow64_pe_module_loaded()` is a stub returning `STATUS_NOT_IMPLEMENTED`.

**`libd3dshared.dylib` goes in the same directory as `D3DMetal.framework`.** `d3d12.so` declares
`LC_RPATH = @loader_path` and looks for `libd3dshared.dylib` beside itself; `libd3dshared` then
`dlopen`s `@rpath/D3DMetal.framework/D3DMetal` relative to *its* own location. Copying only
`libd3dshared` next to the `.so` files breaks it.

So sake copies `libd3dshared.dylib` into `lib/wine/x86_64-unix/`, puts a `D3DMetal.framework`
symlink beside it pointing at `../../external/D3DMetal.framework`, and refuses to call the
install done unless `lib/wine/x86_64-unix/D3DMetal.framework/D3DMetal` resolves. The engine that
comes out has `d3d12.so` linking `@rpath/libd3dshared.dylib` and that symlink landing on a real
x86_64 Mach-O (sake, 2026-09-19). In Diablo IV on this engine, Metal's HUD names
`Game Porting Toolkit 4.0b2` (sake, 2026-09-21).

### Everything else belongs to one title

The two variables above are sake's, and `Bottle.environment` puts them on everything the engine
runs. Anything else is one title's business, and a title carries its own `KEY=VALUE` pairs.
They go in underneath the bottle's, which is composed afterwards, so the five names
`Bottle.environment` writes — `WINEPREFIX`, `WINEDLLOVERRIDES`, `WINEDEBUG`,
`WINE_SIMULATE_WRITECOPY` and `CX_APPLEGPTK_LIBD3DSHARED_PATH` — win. The sheet refuses those by
name rather than accepting a value it would then quietly ignore, because a run that behaves as
though a variable had been set is the worse of the two failures.

**`MTL_HUD_ENABLED=1` draws Metal's performance HUD, and D3DMetal adds a section of its own to
it.** The HUD belongs to the OS, so anything rendering through Metal can show it; what makes it
worth knowing here is that block. In Diablo IV on sake's own engine, above an FPS and GPU-time
graph the HUD names the translation `D3D12 (Metal 4)` and the process `x86_64`, and below it
lists `Game Porting Toolkit 4.0b2` with Dispatch, Draw, Clear Resource, Copy Resource and
ExecuteIndirect counts (sake, 2026-09-21). It is the cheapest look at what D3DMetal is doing per
frame, and it costs no trace.

The prototype lists this variable among the ones that made no difference. That is about the
hang it was tested against, not about the HUD: it did not fix the hang, and it does draw.

## Starting and recognising a title

**A title starts from the game's own directory, by its bare leaf name, with the title's
arguments.** A healthy Battle.net run looks like this in `ps -Ao pid=,args=` (sake,
2026-09-19):

```
start.exe /exec Battle.net.exe --use-gl=angle --use-angle=vulkan
<engine>/lib/wine/../../bin/wineserver
C:\windows\system32\{services,winedevice,plugplay,svchost,explorer,rpcss,conhost}.exe
C:\Program Files (x86)\Battle.net\Battle.net.exe --use-gl=angle --use-angle=vulkan --in-process-gpu
C:\Program Files (x86)\Battle.net\Battle.net.exe --type=utility --utility-sub-type=storage…
C:\Program Files (x86)\Battle.net\Battle.net.exe --type=utility --utility-sub-type=network…
C:\Program Files (x86)\Battle.net\Battle.net.exe --type=renderer …
C:/ProgramData/Battle.net/Agent/Agent.9775/Agent.exe --session=…
```

Three things in that list defeat a naive process check:

- **`wine` turns a relative name into `start.exe /exec`.** sake's own launch therefore appears
  as `start.exe`, never as the game, which is the case the rule below exists for.
- **wineserver does not spell itself `<engine>/bin/wineserver`.** `ps` shows
  `<engine>/lib/wine/../../bin/wineserver`. A teardown check matching the tidy path matches
  nothing and so reports success every time — sake's first version did exactly that, and only a
  real run showed it.
- **`--in-process-gpu` does not mean one process.** It folds the GPU into the browser process;
  the renderer and the two utility processes remain their own. Four `Battle.net.exe` is what a
  healthy run has.

**The game's process is the one whose `argv[0]` ends with the executable's name**, not one that
contains it: a loose match also catches `cmd.exe`, `start.exe` or any launcher carrying the name
in its own arguments, which handed the prototype the wrong process twice. Matching the bare name
at the start is not enough either, because `argv[0]` is spelled differently depending on how the
program was started. So sake cuts `argv[0]` at its first `.exe` and checks what that ends with.

What the client's own logs said on that run is the evidence the settings did their job:
`libcef-*.log` held two `WSALookupServiceBegin failed` lines and nothing else — no GPU errors, no
"GL is disabled" — and `battle.net-*.log` ended
`UAuth: finished loading. statusCode=200 state=Login`, and the renderer that draws the page was
still alive seventy-five seconds later (sake, 2026-09-19). The login form was
seen, the client signed in, and Play started Diablo IV, which was played (the owner's report,
2026-09-20).

## Diablo IV: two ntdll patches and the Play button

*Both patches came from the prototype unchanged and go in before configure. sake measured both
against its own engine and bottle on 2026-09-19, the day it started carrying them; the
prototype's numbers are kept as the before-the-patch half, which sake has not reproduced,
because its engine has never been built without them.*

### 0001: find libd3dshared without the variable

**`patches/0001` resolves `libd3dshared` from `dll_dir` when `CX_APPLEGPTK_LIBD3DSHARED_PATH` is
unset**, because a process whose environment an application composed never inherits the
variable. The variable still wins when set.

With the variable removed, before the patch: 122 MB at 0.0% CPU with nine threads, deadlocked;
after it, 2561 MB at 38.6% CPU with 84 threads, running (prototype). sake's measurement looks at
what is mapped rather than at CPU: with the variable removed from the environment, Diablo IV
came up at 83 threads and 2534 MB with `<engine>/lib/external/libd3dshared.dylib` mapped into
it, seven regions. An unpatched ntdll returns before that `dlopen` when the variable is unset,
so the library being in the process at all is the patch and nothing else (sake, 2026-09-19).
`vmmap` is how to see it, not `WINEDEBUG=+module`
([debugging.md](debugging.md#looking-from-the-mac-side)).

### 0002: read BOOLEAN syscall arguments as Windows defines them

**`patches/0002` is the one that made the Play button work**, and it is worth understanding
before touching ntdll.

Since Diablo IV 3.1.0 (2026-06-30) the loader inspects the process that started it, when that
process is still alive — and `Agent.exe` always is. It opens the parent, reads its image path,
and walks `\DosDevices` one entry at a time with `NtQueryDirectoryObject` to build a
drive-letter-to-device map. CrossOver's build asks for index 0, 1, 2 … 48 and finishes. The
prototype's asked for **index 0 on every call, ~55,000 times a second, forever** — its `+server`
log grew at 17 MB/s, which is how the loop was found.

`WINEDEBUG=+syscall` showed the fifth argument, `RestartScan`, a stack-passed `BOOLEAN`:

| build | `restart` argument word |
|---|---|
| the prototype | `6c006200610000` — UTF-16 `abl`, leftover from a path string |
| CrossOver | `00000000` |

The low byte is FALSE in both. The Windows x64 ABI leaves the upper bits of a narrow argument
undefined and MSVC stores exactly one byte, so the caller is within its rights.
`__wine_syscall_dispatcher` copies the whole 8-byte word into the SysV register, and the
clang-built unix side assumes — as the SysV ABI permits — that a narrow parameter arrives
zero-extended, compiling the test to `testl %r8d, %r8d`. Non-zero garbage above the low byte
therefore reads as TRUE and the enumeration restarts forever.

The fix adds an empty asm barrier that makes the compiler forget the zero-extension assumption,
and applies it to both `BOOLEAN` parameters of `NtQueryDirectoryObject` only, because that is
the call that was measured. **The same exposure exists in `NtQueryDirectoryFile`,
`NtQueryEaFile`, `NtSetTimer`, `NtLockFile`, `NtNotifyChangeDirectoryFile`, `NtNotifyChangeKey`
and `NtCreateEvent`** — Wine's own PE DLLs are their usual callers and keep the slot clean, so
nothing has been seen to need it.

Two things this is *not*:

- **Not a CrossOver-only correctness win.** CrossOver's `ntdll.so` has the identical
  `testl %r8d, %r8d`. It passes because its GCC/binutils-built PE DLLs leave zeros in that slot.
  That reading is inference, not measurement; what was measured is the zero in their trace and
  the string in ours. Either way it is a latent bug in every clang-built Wine.
- **Not Valve's Proton Hotfix.** ValveSoftware/Proton #9926 is a different failure on Linux (an
  exit on a breakpoint before any renderer init). A GCC-built unix side cannot hit this bug.

sake measured it with the prototype's probe shape: `start.exe /exec` keeps a Windows parent
alive exactly as `Agent.exe` does, which reproduces the check in half a minute with no client
and no mouse. Against sake's own engine and bottle: peak 92 threads, 1982 MB, 103 Metal/AGX
mappings, still alive when the sampling ended (sake, 2026-09-19). The stall this replaces sits
flat at 12-13 threads and 235-245 MB for as long as anyone cares to watch, so there is no reading
of those numbers that confuses the two. Play itself was pressed the next day, and the game was
played (the owner's report, 2026-09-20).

### Pressing Play does two separable things

1. **The client becomes willing to hand out a token.** Launching the game directly without a
   press earlier in the same client session gets it all the way up — rendering, intro playing —
   and then `Aurora has rejected the token`, *"There was a problem logging in. (Code 7)"*. In one
   session: a manual launch at 02:13 got Code 7, Play was pressed at 02:48, and a manual launch
   at 02:52 logged in and reached character select (prototype).
2. **`Agent.exe` starts the game.** This is the part the `BOOLEAN` bug broke.

The client logs `Pre-existing game session detected without a pending launch` for every manual
start, **including the ones that log in perfectly**, so that message says nothing about the
token.

So a "launch the game directly" button cannot work for this title on its own: the launcher's own
flow has to be driven at least once per session. sake offers no such button, and nothing in it
knows that a title naming the game's own executable will fail this way.

**A third way in has not been tried.** Blizzard installs its own `Diablo IV Launcher.exe` beside
the game, and the desktop shortcut the installer leaves points at it with no arguments at all:
`drive_c/users/Public/Desktop/Diablo IV.lnk`, 250 bytes, target and working directory and
nothing else (read, 2026-09-21). So a Diablo IV title need not mean starting
`Diablo IV.exe`: it can start the launcher Blizzard ships, which talks to the client the way the
Play button does. **Untested**: the shortcut was read, not run.

## Controllers need SDL2

**Wine has to be built with SDL2, or a Switch-style pad is dead in the game.** `winebus.sys`
has two backends. IOHID is always built and handles pads that behave as plain HID gamepads.
SDL is built only when configure finds SDL2, and it knows device-specific protocols. A pad
that presents itself as a Switch Pro Controller enumerates as a HID device with a reasonable
descriptor and then sends no input at all until it has been through Nintendo's handshake,
which lives in SDL's HIDAPI driver — so an IOHID-only build gives a pad that macOS sees and the
game does not.

Use SDL2 newer than CrossOver's 2.30.12: 2.32.2 fixed a crash initialising with controllers
already connected on macOS, 2.32.6 made Switch controllers initialise reliably on macOS, and
2.32.10 fixed thumbstick range and calibration for Switch Pro Controllers. If a pad
misbehaves, 2.30.12 is the version known to work under CrossOver and the one to bisect
against. Not SDL3: Wine looks for pkg-config's `sdl2` and `SDL_Init` in `libSDL2-2.0*`.

One pad has been played with: an 8BitDo Ultimate 2, which presents itself as Nintendo's
`057E:2009` and which macOS lists as `Pro Controller` (read with
`system_profiler SPBluetoothDataType`, 2026-09-21). That identity is what matters: the ids are
what send it down SDL's Switch driver and Nintendo's handshake. It played Diablo IV:

| where | connection | how it is known |
|---|---|---|
| the prototype | USB | played, 2026-09-17 |
| sake | USB | the owner's report, 2026-09-20 |
| sake | Bluetooth | the owner's report, 2026-09-21 |

The sake rows are reports rather than traces: they show the SDL2 requirement carries over to
sake's own engine and bottle, and are not new evidence about the driver. Other pads have not
been tried.

## Steam: one process draws, another owns the window

**Steam's client needs `patches/0003` to `0006`: without them its window is black on every
start, whatever flags it is given.** The client's browser process owns the window and its GPU
process draws into it, and the winemac.drv in CrossOver 26.3.0's Wine 11.0 has no way to carry
rendering across that line. With the patches a start with no arguments works, and Steam needs
nothing per-title: no flags, no environment, no registry.

*Measured in sake on 2026-09-20 against the default bottle, with Steam's 64-bit client (build
1788652215) installed through the app and the engine built from CrossOver 26.3.0's sources with
D3DMetal 4.0b2: thirteen starts, seven of them traced, six windows photographed.*

**What a start looked like.** The client comes up as a 700×440 window called "Sign in to Steam"
that is black to the last pixel — captured by window id on three starts, 1400×880 pixels at 2×,
100.00% black, one colour. Steam's `cef_log.txt` says why: `GPU process exited unexpectedly:
exit_code=-1073741819` three times per webhelper, Steam restarting the webhelper once, then
`Disabling GPU acceleration: Disabled/CrashCount` and a SwiftShader GPU process compositing in
software, into the same black.

**Who owns what.** `WINEDEBUG=+pid,+win` shows the browser process of steamwebhelper creating
every window the client shows: an `SDL_app` top-level, a `CefBrowserWindow` inside it, a
`Chrome_WidgetWin_1` inside that (700×440, the compositor's target) and a
`Chrome_RenderWidgetHostHWND`. The GPU process, `steamwebhelper.exe --type=gpu-process`, creates
no window at all, and `steam.exe` holds only its bootstrap and tray helpers. The swapchain is
therefore asked for by one process on a window another process owns.

**Where it died.** On the `macdrv_d3dmtl` channel the GPU process makes exactly one hook call,
`get_win_data 0x…`, and the next line is `c0000005` reading address `0x18`, repeated 255 times as
the crash handler re-faulted. winemac.drv keeps its window records per process, so
`get_win_data` returned NULL for the browser's window; `0x18` is `client_cocoa_view` in the
record D3DMetal expects; and `vmmap` on a live GPU process put the faulting `rip` inside
`libd3dshared.dylib`, whose `WineSwapchainCallbacks::InitializeForHWND` reads that field
straight after the call — `movq 0x18(%rcx), %rcx`, with no check for NULL. The 254 faults after
the first are `RtlVirtualUnwind2` writing to a NULL out-parameter while unwinding through the
shim's unix-side frame: Wine cannot dispatch an exception raised inside a dylib the PE side
called into, so crashpad never writes its dump and the process exits with the exception code.

**No flag reaches it.** The `--use-gl=angle --use-angle=vulkan --in-process-gpu` the title had
been given are consumed by `steam.exe` and never appear on the webhelper's command line;
`webhelper.txt` prints that line. Steam's own switches live in `steamclient64.dll`, not
`steam.exe` — `strings` on the exe finds seven and misleads — and this build has 45 `-cef-*`
options. What each relevant one did, 45 seconds per start, window captured by id:

| start | GPU process | the window |
|---|---|---|
| no arguments | dies at the first window, three times, then software | 100% black |
| `-cef-use-vulkan` | lives; 320 frames on MoltenVK | 100% black: `macdrv_client_surface_update` finds no record for the top-level and never attaches the view. This route has a different shape from D3D11's: `+win` shows ANGLE's Vulkan backend making the GPU process create a child window of its own (`Chrome_WidgetWin_0`, plus an `ANGLE DisplayVkWin32 … Intermediate Window Class`), which the browser then re-parents into its tree with three `WM_WINE_SETPARENT`. The swapchain is on a window this process owns under a root it does not, and the patches below do not host that case |
| `-cef-disable-gpu-compositing` | lives; rasterises on D3DMetal, composites in software | 100% black: the GPU process draws into the browser's window with GDI, and win32u gives a DC on another process's top-level no surface (`dce.c`). The browser flushed its own surface twice in 45 s and never called `UpdateLayeredWindow` |
| `-cef-disable-gpu` | lives; SwiftShader | black, the same path |
| `-cef-disable-browser-underlays`, `D3DM_NO_WINDOW=1` | no change | no change |

`-cef-in-process-gpu` and `-cef-single-process`, which would have made this one process the way
`--in-process-gpu` does for Battle.net, are no longer in the binary.

**The fix is in the driver**, as four patches in `patches/`, each with its history in its
header. Upstream Wine's `52e03c61` and `1a63b0d7` (both by CodeWeavers, merged for wine-11.11)
give a process a Metal swapchain for a top-level window another process owns: the layer is
exported through a `CAContext` and the owner hosts it in its window with a `CALayerHost`. The
reference implementation attached to Wine bug 60263 takes that to child windows, posting the
context to the child's root and keeping the hosted layer at the child's rectangle. sake's own
change is to `d3dmetal.c`: D3DMetal's `get_win_data` for a window this process does not own now
gets a record whose view leads to that hosted swapchain, where it used to get NULL. The view has
to be a real `NSView`: the first attempt handed D3DMetal the client surface itself and it died
in `objc_msgSend_stret`, asking that pointer for its bounds — the patch header has the register
dump.

**On the rebuilt engine a start with no arguments works.** No `c0000005` in any process. The GPU
process makes all six glue calls and they read, on `+macdrv_d3dmtl`, `get_win_data 0x20112` →
`remote_win_data window 0x20112 of another process: view … rect (0,0)-(700,440)` →
`create_metal_device` → `view_create_metal_view … hosted swapchain …, view …` →
`view_get_metal_layer` → `release_win_data`; `+msg` shows it posting message `80001002` to the
browser's root, and the browser logs `WM_MACDRV_CREATE_REMOTE_LAYER child 0x20112 context_id
706998962` on receipt. Steam's GPU report stays `ANGLE_D3D11` with `gpu_compositing: enabled`,
one GPU process for the whole run. The window, 45 seconds in: 0.00% black over 1400×880 pixels,
142 colours in a sample, and the sign-in form — logo, account name, password, Sign in, the QR
code — legible in the capture. Thirty seconds in it was 630×397 with the desktop showing
through, so the first frame arrives some seconds after the layer host does. A window hosting
another process's layer cannot be captured by id, so this one was photographed another way
([debugging.md](debugging.md#looking-from-the-mac-side)).

The Vulkan route (`-cef-use-vulkan`) is still black on the rebuilt engine, for the reason in the
table: its swapchain is on a window the GPU process owns under a root it does not, and nothing
hosts that shape yet.

**The client then signed in, and a game ran**: an account was taken, the library came up, and
Stardew Valley installed through it and played. Nothing traced that run, and the measurements
above stop at the sign-in form (the owner's report, 2026-09-20).

## GDK titles: WinHTTP options XCurl cannot do without

**`patches/0007` and `0008` accept two WinHTTP options Wine 11.0 does not know; without them a
GDK title's HTTP client drops a request before sending it.** XCurl, the GDK's HTTP client, runs
over WinHTTP and abandons a request when an option it sets is refused, so `LoginWithSteam` never
reaches PlayFab and Minecraft Dungeons II shows LOG IN FAILED, error 0063.

*Measured in sake on 2026-09-29 in the `ex` bottle, with Minecraft Dungeons II started through
Steam. The title needs Xbox Gaming Services, which Wine does not have, so a community stand-in
DLL was in its place throughout.*

**Two of the options XCurl sets do not exist in Wine 11.0.** The options at the eleven
`WinHttpSetOption` call sites in `XCurl.dll`, read with the engine toolchain's `llvm-objdump`,
were set one at a time from a small exe against CrossOver 26.3.0's WinHTTP, with no request
sent. Two fail, both with `ERROR_WINHTTP_INVALID_OPTION` (12009), because `session.c` has no case
for either: `WINHTTP_OPTION_IPV6_FAST_FALLBACK` (140), set on the session, and
`WINHTTP_OPTION_DECOMPRESSION` (118), set on each request as soon as it is opened.

**A refusal ends the request before it is sent.** For 118, XCurl reads the error and abandons
the request. Refusing 140 alone does the same: with the stand-in's own answer to it removed and
118 still answered, the game showed the same error, and the stand-in logged 140 refused 25 times
and not one connection made.

**Upstream stubbed both, and sake carries the two commits** until CrossOver's sources contain
them: `patches/0007` is Paul Gofman's for 118, from wine-11.4, and `patches/0008` is Hans
Leidekker's for 140, from wine-11.7. Each accepts the option, prints a `FIXME` and does nothing
else. For 118 that is enough, because the `Accept-Encoding` header is WinHTTP's to add —
`XCurl.dll` holds no such string, in ASCII or UTF-16 — so nothing asks the server to compress.
wine-11.5 replaced the 118 stub with real gzip and deflate support, which sake does not carry.

**How to tell it worked.** The same exe on the patched engine gets `TRUE` for both, and with
`WINEDEBUG` at its default prints the two lines below, where the unpatched engine printed
`unimplemented option 140` and `unimplemented option 118`:

```
fixme:winhttp:session_set_option WINHTTP_OPTION_IPV6_FAST_FALLBACK: 1
fixme:winhttp:set_option WINHTTP_OPTION_DECOMPRESSION, 0x3 stub.
```

sake starts titles with `WINEDEBUG=-all`, so a title's log never shows them; the tell in the
game is the sign-in going through with both of the stand-in's hooks removed, which it did on the
rebuilt engine: Microsoft's sign-in, then `LoginWithSteam`, then character select, with every
reply the stand-in logged, 20 of them, a 200 and no option refused.

## A bottle on exFAT: the `._` files macOS writes are not the game's

**`patches/0009` leaves macOS's AppleDouble files out of a directory listing** when the file each
belongs to is beside it and the volume has no native extended attributes. Without it a game on
such a disk can read one as its own file: Minecraft Dungeons II read one as its settings and
reset them on every launch, with the community stand-in and with sake's own runtime alike. A
`._` file on APFS, or one with nothing beside it, is still listed, and a name asked for exactly
is still found.

*Measured in sake on 2026-09-30 in the `ex` bottle, a symlink into a directory on an exFAT disk,
with Minecraft Dungeons II started through Steam.*

**macOS writes a second file beside nearly every file there.** exFAT cannot store extended
attributes itself — `getattrlist` reports `VOL_CAP_INT_EXTENDED_ATTR` unset for that disk and
set for the internal APFS volume — so macOS keeps a file's attributes in a 4096-byte AppleDouble
file named `._` and the file's own name. On this Mac a file is given one as soon as it is
written, because it is given `com.apple.provenance`: the game's saves were, and so was a file
written from a shell. The bottle held 6,259 of them. Wine lists these as ordinary files, marked
hidden because their names start with a dot, and its sorted listing puts each before the file it
belongs to.

**The game read one as its settings.** It lists `Saved\SaveGames\*.*`, opened
`._GlobalSaveDataDefault.sav`, read its 4096 bytes and never opened `GlobalSaveDataDefault.sav` at
all. It then showed SETTINGS FILE DAMAGED and sent the person through the initial setup again,
although the file it had written is sound: JSON with every byte one lower. With the five
companions in `SaveGames` removed by hand, the same file loaded and the game went straight to
play; its next save brought all five back. Steam's client in that bottle had been syncing
`._sharedconfig.vdf` to Steam Cloud as one of its configuration files: its `logs/cloud_log.txt`
reports it in sync nine times before the patch.

**How to tell it worked.** `WINEDEBUG=+file` prints `leaving out` and the name for each file left
out, and the listing after it holds none of them. On the rebuilt engine, with the five
companions back on disk, the game's listing of `SaveGames` left them out and returned the five
saves, it read `GlobalSaveDataDefault.sav`, and it started with no dialog. Steam's next sync
named `sharedconfig.vdf` alone and found nothing to download. In `wine cmd /c dir`, a `._` file
with nothing beside it on the exFAT disk and a `._` file on APFS were both listed, and
`rmdir /s /q` removed an exFAT directory holding two companions it had not been shown, since
macOS removes a companion with its file. Starting `cmd` in that bottle left out 854 names.

Not measured: FAT and SMB volumes, which macOS treats the same way when they lack native
extended attributes, and whether Steam ever removes the copy of `._sharedconfig.vdf` its cloud
still holds.

## Taking a bottle down

**`Bottle.takeDown` is the whole sequence: `wineserver -k`, then `SIGTERM` to whatever is still
in the prefix, then `SIGKILL`, then a count once more, and what is left is what gets reported**
rather than an assumption of success. Stopping the `wine` sake started is not enough:
`Agent.exe` runs with ppid 1, wineserver is its own daemon, and Battle.net keeps a fistful of
CEF helpers (prototype). `wineserver -k` alone leaves the prefix's own services running, `ps`
cannot say which prefix a process belongs to, and the directory wineserver keeps its socket in
can.

**`wineserver -k` leaves the prefix's own services behind.** A title was started from the
library and stopped again: `wineserver -k` took down the game and the server, and then these
seven were still there, all reparented to ppid 1 (sake, 2026-09-20):

```
services.exe   winedevice.exe ×2   plugplay.exe
svchost.exe -k LocalServiceNetworkRestricted   explorer.exe /desktop   rpcss.exe
```

They stayed for the rest of the session. Because the app had started them, macOS kept its
LaunchServices record alive as `exited-with-subordinates`, so **the Dock went on showing a
running sake for an app that had already quit**, which is how this was noticed at all. Six of
the seven took `SIGTERM`; one `winedevice.exe` needed `SIGKILL`.

**A disk image sake mounted does the same, and lasts longer.** Its `diskimages-helper` keeps
running with ppid 1, macOS counts that helper as a subordinate of the app that mounted it, and
the app's LaunchServices record therefore stays at `exited-with-subordinates`, so the Dock shows
a running sake for an app that quit hours ago, across every launch since. The Game Porting
Toolkit's evaluation-environment image, mounted by the D3DMetal step at 12:27, was still mounted
at 13:30; ejecting it took the helper with it, and the tile left the Dock in the same second
(sake, 2026-09-20). `D3DMetalInstaller` unmounts what it mounts
([licensing.md](licensing.md#what-sake-actually-does)).

**Which prefix a process belongs to is in the socket directory.** `ps` is no help: these spell
themselves `C:\windows\system32\services.exe` and carry neither the engine's path nor the game's
name, so a sweep looking for those two reports success with seven processes up. That was sake's
bug, not just a gap in diagnosis. What does answer it is where wineserver keeps its socket:

```
/tmp/.wine-<uid>/server-<dev>-<inode>       both halves in hex
bottle  dev=16777234 → 1000012   inode=141967053 → 8763ecd
actual  /tmp/.wine-502/server-1000012-8763ecd
```

The two halves are the **prefix directory's own `st_dev` and `st_ino`**, confirmed against a
live bottle, and `lsof -t +D <that directory>` returned exactly those seven pids and nothing
else: the clients hold the server's `tmpmap-*` shared memory open, so they are still found
**after the server itself is gone** (sake, 2026-09-20). An inode does not change when a
directory is renamed, so this identifies a bottle's processes across a rename; and it is per
prefix, so nothing here can reach a CrossOver bottle or another of sake's.

**A bottle that is a symlink is named by what the link points at.** Wine `chdir`s into
`WINEPREFIX` and stats `.`, in ntdll and wineserver alike (read in CrossOver 26.3.0's
sources, 2026-10-01), while `FileManager.attributesOfItem` describes a link itself, so
reading the bottle's own path with it names a directory that never exists. In the `ex`
bottle, a link to a directory on an exFAT disk, the link is `1000012-8fa3a84` and the
server's directory `server-1000016-116a1`. Through the link's own inode, Stop killed
wineserver and left nineteen processes running with ppid 1 (sake, 2026-09-29); through its
target, the sequence Stop runs found eighteen there with Steam up, wineserver and seven
`steamwebhelper.exe` among them, and left none (sake, 2026-10-01).
