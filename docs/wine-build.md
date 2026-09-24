# Building Wine from CrossOver's sources

What the build has to do, and which parts of it are not negotiable.

Everything here was learned in the d4-mac prototype between 2026-08 and 2026-09-17, on one
machine (Apple silicon, macOS 27.0), unless a section says otherwise. **sake produced the
nine components below and then built Wine itself on 2026-09-19** — configure, the soname
rewrite, make and install, 4m40s for Wine on ten cores, 1.1 GB of engine. Later the same day
it created a prefix with that engine and Wine came up clean, and later still a game started
in it; `runtime.md` has both. Treat anything not marked as sake's own measurement as the
specification the implementation has to satisfy rather than a report on its behaviour.

## Why CrossOver's sources and not upstream Wine

The piece that makes DirectX 12 work on macOS is Apple's closed **D3DMetal**, and the
Wine-side glue it plugs into lives in `dlls/winemac.drv/d3dmetal.c` and `d3dmetal_objc.m` —
about 512 lines of C and Objective-C that hand D3DMetal a `CAMetalLayer`. That glue is LGPL,
so CodeWeavers are obliged to publish it, and they do:
`crossover-sources-<version>.tar.gz`, ~149 MB. Upstream Wine does not have it.

The prototype used CrossOver 26.3.0 because that is the version demonstrably running the
game on the same machine. CodeWeavers keep several versions available, so the version is a
knob the GUI can expose.

## What has to be built before Wine

CrossOver's tarball bundles many dependencies **as sources**, which is not the same as
satisfying them — building the bundled glib needs meson, ninja and python, and gnutls needs
nettle, gmp and libtasn1, none of which are bundled. The short list that actually has to be
produced:

| component | why it cannot be skipped |
|---|---|
| llvm-mingw | the PE compiler. Universal binary, so it runs native or translated |
| bison ≥ 3.0 | `/usr/bin/bison` is 2.3 (2006) and configure rejects it |
| pkgconf | macOS ships no `pkg-config` at all |
| gmp, nettle, libtasn1 | static, underneath gnutls |
| gnutls | without TLS the Battle.net client cannot log in |
| freetype | no fonts at all without it |
| SDL2 | no game controller works without it — see `runtime.md` |
| MoltenVK | Chromium's GPU process dies with no Vulkan driver |

Notes that cost time to find:

- **mingw-w64's GCC is never needed.** llvm-mingw ships `x86_64-w64-mingw32-gcc` as a
  symlink to a clang wrapper, so Wine's configure matches its first-choice "gcc" name while
  the compiler is really LLVM. Apple's old Homebrew formula pulling in mingw-w64 is what
  made this look mandatory.
- **`sources/gnutls` in the tarball is an empty directory.** Several component directories
  ship empty. gnutls has to come from upstream.
- **freetype is present but unbuildable as shipped** — its `dlg` git submodule is missing and
  the Makefile runs `git submodule update` in a non-repository. The official release tarball
  of the same version already contains `src/dlg` and skips that path.
- **MoltenVK is Apache-2.0**, so the upstream Khronos release is used as-is. Rebuilding it
  would change nothing legally.
- The prototype ran newer gnutls, MoltenVK, SDL2 and D3DMetal than CrossOver ships, and that
  was deliberate, not drift.

## The patches go in before configure

`patches/` holds the changes sake makes to Wine's own code — seven of them as of 2026-09-23,
three in ntdll and four in winemac.drv, all LGPL-2.1-or-later rather than this repository's
MIT. Two of the four are upstream Wine commits carried only until the CrossOver sources sake
builds catch up with wine-11.11, one is the reference implementation attached to Wine bug
60263, and the rest are sake's own; each file's header says which it is and where it came
from. What each one is for, and how to tell that it worked, is in `runtime.md`; why they are
a separate directory is in `licensing.md`.

They are applied to the unpacked source tree, which is the only copy sake has of it, so the
build has one step that is not out of tree. Whether a patch is already in is asked of
`patch` itself — a patch that reverses cleanly is applied — rather than recorded in a marker
file, because the tarball is unpacked once and never re-extracted and a marker would have to
be invalidated by hand every time a patch changed.

**Patches on one file stack, and the check knows it.** Measured 2026-09-20, on the second
build after the four winemac.drv patches went in: 0003 no longer reversed on its own once
0004 and 0005 had changed the lines around it, did not apply forward either, and the build
stopped with "applies to neither" before configure. The two ntdll patches never showed this
because they touch different regions. So a patch that reverses on its own is taken as
applied and as the top of its stack; one that neither reverses nor applies is tried as the
bottom of a run: the files the run touches are copied to a temporary directory, the run is
reversed there from the top down, and if that succeeds the whole run counts as applied. The
tree itself only ever sees dry runs and forward applications. `PatchTests` carries the three
shapes a tree can be in when a build starts — pristine, an older version's prefix, and an
applied stack with a new patch on top — and the stack that does not reverse, which is still
the error it always was.

**A build with no patches is stopped rather than allowed.** Wine without them configures,
compiles, installs and passes every check in this document. What it cannot do is start a
game, and that is a long way downstream of here.

An engine that is already built does not pick a new patch up: `make install` is what writes
`bin/wine`, and its presence is what says the step is done. Changing a patch means deleting
that and rebuilding, and that is a full build rather than an incremental one: measured at
4m24s on 2026-09-19, no cheaper than the first.

## configure flags that must not be removed

- **`--enable-archs=i386,x86_64`.** Battle.net's launcher is 32-bit, so 32-bit support is not
  optional. `--enable-win32on64` (CrossOver 22, Apple's 2023 formula) no longer exists;
  Wine 11 uses upstream WoW64.
- **Do not pass `--without-vulkan` or `--without-gnutls`.** They do not compile:
  `dlls/win32u/vulkan.c` (marked `CW HACK 25909`) and `dlls/bcrypt/gnutls.c` reference
  `SONAME_LIBVULKAN` / `SONAME_LIBGNUTLS` with no `#ifdef` around them, because CodeWeavers
  always ship both.
- **Do not pass `--without-sdl`.** The prototype did, and the price was that no game
  controller worked at all, silently — `winebus.sys` still has its IOHID backend and still
  enumerates the device. The tell is `SONAME_LIBSDL2` sitting at `#undef` in `config.h`.
- **Do not pass `--without-unwind`.** configure calls it "do not use the libunwind library
  (exception handling)" and means it: `unwind_builtin_dll()` in
  `dlls/ntdll/unix/signal_x86_64.c` returns `STATUS_UNSUCCESSFUL` for any frame whose DWARF
  FDE cannot be found instead of falling back to libunwind. macOS needs no extra library —
  `unw_step` lives in libSystem, so `HAVE_LIBUNWIND` is defined with `UNWIND_LIBS` empty.
  (Correct on its own merits; it was **not** the fix for the Play button.)

Also: clang 16+ turned several legacy-C patterns into hard errors, so the build needs
`-Wno-implicit-function-declaration -Wno-format -Wno-deprecated-declarations
-Wno-incompatible-pointer-types`. Apple's own formula carried the same list. Apple's patched
clang is *not* required; the Mach-O side builds with stock Apple clang.

## Ordering traps

- **The build must produce x86_64 host tools**, because it generates and then executes them
  (winebuild, widl, wrc, makedep). The prototype got that by wrapping the *build* in
  `arch -x86_64`; with the Command Line Tools alone that route is closed — see below.
- **Never wrap a Wine *run* in `arch -x86_64`.** `arch` is a hardened system binary, so
  exec'ing it strips every `DYLD_*` variable. Wine's binaries are already x86_64, so Rosetta
  handles them anyway.
- **`make install` overwrites D3DMetal.** It puts Wine's own `d3d10`/`d3d11`/`d3d12`/`dxgi.dll`
  back, so installing D3DMetal has to happen *after* every `make install`, not once. sake keeps
  its own copy of Apple's `redist/lib`, so putting it back is one press and does not need the
  toolkit mounted again. Nothing re-runs it on its own; what the code does is stop claiming
  the step is finished, so the wizard sends the user there.

  This section used to say that deleting the whole engine was the only way to re-run `make
  install`, so D3DMetal went with it and the next install put it back. That is wrong.
  Measured in sake on 2026-09-19: deleting `engine/bin/wine` alone is enough to make the
  wizard rebuild, and afterwards all four DLLs were Wine's — while the D3DMetal step still
  read **"already installed"**, because it asked whether the framework was there and the
  framework is what `make install` does not touch. Silent, and the engine it left could not
  run a DX12 game.

  **`isInstalled` now asks whether the four DLLs are Apple's**, which is the question
  `verify()` had been asking all along, so a Wine rebuild drops the D3DMetal step back to
  unfinished and the wizard opens on it. Measured the same day, on the real engine and
  through the app: with one DLL swapped for Wine's own the wizard opened on D3DMetal and
  its row read "waiting", and one press put the engine back.
- **Sonames must not be leaf names.** A leaf name resolves only through
  `DYLD_LIBRARY_PATH`, and that does not reach Wine's child processes. sake rewrites the
  four in `include/config.h` to `@loader_path`-relative paths between configure and make;
  see `layout.md`.
- **Nothing x86_64 may exec an xcode-select shim.** `/usr/bin/clang`, `/usr/bin/m4` and
  their neighbours are universal shims that `dlopen` an arm64-only `libxcrun.dylib`, so
  started x86_64 they die. This bit in three unrelated places before it was recognised as one
  thing, and the three sections below are those three.

### The wrapping no longer works with the Command Line Tools alone

Measured in sake on 2026-09-19 (CLT 27.0, macOS 27.0). This one is not the prototype's.

`/usr/bin/make` and `/usr/bin/clang` are universal, but they are xcode-select shims that
`dlopen` `libxcrun.dylib` — and that library ships arm64 and arm64e only. The real binaries
behind them, in `/Library/Developer/CommandLineTools/usr/bin`, are arm64-only. Under
`arch -x86_64` the shim reports `missing compatible architecture (need 'x86_64')` and the
real binary reports `Bad CPU type in executable`. Xcode 26.4's copies of both are universal,
so pointing `DEVELOPER_DIR` at Xcode brings the wrapping back — at the price of requiring
Xcode.

What works with the Command Line Tools alone is to run the tools natively and name the
target out loud: every `configure` gets `--host=x86_64-apple-darwin
--build=x86_64-apple-darwin` **and** `CC="clang -arch x86_64"` — absolute for Wine, for a
reason two sections down. Autoconf then believes it is
a native x86_64 build and runs its test programs, which Rosetta executes — which is what the
wrapping used to buy.

`CC` is not optional. With the triplet alone, gmp compiles x86_64 assembly and hands it to
an arm64 assembler: `tmp-add_err1_n.s: error: invalid operand / pop %rbx`.

Verified by building the six libraries that take a configure flag, and then Wine itself, this
way on 2026-09-19 — MoltenVK is placed rather than configured, so it never sees one. Wine's
configure had never been run without the wrapping — the prototype passed it no triplet at all
— and it wants `CXX` named as well as `CC`, CrossOver's tree having C++ in it.

Naming the compiler out loud raises two questions the wrapping answered implicitly, and the
next two sections are those: which components should be x86_64 at all, and where the PE
compiler goes on PATH.

### Only what ends up inside Wine is x86_64

Measured in sake on 2026-09-19. This corrects an earlier claim here that all nine landed as
x86_64 and that "the two that produce executables run". They do run — just not inside a Wine
build.

`bison` and `pkgconf` are build tools. Wine neither links nor `dlopen`s what they produce,
so nothing requires them to match Wine's architecture; the prototype had them x86_64 only
because it wrapped the whole build in `arch -x86_64`.

x86_64 is worse than unnecessary for them, because **an x86_64 process cannot exec an
xcode-select shim**. bison has `/usr/bin/m4` compiled into it, and that is a universal shim:
called from x86_64 it starts x86_64, cannot `dlopen` the arm64-only `libxcrun.dylib`, and
dies. make sees the broken pipe and stops with `Error 141` on `tools/widl/parser.tab.h` — an
error naming neither m4 nor architecture.

`M4=$(xcrun -f m4)` also clears it, since an x86_64 process *can* exec an arm64-only binary.
Building the tool native clears the class rather than the instance, which is why sake does
that instead.

So: gmp, nettle, libtasn1, gnutls, freetype, SDL2 and MoltenVK are x86_64 because Wine loads
them. bison and pkgconf are native.

### The PE compiler leads the system, and `CC` is absolute

Measured in sake on 2026-09-19. llvm-mingw ships a bare `clang` and `clang++` beside its
`x86_64-w64-mingw32-*` ones, and the two halves of a Wine build disagree about which clang
the name `clang` should mean.

**winebuild wants llvm-mingw's.** It assembles every PE object with whatever plain `clang`
PATH offers it — `find_binary( NULL, "clang" )` in `tools/winebuild/utils.c`, reached
because nothing on the way in hands it a `--cc-cmd`. Put llvm-mingw behind `/usr/bin` and it
finds Apple's instead; winebuild is x86_64 and `/usr/bin/clang` is a shim, so it dies the
way bison's m4 does — 94,000 lines into the build, naming neither clang nor architecture:

```
winebuild: /usr/bin/clang failed with status 1
winegcc: ./tools/winebuild/winebuild failed
```

**configure wants Apple's.** llvm-mingw's clang targets Windows, so with it in front the
first link test fails before anything else is checked at all:

```
ld: warning: ignoring -lto_library '<llvm-mingw>/lib/libLTO.dylib', file does not exist
ld: library 'System' not found
```

Both at once: llvm-mingw ahead of `/usr/bin`, and `CC`/`CXX` named by absolute path so that
configure never resolves the bare name. That is the arrangement the prototype had without
having to think about it — it named no `CC`, so configure went looking for `gcc`, a name
llvm-mingw does not ship unprefixed.

The collision is narrow, which is why the front of PATH is safe: only `clang`, `clang++`,
`clangd` and `lldb` exist in both llvm-mingw's `bin` and `/usr/bin`, and nothing configure
looks for by bare name — `cpp`, `ld`, `strip`, `flex`, `bison`, `pkg-config` — is in
llvm-mingw at all.
