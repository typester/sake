# xgameruntime

sake's own `xgameruntime.dll`: the Gaming Runtime that a title built on Microsoft's GDK
loads. On Windows, Xbox Gaming Services installs that DLL; Wine has none, and this is what
sake puts in its place. `docs/gdk.md` has the design and what has been measured with it.

It hands a title its user and tokens: the person sake signed in, from a session sake writes
into the bottle, and a placeholder until there is one. The first token request with no good
session asks sake to sign the person in, through files `docs/gdk.md` describes, and completes
once sake has.

## How a title reaches it

Each module of a GDK title carries the GDK's thunks and loads `xgameruntime.dll` itself,
with `LoadLibraryExW`: from `system32`, and from the executable's own folder as well when
a copy is there and either `ForceUseLocalServices` is set or the Microsoft Store is not
installed. It looks up the six exports in `xgameruntime.def`. From then on, every API call
asks `QueryApiImpl` for an object by class ID and interface ID, calls one slot of its
vtable, and releases it.

## What it answers

| class | how |
|---|---|
| XThreading (XAsync, XTaskQueue, XThread) | libHttpClient's implementation; XThread is its own |
| XGameRuntimeFeature | true for the features below, false for the rest |
| XError | options and callback accepted, reports logged |
| XSystem, XSystemAnalytics | sandbox `RETAIL`; the rest minimal |
| XNetworking | online, unmetered, with the initial notification to each registration for changes; TLS 1.2 and no pinned certificates for every URL |
| XGame | the title ID from the title's `MicrosoftGame.config` |
| XGameProtocol, XGameInvite | registrations accepted, never fired |
| XUser, XUserGamertag, XUserDevice | one user: the session's person, or a placeholder until the first token request asks sake; one `SignedInAgain` after the silent add; tokens by host from the session, unsigned; no gamer picture and no devices |

A class answers every interface version it is known by from one table that carries all of
their slots. Anything else is refused and logged.

## Where the facts come from

- **The title's own binaries**, read with the engine toolchain's `llvm-objdump` on
  2026-09-29: the exports the thunks look up, the class and interface IDs they ask for, and
  the argument shape of each slot they call. Minecraft Dungeons II's executable is
  encrypted on disk, but its IDs are in its `.rdata`, and the thunks in its DLLs can be read.
- **WineGDK** (`Weather-OS/WineGDK` at `b03ba49`): the slot order of the interfaces it
  describes. Only those facts are used, not its text. Every `XUser` slot was checked against
  the thunks on 2026-09-30, and every slot Minecraft Dungeons II calls before signing in
  before that.
- **Microsoft's GDK reference** (learn.microsoft.com, read 2026-09-30): the shapes of what
  `XUser` hands back, its enumerations and error codes, and the initial notification a
  registration for connectivity changes gets.
- **The community stand-in, run from outside**: which change event it delivers after the
  silent add, and where the notifications arrive. Its DLL was called from a probe and its
  code was not read.
- **libHttpClient** (`microsoft/libHttpClient`): XAsync and XTaskQueue, compiled unmodified
  from `Source/Task`. `src/pch.h` stands in for the header its own build provides.

## Licences

The code in this directory is MIT, like the rest of sake. libHttpClient is MIT too,
Copyright (c) Microsoft Corporation. It is fetched rather than kept here, and a built DLL
contains it, so its `LICENSE.md` goes wherever the DLL goes. No code or text here comes from
the community stand-in, whose repository has no licence; what it was seen to do is a fact
the runtime follows (above).

## How sake builds and places it

Setup's GDK Runtime step builds it from the copy of this directory inside Sake.app, running
this Makefile with a `CXX`, `LIBHTTPCLIENT` and `OUT` of its own, and keeps the DLL in the
engine with libHttpClient's `LICENSE.md`. Before sake starts anything in a bottle it puts both
in that bottle's `system32`, and it replaces a copy there only when the copy carries the string
in `main.cpp`, which is why that string can never change. SakeKit's tests run this Makefile
with a stand-in compiler, so a change to those three variables fails there. `docs/gdk.md` has
the rest.

## Building it by hand

For working on it:

```sh
curl -L -o target/libHttpClient-7ead73f6.tar.gz \
  https://github.com/microsoft/libHttpClient/archive/7ead73f6389271c2dc2cb10cdafcc587b899bd8a.tar.gz
shasum -a 256 target/libHttpClient-7ead73f6.tar.gz
tar xzf target/libHttpClient-7ead73f6.tar.gz -C target
PATH=~/Library/Caches/Sake/toolchain/llvm-mingw-20260908-ucrt-macos-universal/bin:$PATH \
  make -C xgameruntime LIBHTTPCLIENT=$PWD/target/libHttpClient-7ead73f6389271c2dc2cb10cdafcc587b899bd8a
```

The tarball hashed `dda556ee4c7f5f925779fec25a8dfa3d7b236513638b0e516ed456817c8aac94`
on 2026-09-29, twice, an hour apart, and again on 2026-09-30. GitHub promises the files inside
an archive of a commit and not its bytes, which is why SakeKit checks what it unpacks to
instead. The DLL lands in `target/xgameruntime/`: about 900 KB, importing the UCRT, KERNEL32
and ole32 and nothing else.

A new commit needs a new pin for what the archive unpacks to, `GDKRuntimeBuilder.pinnedLibHttpClient`.
This prints it for an unpacked tree the way SakeKit computes it, and gave `08c0f152…` for `7ead73f6`
on 2026-09-30, the value SakeKit then matched against a real download:

```sh
cd target/libHttpClient-<commit>
find . -type f -not -path '*/.*' | sed 's|^\./||' | LC_ALL=C sort |
  while IFS= read -r f; do printf '%s\0%s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done |
  shasum -a 256
```

## The log

Every process that loads it appends to `%TEMP%\xgameruntime.log`, which in a sake bottle
is `drive_c/users/crossover/AppData/Local/Temp/xgameruntime.log`. It records where the DLL
was loaded from, each `QueryApiImpl`, and each call. A title calls some of these every
frame, so each call site writes its first twenty calls and then every power of two.
