# GDK titles: what sake provides in place of Gaming Services

A title built on Microsoft's Game Development Kit (GDK) calls into `xgameruntime.dll`, the
Gaming Runtime that Xbox Gaming Services installs on Windows, for its task queues, its user
and its tokens. Wine has neither. This file is how sake means to provide both itself: a
runtime DLL it builds, and a sign-in it performs. **The runtime exists, in `xgameruntime/`,
and takes Minecraft Dungeons II as far as its sign-in; the sign-in does not exist yet.** What
was measured says so and gives the date; the rest is a decision or an open question.

## What was measured

On 2026-09-29, in the `ex` bottle, with Minecraft Dungeons II started through Steam and the
community stand-in for Gaming Services in place (`runtime.md` has the WinHTTP half of that
run). The stand-in's repository has no licence, so its code is not a source for anything
here; its log is used only as a record of what the game asked for.

- **The title carries its own identity.** `MicrosoftGame.config` beside the executable has
  `<MSAAppId>00000000497C1B94</MSAAppId>`, `<TitleId>6B9DE498</TitleId>` and
  `<RequiresXboxLive>false</RequiresXboxLive>`. The stand-in signed in with that same
  `MSAAppId` as its OAuth client — Microsoft's device-code flow on `login.live.com`, scope
  `service::user.auth.xboxlive.com::MBI_SSL`, then a user token from
  `user.auth.xboxlive.com`, a device token from `device.auth.xboxlive.com` and XSTS tokens
  from `xsts.auth.xboxlive.com` — and the game reached character select.
- **What the game calls.** The `XTaskQueue` family (create, composite, register monitor,
  terminate); `XUserAddAsync` and `XUserAddResult`, `XUserAddByIdWithUiAsync`, `XUserGetId`,
  `XUserRegisterForChangeEvent`; `XSystemGetXboxLiveSandboxId`,
  `XNetworkingGetConnectivityHint`, `XGameProtocolRegisterForActivation`,
  `XGameGetXboxTitleId`, `XGameRuntimeIsFeatureAvailable`, `XErrorSetOptions`,
  `XErrorSetCallback`; and `XblMultiplayerActivitySetActivityAsync` and
  `XblMultiplayerActivityDeleteActivityAsync`. XCurl, the GDK's HTTP client, asks the
  runtime for each URL's TLS requirements before it connects.
- **What it asks tokens for.** `XUserGetTokenAndSignature` for `https://playfabapi.com/`,
  `https://api.minecraftservices.com` and `multiplayeractivity.xboxlive.com`.
- **The public endpoint table does not cover those.** Xbox Live maps each service to the
  relying party its token must name. `title.mgt.xboxlive.com/titles/default/endpoints`
  answered without authentication with 88 entries, none for PlayFab or Minecraft; the
  title's own table did not answer unauthenticated (HTTP 414).
- **The engine's toolchain builds C++ that runs here.** llvm-mingw's `clang++` links a DLL
  with libc++ inside it, importing nothing but the UCRT and `KERNEL32`. The runtime imports
  `ole32` as well: libHttpClient waits for an async call through COM when the waiting thread
  is in a single-threaded apartment.

Later the same day sake's own runtime took the stand-in's place: `xgameruntime/`, built by
hand and put in the bottle's `system32`, with the stand-in's three copies set aside.

- **How a title finds the runtime.** No module imports `xgameruntime.dll`; the GDK's thunks in
  each one load it themselves with `LoadLibraryExW`. The launcher's look up six exports and
  search `system32`, and the executable's own folder as well only when a copy is already there
  (`GetFileAttributesW`) and either `ForceUseLocalServices` is set under
  `HKLM\Software\Microsoft\GamingServices` or the Microsoft Store is not installed. They tell
  the runtime which through bit 0x8 of their initialisation flags. With sake's copy in
  `system32` alone, the launcher and the game both passed 0x2: the folder was not searched.
  `system32` is where it goes.
- **Which GDK edition.** The `.xbld` section says: "April 2026 GRDK Update 1" for the
  launcher, `XCurl.dll` and `GameChat2.dll`. The game's executable holds objects from that
  edition and from "October 2025 GRDK", which is what `libHttpClient.GDK.dll` was built with.
- **What the game can ask for.** Its executable's code is encrypted on disk, but its `.rdata`
  lists the 18 pairs of class and interface ID its thunks pass to `QueryApiImpl`. WineGDK's
  IDL describes five of those classes — XThreading (`XAsync`, `XTaskQueue`, `XThread`),
  XGameRuntimeFeature, XSystem, XUser and XNetworking — and every interface version the game
  names for them is one WineGDK lists. XError and XGameProtocol, which the game also uses
  before signing in, are in no IDL. Their slots come from the argument shapes of the thunks
  in `libHttpClient.GDK.dll`, which carries thunks for 23 classes, far more than it calls.
  Where both exist, the shapes agree with WineGDK's slot order for every slot the game used.
- **The run.** The launcher passed its Gaming Services check and started the game a second
  later. The game called XError, `XTaskQueue`, XNetworking, XGameProtocol and XUser, and
  nothing it asked for was refused. XGameProtocol is the class `95fd18d2`, registered right
  after the XGame feature check; the other class of its shape, `0651aae2`, is then XGameInvite,
  which the runtime reports absent and the game never asked for. XUser was asked for under its
  base interface ID, `01acd177`. The silent `XUserAddAsync` failed with
  `E_GAMEUSER_NO_DEFAULT_USER`, and the game drew its title scene with "SIGNING IN .." and
  waited: 3.5 minutes with no further `XUser` call, no sign-in window asked for and no HTTP
  request. Closed from its window, it ran its XSAPI and libHttpClient cleanups through the
  runtime in a quarter of a second and was gone at the next three-second sample.
  `GamingRepair.exe`, which Steam runs before every start, still exited `0x80040154`, as it
  had with the stand-in.
- **So the title does not ask to be signed in.** Whoever signs in has to have done so before
  it starts, which is what the session file in the design assumes.

## WineGDK

`Weather-OS/WineGDK` implements `xgameruntime` inside Wine 11.14. Its author declares their
own code CC0 — "derive, redistribute and reimplement ... without any attributions" — except
code by Olivia Ryan and the Xodus interop, which stay under Wine's LGPL. At its 2026-08-22
head:

- task queues, `XAsync`, threading, `XSystem`, feature queries and networking are
  implemented, and its IDL describes the runtime's COM-style interfaces;
- `XUser` is not: `XUserAddAsync`, `XUserGetId` and `XUserGetTokenAndSignatureAsync` return
  `E_NOTIMPL`, and the sign-in in progress hands token requests to Xodus, a separate GPL-3.0
  service;
- it is C++, built by Wine's C++ support for PE modules, which the Wine 11.0 in CrossOver
  26.3.0's sources does not have — so it cannot become a patch against sake's tree.

Not all of it is its author's to declare, which this file did not say until 2026-09-29 and
the design below took for granted. The files behind its task queues and `XAsync` open with
"From https://github.com/microsoft/libHttpClient" — Microsoft's code, MIT-licensed — beneath
an LGPL header; `InitInternalGDKC.cpp`, `UserImpl.*` and `XodusService.cpp` carry Olivia
Ryan's copyright; and its IDL has the Wine project's LGPL header rather than the CC0
declaration. What sake takes from WineGDK is therefore facts and no text: the interfaces'
IDs and the order of their slots.

## The design

**A runtime sake builds.** sake's own `xgameruntime.dll`, C++, built with the engine's
toolchain outside Wine's build and put in a GDK title's bottle. It is not a Wine patch: it
replaces no Wine code. It lives in `xgameruntime/`: the task queue and `XAsync` are
libHttpClient's, compiled unmodified from a pinned commit; the IDs and slot order are
WineGDK's, each checked against the title's thunks; the rest, `XUser` included, is written
there. This paragraph used to make WineGDK's implementation the starting point, which would
have taken Microsoft's code at second hand under a header that is not its own.

**A sign-in in the app.** The device-code flow with the title's own `MSAAppId`, the code
shown in sake's window, the refresh token and the device's proof key kept in the Keychain,
and XSTS tokens minted for each relying party the title needs. The title declares that ID
for exactly this; sake signs in as no other application.

**A session file between them.** At launch sake writes into the bottle the user's XUID,
gamertag and the title's XSTS tokens with their expiry, and the runtime reads it. The
refresh token and the proof key stay out of the bottle.

## Open questions

- **Which relying party a URL needs**, when the title's own endpoint table wants
  authentication: fetch it once signed in, or keep a table per title.
- **Whether tokens outlive a session.** XSTS tokens last hours; a long session may need a way
  for the runtime to ask sake for fresh ones instead of a file written at launch.
- ~~**The interface layout.**~~ **Answered for Minecraft Dungeons II on 2026-09-29**, above:
  every version it names is one WineGDK lists. A title built with a later edition may name
  another; the runtime refuses a version it does not know and logs it, which is where to
  look.
- **The game executable's own thunks.** Its code is encrypted on disk, so only the calls it
  made have been checked.
- **Security information for a URL** is answered with TLS 1.2 and no pinned certificates,
  and only a probe has asked for it: the game sends no request before it has a user.
- **How to pin libHttpClient.** The tarball GitHub generates for the commit hashed the same an
  hour apart on 2026-09-29, but GitHub does not promise that; SakeKit may have to pin the
  commit itself.
- **What stops the game before this matters.** The launcher's Gaming Services check is
  answered by the runtime (above). The VC++ false positive is still open: the `ex` bottle gets
  past it with a DLL override sake does not set.

## Order

1. **The runtime alone**: built, placed, and the game started with no stand-in, as far as its
   sign-in. The interface layout is the largest unknown, so it goes first. **Done on
   2026-09-29**, built and placed by hand (above).
2. **The sign-in in SakeKit**, measured against the relying parties above.
3. **`XUser` over the session file**, to character select.
4. **SakeKit builds and places the runtime**: `xgameruntime/` compiled with the engine's
   toolchain, libHttpClient fetched as a pinned source, and the DLL put in the `system32` of a
   bottle whose title has a `MicrosoftGame.config`. Last, because the steps before it need
   nothing from it.
