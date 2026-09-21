# Running games: the settings, the patches, and how to tell failures apart

A built Wine is not a working one. This is what the d4-mac prototype needed on top of the
build to get Diablo IV from "starts" to "plays", verified 2026-09-17 and 2026-09-18 on one
machine. **sake now creates prefixes and starts the Battle.net client in one**, dated in
the sections below, and it builds the file layout D3DMetal needs. No game has been started,
so everything from the Play button onwards is still the prototype's.

## Creating a prefix

`wine wineboot --init` makes it, and `wineserver -w` is where it finishes — Wine's processes
outlive the command that started them, so returning from wineboot is not the end.

**`WINEDLLOVERRIDES="mscoree,mshtml=d"`, or wineboot never returns.** Without it wineboot
puts up the Wine Mono installer's dialog and waits for a click that never comes: 0% CPU
inside `CFRunLoopRun` → `mach_msg` forever, and `syswow64` is never populated. (Prototype,
2026-09-17.)

**An empty `syswow64` is the one check worth making.** It means WoW64 did not initialise, so
no 32-bit application will run — and Battle.net's launcher is 32-bit. Everything else about
the prefix looks finished when this is what happened.

**Turn the crash dialog off before anything can crash**: `ShowCrashDialog=0` under
`HKCU\Software\Wine\WineDbg`. Otherwise a crash spawns `winedbg --auto`, which puts up a
dialog and holds the process until somebody clicks Close — an unattended command just blocks
until it times out — and resets `WINEDEBUG` on the way, so suppressed logging comes roaring
back into whatever was being debugged. (Prototype, 2026-09-18.)

Both halves of that showed up in sake on 2026-09-19. With the value set, a run whose render
process kept hitting a breakpoint carried on unattended instead of stopping on a dialog —
and `winedbg --auto` still ran and symbolised, spilling 880 lines of `dbghelp_dwarf` fixmes
into a run made with `WINEDEBUG=-all`.

sake created its first bottle on 2026-09-19 (Apple M5, macOS 27.0, against the engine built
the same day). What that cost and what came out:

| | |
|---|---|
| `wineboot --init` | 17.2 s, first run, nothing warm |
| `wineserver -w`, the registry write, shutdown | 4.0 s |
| the bottle | 997 MB, 801 files in `system32` and 841 in `syswow64` |
| everything Wine printed | MoltenVK's three-line banner. No `err:`, no `fixme:`, nothing else |

Two things in a fresh bottle that a path in this document may not lead you to expect:

- **The Windows user is `crossover`,** not the account's short name — `drive_c/users/crossover`.
  CrossOver's tree does this, and the prototype's bottle has the same directory, so every
  `drive_c/users/<user>/…` path below means that one.
- **`dosdevices` maps whatever was mounted at the time.** A bottle created while Apple's
  Game Porting Toolkit is still mounted gets a `d:` pointing into `/Volumes`, which dangles
  as soon as it is ejected. Harmless, and worth recognising rather than debugging.

## Three settings carry the whole thing

None is on by default, and no symptom resembles its cause.

**Two of the three are sake's to apply and one is not.** `WINE_SIMULATE_WRITECOPY` and
`CX_APPLEGPTK_LIBD3DSHARED_PATH` are environment, so `Bottle.environment` puts them on
everything the engine runs. `--in-process-gpu` and the two ANGLE flags beside it are
**Chromium's**, and mean something only to a program built on CEF — putting them on a game
that reads its own `argv` is not free. sake therefore offers them when it can see it is
dealing with a Chromium app, and otherwise leaves the arguments empty.

What it looks for is `libcef.dll`, **beside the program or one directory below it**.
Measured against a real Battle.net install on 2026-09-20: the exe is
`Battle.net/Battle.net.exe` and its CEF build is `Battle.net/Battle.net.17821/libcef.dll`,
so looking only beside the program finds nothing and the flags would never be offered for
the one title that is known to need them.

**Those three flags are Battle.net's, not Chromium's in general.** Steam's client, the second
Chromium app through sake (2026-09-20), takes none of them: `steam.exe` consumes whatever it
is given and passes nothing through to `steamwebhelper.exe`, and Steam's own switch list has
no in-process-GPU option left. Its `libcef.dll` also sits three directories down, so the
heuristic never offers them for it — correctly, as it turns out. What Steam needed was in
the driver, not in the arguments; the section on Steam below has the measurement.

### `WINE_SIMULATE_WRITECOPY=1` — or Battle.net never fetches the login page

CodeWeavers' `CW Hack 22996`. With it, a page that has been `VirtualProtect`ed away from
`PAGE_WRITECOPY` is reported as already copied, which is what Windows does.

Without it, every CEF render process executes an `int3` within five seconds of starting,
always at the same address; `UAuth: begin loading` never appears and the login page is never
even requested. CodeWeavers told Battle.net users to set this by hand in 2023 and it is
still not automatic.

sake measured that on 2026-09-19 by starting the client twice with nothing different but
this variable:

| | with it | without it |
|---|---|---|
| `wine: Unhandled exception 0x80000003` | none in 75 s | 11 in 60 s, every one at `6B0300E1` |
| `UAuth: begin loading` | present, then `finished loading. statusCode=200 state=Login` | never appears |
| `Battle.net.exe` processes | 4 | 3 |

`0x80000003` is `STATUS_BREAKPOINT`, which is the `int3`, and the first arrives nine seconds
in and then one every five seconds after it. Same bottle, same arguments, same other three
variables: this one line is the difference between a login page and a breakpoint.

### `--in-process-gpu` — or the login form is drawn but never shown

With a separate GPU process the login web view never gets a compositor surface of its own.
MoltenVK reports swapchains for the window (348x646) and the chrome strip (348x50) but never
one the size of the page content (348x558); the view stays black while the renderer paints
the form perfectly. Folding the GPU into the browser process makes the content surface
appear.

This is not a graphics setting in disguise. Turning off Battle.net's own browser hardware
acceleration changes nothing, `--disable-direct-composition` changes nothing, and fonts are
not involved.

Battle.net also needs `--use-gl=angle --use-angle=vulkan`. Left alone, ANGLE tries its D3D11
backend (which gets nothing — D3DMetal has no 32-bit half), then SwANGLE, then gives up with
"GL is disabled" and the GPU process exits with `ACCESS_VIOLATION`.

### `CX_APPLEGPTK_LIBD3DSHARED_PATH` — or Diablo IV does not start at all

Apple's `libd3dshared.dylib` exports `register_non_native_code_region`, which is how Rosetta
is told a region of memory holds dynamically generated x86_64 code. Wine only looks that
symbol up when this variable points at the library (`init_non_native_support()` in
`dlls/ntdll/unix/loader.c`). CrossOver's launcher sets it on every run; nothing else does.

Blizzard's protected loader `diablo_iv_loader.dll` generates code at runtime and drives it
with fibers plus `SetThreadContext` on other threads. Without the registration the fiber
switch does not return where the loader expects, its scheduler loop re-enters, and it
deadlocks re-acquiring its own non-recursive SRW lock. What you see is 0.0% CPU, 122 MB
resident, nine threads, no window, and **not one byte** in the game's own
`_FenrisDebug-*.txt`. Nothing in that picture points at Rosetta.

The 32-bit client is structurally unaffected: `pe_module_loaded()` reaches
`init_non_native_support()` only on the 64-bit side, because the WoW64 entry point
`wow64_pe_module_loaded()` is a stub returning `STATUS_NOT_IMPLEMENTED`.

**Also place `libd3dshared.dylib` in the same directory as `D3DMetal.framework`.**
`d3d12.so` declares `LC_RPATH = @loader_path` and looks for `libd3dshared.dylib` beside
itself; `libd3dshared` then `dlopen`s `@rpath/D3DMetal.framework/D3DMetal` relative to *its*
own location. Copying only `libd3dshared` next to the `.so` files breaks it.

sake does this on 2026-09-19: it copies `libd3dshared.dylib` into
`lib/wine/x86_64-unix/` and puts a `D3DMetal.framework` symlink beside it pointing at
`../../external/D3DMetal.framework`, then refuses to call the install done unless
`lib/wine/x86_64-unix/D3DMetal.framework/D3DMetal` resolves. The engine that comes out has
`d3d12.so` linking `@rpath/libd3dshared.dylib` and that symlink landing on a real x86_64
Mach-O. **Nothing has been run against it.**

### Everything else belongs to one title

The three above are sake's, and `Bottle.environment` puts them on everything the engine
runs. Anything else is one title's business, and since 2026-09-21 a title carries its own
`KEY=VALUE` pairs. They go in underneath the bottle's, which is composed afterwards, so the
five names `Bottle.environment` writes — `WINEPREFIX`, `WINEDLLOVERRIDES`, `WINEDEBUG`,
`WINE_SIMULATE_WRITECOPY` and `CX_APPLEGPTK_LIBD3DSHARED_PATH` — win. The sheet refuses
those by name rather than accepting a value it would then quietly ignore, because a run that
behaves as though a variable had been set is the worse of the two failures.

**`MTL_HUD_ENABLED=1` draws Metal's performance HUD, and D3DMetal adds a section of its
own to it.** The HUD belongs to the OS, so anything rendering through Metal can show it;
what makes it worth knowing here is that block. Measured in Diablo IV on sake's own
engine, 2026-09-21: above an FPS and GPU-time graph the HUD names the translation
`D3D12 (Metal 4)` and the process `x86_64`, and below it lists
`Game Porting Toolkit 4.0b2` with Dispatch, Draw, Clear Resource, Copy Resource and
ExecuteIndirect counts. It is the cheapest look at what D3DMetal is doing per frame, and
it costs no trace.

The prototype lists this variable among the ones that made no difference. That is about
the hang it was tested against, not about the HUD: it did not fix the hang, and it does
draw.

## Starting a title

From the game's own directory, by its bare leaf name, with the title's arguments. sake did
this for the first time on 2026-09-19; a healthy Battle.net run looks like this in
`ps -Ao pid=,args=`:

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

- **`wine` turns a relative name into `start.exe /exec`.** sake's own launch therefore
  appears as `start.exe`, never as the game. That is precisely the case the "cut `argv[0]`
  at its first `.exe`" rule exists for, and it drops out as intended.
- **wineserver does not spell itself `<engine>/bin/wineserver`.** `ps` shows
  `<engine>/lib/wine/../../bin/wineserver`. A teardown check matching the tidy path matches
  nothing and so reports success every time — sake's first version did exactly that, and
  only a real run showed it.
- **`--in-process-gpu` does not mean one process.** It folds the GPU into the browser
  process; the renderer and the two utility processes remain their own. Four
  `Battle.net.exe` is what a healthy run has.

What the client's own logs said on that run is the evidence the settings above did their
job: `libcef-*.log` held two `WSALookupServiceBegin failed` lines and nothing else — no GPU
errors, no "GL is disabled" — and `battle.net-*.log` ended
`UAuth: finished loading. statusCode=200 state=Login`.

**Nobody looked at the screen.** This was measured without screen access, so "the login form
is visible" is not claimed. What is claimed is that the page was requested, came back 200,
and the renderer that draws it was still alive seventy-five seconds later.

## Two patches to ntdll

sake carries six patches in `patches/`, all LGPL-2.1-or-later because all are derivatives of
Wine. The two in ntdll are this section's; they came from the prototype unchanged and go in
before configure. The four in winemac.drv arrived with Steam on 2026-09-20 and are in the
Steam section below. The build side of patching is in `wine-build.md` and the licence side in
`licensing.md`.

**sake measured both on 2026-09-19**, against its own engine and bottle, the day it started
carrying them. The prototype's numbers are kept beside sake's because they are the
before-the-patch half, and sake has not reproduced that half — its engine has never been
built without them.

**Resolve `libd3dshared` from `dll_dir` when the variable is unset.** A process whose
environment was composed by an application never inherits the variable. The prototype
measured, with the variable removed: before the patch 122 MB at 0.0% CPU with nine threads
(deadlocked), after it 2561 MB at 38.6% CPU with 84 threads (running). The variable still
wins when set.

sake's own measurement looks at what is mapped rather than at CPU. With the variable removed
from the environment, Diablo IV came up at 83 threads and 2534 MB with
`<engine>/lib/external/libd3dshared.dylib` mapped into it, seven regions. An unpatched ntdll
returns before that `dlopen` when the variable is unset, so the library being in the process
at all is the patch and nothing else.

**`vmmap` is how to check this, not `WINEDEBUG=+module`.** The two `TRACE`s in
`init_non_native_support` only run once something calls `pe_module_loaded`, which a
`wine cmd /c exit` never does — and during a real game start they did not reach a filter on
wine's own stderr either. Two attempts went that way before the mapping was looked at
instead, which took one command.

**Read `BOOLEAN` syscall arguments as the Windows ABI defines them.** This is the one that
made the Play button work, and it is worth understanding before touching ntdll.

Since Diablo IV 3.1.0 (2026-06-30) the loader inspects the process that started it, when
that process is still alive — and `Agent.exe` always is. It opens the parent, reads its
image path, and walks `\DosDevices` one entry at a time with `NtQueryDirectoryObject` to
build a drive-letter-to-device map. CrossOver's build asks for index 0, 1, 2 … 48 and
finishes. The prototype's asked for **index 0 on every call, ~55,000 times a second,
forever** — its `+server` log grew at 17 MB/s, which is how the loop was found.

`WINEDEBUG=+syscall` showed the fifth argument, `RestartScan`, a stack-passed `BOOLEAN`:

| build | `restart` argument word |
|---|---|
| the prototype | `6c006200610000` — UTF-16 `abl`, leftover from a path string |
| CrossOver | `00000000` |

The low byte is FALSE in both. The Windows x64 ABI leaves the upper bits of a narrow
argument undefined and MSVC stores exactly one byte, so the caller is within its rights.
`__wine_syscall_dispatcher` copies the whole 8-byte word into the SysV register, and the
clang-built unix side assumes — as the SysV ABI permits — that a narrow parameter arrives
zero-extended, compiling the test to `testl %r8d, %r8d`. Non-zero garbage above the low byte
therefore reads as TRUE and the enumeration restarts forever.

The fix adds an empty asm barrier that makes the compiler forget the zero-extension
assumption, and applies it to both `BOOLEAN` parameters of `NtQueryDirectoryObject` only,
because that is the call that was measured. **The same exposure exists in
`NtQueryDirectoryFile`, `NtQueryEaFile`, `NtSetTimer`, `NtLockFile`,
`NtNotifyChangeDirectoryFile`, `NtNotifyChangeKey` and `NtCreateEvent`** — Wine's own PE DLLs
are their usual callers and keep the slot clean, so nothing has been seen to need it.

Two things this is *not*:

- **Not a CrossOver-only correctness win.** CrossOver's `ntdll.so` has the identical
  `testl %r8d, %r8d`. It passes because its GCC/binutils-built PE DLLs leave zeros in that
  slot. That reading is inference, not measurement; what was measured is the zero in their
  trace and the string in ours. Either way it is a latent bug in every clang-built Wine.
- **Not Valve's Proton Hotfix.** ValveSoftware/Proton #9926 is a different failure on Linux
  (an exit on a breakpoint before any renderer init). A GCC-built unix side cannot hit this
  bug.

sake measured this one with the prototype's probe shape — `start.exe /exec` keeps a Windows
parent alive exactly as `Agent.exe` does, which reproduces the check in half a minute with
no client and no mouse. Against sake's own engine and bottle: peak 92 threads, 1982 MB, 103
Metal/AGX mappings, still alive when the sampling ended. The stall this replaces sits flat
at 12-13 threads and 235-245 MB for as long as anyone cares to watch, so there is no reading
of those numbers that confuses the two.

**That is the check cleared, not the button pressed.** Nobody has pressed Play on sake's
build; what has been shown is that the thing the button trips over no longer stalls.

## SSO: pressing Play does two separable things

1. **The client becomes willing to hand out a token.** Launching the game directly without a
   press earlier in the same client session gets it all the way up — rendering, intro
   playing — and then `Aurora has rejected the token`, *"There was a problem logging in.
   (Code 7)"*. Measured in one session: manual launch at 02:13 got Code 7, Play pressed at
   02:48, manual launch at 02:52 logged in and reached character select.
2. **`Agent.exe` starts the game.** This is the part the BOOLEAN bug broke.

The client logs `Pre-existing game session detected without a pending launch` for every
manual start **including the ones that log in perfectly**, so that message says nothing
about the token.

Implication for sake: a "launch the game directly" button cannot work for this title on its
own. The launcher's own flow has to be driven at least once per session.

## Controllers need SDL2

`winebus.sys` has two backends. **IOHID** is built either way and handles anything behaving
as a plain HID gamepad. **SDL** is compiled in only if configure found SDL2, and it is the
one that knows device-specific protocols.

A Nintendo Switch Pro Controller needs the second: it enumerates as a HID device with a
reasonable descriptor and then sends **no input reports at all** until it has been through
Nintendo's handshake, which lives in SDL's HIDAPI driver. An IOHID-only build gives a
controller that is plugged in, visible to macOS, and completely dead in the game.

Verified by playing the game with a Switch Pro Controller over USB, 2026-09-17. Bluetooth
and other pads are untested.

**The same controller and cable played Diablo IV through sake on 2026-09-20.** Reported by
the owner, not instrumented — there is no log of that run. What it settles is that the SDL2
requirement above carries over to sake's own engine and bottle; it is not new evidence about
the driver.

Use SDL2 newer than CrossOver's 2.30.12: 2.32.2 fixed a crash initialising with controllers
already connected on macOS, 2.32.6 fixed reliability of initializing Switch controllers on
macOS, and 2.32.10 fixed thumbstick range and calibration for Switch Pro Controllers by
name. If a pad misbehaves, 2.30.12 is the version known-good under CrossOver and the right
thing to bisect against. Not SDL3 — Wine looks for pkg-config's `sdl2` and `SDL_Init` in
`libSDL2-2.0*`.

## Steam: the client draws in one process and owns its window in another

Measured in sake on 2026-09-20 against the default bottle, with Steam's 64-bit client (build
1788652215) installed through the app and the engine built from CrossOver 26.3.0's sources
with D3DMetal 4.0b2: thirteen starts, seven of them traced, six windows photographed.
Everything in this section is sake's own measurement.

**What a start looked like.** The client comes up as a 700×440 window called "Sign in to
Steam" that is black to the last pixel — captured by window id on three starts, 1400×880
pixels at 2×, 100.00% black, one colour. Steam's `cef_log.txt` says why: `GPU process exited
unexpectedly: exit_code=-1073741819` three times per webhelper, Steam restarting the webhelper
once, then `Disabling GPU acceleration: Disabled/CrashCount` and a SwiftShader GPU process
compositing in software, into the same black.

**Who owns what.** `WINEDEBUG=+pid,+win` shows the browser process of steamwebhelper creating
every window the client shows: an `SDL_app` top-level, a `CefBrowserWindow` inside it, a
`Chrome_WidgetWin_1` inside that (700×440, the compositor's target) and a
`Chrome_RenderWidgetHostHWND`. The GPU process, `steamwebhelper.exe --type=gpu-process`,
creates no window at all, and `steam.exe` holds only its bootstrap and tray helpers. The
swapchain is therefore asked for by one process on a window another process owns.

**Where it died.** On the `macdrv_d3dmtl` channel the GPU process makes exactly one hook call,
`get_win_data 0x…`, and the next line is `c0000005` reading address `0x18`, repeated 255
times as the crash handler re-faulted. winemac.drv keeps its window records per process, so
`get_win_data` returned NULL for the browser's window; `0x18` is `client_cocoa_view` in the
record D3DMetal expects; and `vmmap` on a live GPU process put the faulting `rip` inside
`libd3dshared.dylib`, whose `WineSwapchainCallbacks::InitializeForHWND` reads that field
straight after the call — `movq 0x18(%rcx), %rcx`, with no check for NULL. The 254 faults
after the first are `RtlVirtualUnwind2` writing to a NULL out-parameter while unwinding
through the shim's unix-side frame: Wine cannot dispatch an exception raised inside a dylib
the PE side called into, so crashpad never writes its dump and the process exits with the
exception code.

**No flag reaches it.** The `--use-gl=angle --use-angle=vulkan --in-process-gpu` the title
had been given are consumed by `steam.exe` and never appear on the webhelper's command line;
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

`-cef-in-process-gpu` and `-cef-single-process`, which would have made this one process the
way `--in-process-gpu` does for Battle.net, are no longer in the binary.

**The fix is in the driver**, as four patches in `patches/`, each with its history in its
header. Upstream Wine's `52e03c61` and `1a63b0d7` (both by CodeWeavers, merged for
wine-11.11) give a process a Metal swapchain for a top-level window another process owns:
the layer is exported through a `CAContext` and the owner hosts it in its window with a
`CALayerHost`. The reference implementation attached to Wine bug 60263 takes that to child
windows, posting the context to the child's root and keeping the hosted layer at the child's
rectangle. sake's own change is to `d3dmetal.c`: D3DMetal's `get_win_data` for a window this
process does not own now gets a record whose view leads to that hosted swapchain, where it
used to get NULL. The view has to be a real `NSView`: the first attempt handed D3DMetal the
client surface itself and it died in `objc_msgSend_stret`, asking that pointer for its
bounds — the patch header has the register dump.

**On the rebuilt engine, the same day, a start with no arguments works.** No `c0000005` in
any process. The GPU process makes all six glue calls and they read, on `+macdrv_d3dmtl`,
`get_win_data 0x20112` → `remote_win_data window 0x20112 of another process: view … rect
(0,0)-(700,440)` → `create_metal_device` → `view_create_metal_view … hosted swapchain …,
view …` → `view_get_metal_layer` → `release_win_data`; `+msg` shows it posting message
`80001002` to the browser's root, and the browser logs `WM_MACDRV_CREATE_REMOTE_LAYER child
0x20112 context_id 706998962` on receipt. Steam's GPU report stays `ANGLE_D3D11` with
`gpu_compositing: enabled`, one GPU process for the whole run. The window, 45 seconds in:
0.00% black over 1400×880 pixels, 142 colours in a sample, and the sign-in form — logo,
account name, password, Sign in, the QR code — legible in the capture. Thirty seconds in it
was 630×397 with the desktop showing through, so the first frame arrives some seconds after
the layer host does. Nobody had signed in yet when this was written.

One instrument changed with the fix: `screencapture -l <id>` on a window that hosts another
process's layer fails with "could not create image from window", where the black windows
captured fine. The capture above is a full-screen shot taken with the window raised for a
second and cropped to its bounds. The Vulkan route (`-cef-use-vulkan`) is still black on the
rebuilt engine, for the reason in the table: its swapchain is on a window the GPU process
owns under a root it does not, and nothing hosts that shape yet.

**Signed in, and a game ran, later the same day.** The client took an account, the library
came up, and Stardew Valley installed through it and played. Reported by the owner, not
instrumented: nothing traced that run, and the measurements above all stop at the sign-in
form. 2026-09-20.

## Killing wineserver leaves the prefix's own services running

**Measured in sake on 2026-09-20.** A title was started from the library and stopped again.
`wineserver -k` took down the game and the server, and then seven processes were still
there, all reparented to ppid 1:

```
services.exe   winedevice.exe ×2   plugplay.exe
svchost.exe -k LocalServiceNetworkRestricted   explorer.exe /desktop   rpcss.exe
```

They stayed for the rest of the session. Because they had been started by the app, macOS
kept the app's LaunchServices record alive as `exited-with-subordinates` — so **the Dock
went on showing a running sake for an app that had already quit**, which is how this was
noticed at all.

Six of the seven took `SIGTERM`; one `winedevice.exe` needed `SIGKILL`.

### A mounted disk image does the same thing, and lasts longer

The Wine processes above were found while chasing a Dock tile that would not go away, and
they turned out not to be the whole answer. **An image sake mounted keeps its
`diskimages-helper` running with ppid 1**, macOS counts that helper as a subordinate of the
app that mounted it, and the app's LaunchServices record therefore stays at
`exited-with-subordinates` — so the Dock shows a running sake for an app that quit hours
ago, across every launch since.

Measured 2026-09-20: the Game Porting Toolkit's evaluation-environment image had been
mounted by the D3DMetal step at 12:27 and was still mounted at 13:30. Ejecting it took the
helper with it and the tile disappeared from the Dock in the same second. `D3DMetalInstaller`
now unmounts what it mounts; `licensing.md` says why that was always the intention.

### Which prefix a process belongs to: the socket directory

`ps` is no help — these spell themselves `C:\windows\system32\services.exe` and carry
neither the engine's path nor the game's name, so a sweep looking for those two reports
success with seven processes up. That was sake's bug, not just a gap in diagnosis.

What does answer it is where wineserver keeps its socket:

```
/tmp/.wine-<uid>/server-<dev>-<inode>       both halves in hex
bottle  dev=16777234 → 1000012   inode=141967053 → 8763ecd
actual  /tmp/.wine-502/server-1000012-8763ecd
```

The two halves are the **prefix directory's own `st_dev` and `st_ino`**, confirmed against a
live bottle on 2026-09-20. `lsof -t +D <that directory>` returned exactly those seven pids
and nothing else — the clients hold the server's `tmpmap-*` shared memory open, so they are
still found **after the server itself is gone**.

Two things follow. An inode does not change when a directory is renamed, so this identifies
a bottle's processes across a rename. And it is per prefix, so nothing here can reach a
CrossOver bottle or another of sake's.

`Bottle.takeDown` is the whole sequence: `wineserver -k`, then whatever is still in the
prefix gets `SIGTERM`, then `SIGKILL`, then it is counted once more and **what is left is
what gets reported** rather than an assumption of success.

## Telling failure states apart

RSS alone misleads, and a hang and a slow start look nothing alike. Thread count separates
the top three states; `vmmap $pid | grep -icE 'Metal|AGX'` says whether graphics was ever
reached (~50 mappings means never, 100+ means rendering).

| state | threads | RSS | Metal/AGX maps |
|---|---|---|---|
| no Rosetta registration, or a mismatched-ABI module | 9-11 | 125-155 MB | ~50 |
| the `\DosDevices` loop (before the BOOLEAN fix) | 12 | 235-245 MB | ~50 |
| graphics up, waiting on the client | 17-19 | 390-410 MB | 74-81 |
| running and rendering | 83-98 | 1.7-4.6 GB | 100+ |

Four traps in that table, each of which produced a wrong conclusion in the prototype:

- **The running row kept being too narrow.** It read 83-90, then 83-96, then 83-98, widened
  each time someone measured again. Read it as "well past 40", not as a window to match.
- **The counts include the process row** (`ps -M -p $pid | tail -n +2 | grep -c .`). Count
  thread rows alone and everything reads one low — the stall comes out at 11, lands in the
  row above, and a reproducing hang gets reported as a dead build.
- **Threads do not separate the bottom two states.** 9-11 against 12 is one thread. RSS is
  what tells those apart: 125-155 MB against 235-245 MB.
- **Sample, do not read once at the end.** A build that clears the check and then dies of
  something unrelated looks identical to one that never cleared it, if you only look at the
  end. Keep the peak.

Identify the game's process by the `argv[0]` that *ends with* the executable name, not one
that contains it: a loose match also catches `cmd.exe`, `start.exe` or any launcher carrying
the name in its own arguments. That happened twice. Matching the bare name at the start is
not enough either, because `argv[0]` is spelled differently depending on how the game was
started. Cut `argv[0]` at its first `.exe` and check what that ends with.

## Diagnostic technique that paid off

- **Search before analysing.** The `WINE_SIMULATE_WRITECOPY` fix is documented across
  Lutris, GamingOnLinux and CodeWeavers' own forum. Hours of first-principles crash analysis
  went in before anyone searched. The lesson was then ignored on the Play button and the
  same bill arrived. Caveat learned the second time: the search found the *game update*, not
  the *cause*. **Search first, then measure.**
- **Diff against a working implementation on the same machine.** CrossOver is installed and
  this tree is built from *its* sources, so anything that differs is configuration or build
  flags. Running CrossOver's binaries against the prototype's bottle answered "build or
  bottle?" in one command. Its Perl `bin/wine` is readable and
  `--bottle NAME --ux-app /usr/bin/env` dumps the environment its launcher builds — bisect
  the environment from the side that works, rather than guessing single variables against a
  failing run.
- **Make the two candidates produce different observable output before believing either.**
  The Play button was blamed on `Agent.exe` not passing an environment variable. The
  variable arrives. The diagnosis stood because the symptom it predicted was the symptom
  present.
- **Read the application's own logs first.** Battle.net writes
  `drive_c/users/<user>/AppData/Local/Battle.net/Logs/{battle.net,libcef}-*.log`, and the
  libcef log named the real problem after a lot of guessing had not.
- **`--remote-debugging-port=9222`** distinguishes "not painting" from "painting but not
  shown". Battle.net forwards unrecognised arguments to CEF. `Page.captureScreenshot` proved
  the renderer was drawing the login form perfectly while the window was black.
- **MoltenVK's `Created N swapchain images with size (W, H)` lines are a free instrument.**
  Comparing which surface sizes appear between runs exposed the missing content-sized
  surface and then confirmed the fix.
- **`WINEDEBUG=+loaddll` names the last DLL before a hang** and is safe on its own.
  `+server`, `+syscall`, `+module`, `+seh` and `+file` are light enough to keep a failure
  reproducing.
- **Wine keeps its sockets in `wineserver`**, not the Windows-side process. `lsof` against
  the Battle.net pid shows zero connections while it is talking to Blizzard happily. This
  produced three consecutive wrong network conclusions.
- **`wineserver -k` silently targets `~/.wine` unless `WINEPREFIX` is set**, exits 0, and
  reports success having killed nothing. It is the first half of taking a bottle down —
  `Agent.exe` runs with ppid 1, wineserver is its own daemon, and Battle.net keeps a
  fistful of CEF helpers — but **it is not the whole of it**, which is the next section.
- **`WINEDEBUG=err+all` causes crashes rather than revealing them.** A failed `dlopen` of a
  missing dylib produces a `dlerror()` string long enough to overflow Wine's debug buffer;
  the exception cannot be dispatched and the process dies. Raising the log level turns a
  cleanly handled failure into a crash.
- **A whole-module relay trace can hide the bug.** `RelayFromInclude` on the loader logs ~7M
  calls and the game then starts fine. That was read as timing sensitivity and it was not
  one — the overhead changes what callees leave on the stack. A Heisenbug is a limit on
  which instrument you may use, not evidence about the cause.
- **Attaching a debugger to Diablo IV is destructive.** The protected loader answers with an
  unhandled `0xc00000e5` and obfuscated registers, and the process drops from 58% CPU to
  1.8% — the state you came to read is gone. `sample(1)` is safe but cannot unwind through
  `__wine_syscall_dispatcher`.
- **Check that the control actually ran.** A control run whose log is zero bytes did not
  reproduce anything; it failed to start.
- **`WINEDEBUG=+pid` before anything else with more than one process.** Without it every
  trace prefix is a thread id, and four Chromium processes cannot be told apart. Learned on
  Steam, 2026-09-20.
- **`+macdrv_d3dmtl` is D3DMetal's half of the conversation.** It is the channel of the glue
  in `dlls/winemac.drv/d3dmetal.c`, the only code D3DMetal calls in Wine. A `get_win_data`
  with no `create_metal_device` after it means winemac returned NULL, and the six calls of a
  swapchain's creation read like a checklist.
- **`+win` names the owner of an HWND**, class and parent included, which is how "whose window
  is the GPU process drawing into" got answered.
- **A fault inside a dylib has no module name in `+seh`.** `vmmap` a live process for the
  `__TEXT` ranges of `libd3dshared`, `D3DMetal` and `winemac.so`, then `objdump -d` the dylib
  at `rip` minus its start; `+loaddll` only knows PE modules.
- **Crashpad eats the crash.** A CEF process never reaches `winedbg --auto`, so there is no
  backtrace to wait for; `+seh` is the only view of where it died.
- **A Wine window can be photographed even behind the terminal.** Once Screen Recording is
  granted to the terminal, `screencapture -x -o -l <CGWindowID>` captures an occluded window,
  and `CGWindowListCopyWindowInfo` gives the id (owner `wine`). A full-screen capture shows
  whatever is in front, which here is always the terminal. This is what turned "black" from a
  report into 100.00% of 1,232,000 pixels. **Not once the window hosts another process's
  layer**: then `-l` fails with "could not create image from window" and `-R` never worked
  here at all, so raise the window (`set frontmost of (first process whose unix id is …)`
  through System Events), take the full screen, crop to the window's bounds, and hand focus
  back to the terminal.
