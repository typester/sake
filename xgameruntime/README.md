# xgameruntime

sake's own `xgameruntime.dll`: the Gaming Runtime that a title built on Microsoft's GDK
loads. On Windows, Xbox Gaming Services installs that DLL; Wine has none, and this is what
sake puts in its place. `docs/gdk.md` has the design and what has been measured with it.

Nobody is signed in yet. `XUserAddAsync` fails as though no user were signed in, which is
as far as the first step of `docs/gdk.md`'s order goes.

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
| XNetworking | online, unmetered; TLS 1.2 and no pinned certificates for every URL |
| XGame | the title ID from the title's `MicrosoftGame.config` |
| XGameProtocol, XGameInvite | registrations accepted, never fired |
| XUser, XUserGamertag, XUserDevice | no user: adding one fails, silently or as a closed sign-in window |

A class answers every interface version it is known by from one table that carries all of
their slots. Anything else is refused and logged.

## Where the facts come from

- **The title's own binaries**, read with the engine toolchain's `llvm-objdump` on
  2026-09-29: the exports the thunks look up, the class and interface IDs they ask for, and
  the argument shape of each slot they call. Minecraft Dungeons II's executable is
  encrypted on disk, but its IDs are in its `.rdata`, and the thunks in its DLLs can be read.
- **WineGDK** (`Weather-OS/WineGDK` at `b03ba49`): the slot order of the interfaces it
  describes. Only those facts are used, not its text, and every slot Minecraft Dungeons II
  calls before signing in was checked against the thunks.
- **libHttpClient** (`microsoft/libHttpClient`): XAsync and XTaskQueue, compiled unmodified
  from `Source/Task`. `src/pch.h` stands in for the header its own build provides.

## Licences

The code in this directory is MIT, like the rest of sake. libHttpClient is MIT too,
Copyright (c) Microsoft Corporation. It is fetched rather than kept here, and a built DLL
contains it, so its `LICENSE.md` goes wherever the DLL goes. Nothing here comes from the
community stand-in, whose repository has no licence.

## Building it by hand

Until SakeKit builds it:

```sh
curl -L -o target/libHttpClient-7ead73f6.tar.gz \
  https://github.com/microsoft/libHttpClient/archive/7ead73f6389271c2dc2cb10cdafcc587b899bd8a.tar.gz
shasum -a 256 target/libHttpClient-7ead73f6.tar.gz
tar xzf target/libHttpClient-7ead73f6.tar.gz -C target
PATH=~/Library/Caches/Sake/toolchain/llvm-mingw-20260908-ucrt-macos-universal/bin:$PATH \
  make -C xgameruntime LIBHTTPCLIENT=$PWD/target/libHttpClient-7ead73f6389271c2dc2cb10cdafcc587b899bd8a
```

The tarball hashed `dda556ee4c7f5f925779fec25a8dfa3d7b236513638b0e516ed456817c8aac94`
on 2026-09-29, twice, an hour apart. GitHub generates these archives and does not promise
to reproduce them byte for byte. The DLL lands in `target/xgameruntime/`: about 900 KB,
importing the UCRT, KERNEL32 and ole32 and nothing else.

## The log

Every process that loads it appends to `%TEMP%\xgameruntime.log`, which in a sake bottle
is `drive_c/users/crossover/AppData/Local/Temp/xgameruntime.log`. It records where the DLL
was loaded from, each `QueryApiImpl`, and each call. A title calls some of these every
frame, so each call site writes its first twenty calls and then every power of two.
