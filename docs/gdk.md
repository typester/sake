# GDK titles: what sake provides in place of Gaming Services

A title built on Microsoft's Game Development Kit (GDK) calls into `xgameruntime.dll`, the
Gaming Runtime that Xbox Gaming Services installs on Windows, for its task queues, its user
and its tokens. Wine has neither. This file is how sake means to provide both itself: a
runtime DLL it builds, and a sign-in it performs. **Nothing here is built yet.** What was
measured says so and gives the date; the rest is a decision or an open question.

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
  with libc++ inside it, importing nothing but the UCRT and `KERNEL32`.

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

## The design

**A runtime sake builds.** sake's own `xgameruntime.dll`, C++, built with the engine's
toolchain outside Wine's build and put in a GDK title's bottle. It is not a Wine patch: it
replaces no Wine code. What WineGDK has implemented is the starting point, with its
provenance in each file's header; `XUser` is written here.

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
- **The interface layout.** The runtime's COM-style interfaces change between GDK editions;
  which edition Minecraft Dungeons II was built with and which WineGDK describes has not been
  compared.
- **What stops the game before this matters.** Its launcher's checks and the VC++ false
  positive are separate problems and still open.

## Order

1. **The runtime alone**: built, placed, and the game started with no stand-in, as far as its
   sign-in. The interface layout is the largest unknown, so it goes first.
2. **The sign-in in SakeKit**, measured against the relying parties above.
3. **`XUser` over the session file**, to character select.
