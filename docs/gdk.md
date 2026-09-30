# GDK titles: what sake provides in place of Gaming Services

A title built on Microsoft's Game Development Kit (GDK) calls into `xgameruntime.dll`, the
Gaming Runtime that Xbox Gaming Services installs on Windows, for its task queues, its user
and its tokens. Wine has neither. This file is how sake means to provide both itself: a
runtime DLL it builds, and a sign-in it performs. **The runtime exists, in `xgameruntime/`,
and takes Minecraft Dungeons II as far as its sign-in. The sign-in exists in SakeKit and has
signed a real account in; nothing calls it yet.** What was measured says so and gives the
date; the rest is a decision or an open question.

## What was measured

On 2026-09-29, in the `ex` bottle, with Minecraft Dungeons II started through Steam and the
community stand-in for Gaming Services in place (`runtime.md` has the WinHTTP half of that
run). The stand-in's repository has no licence, so its code is not a source for anything
here; its log is used only as a record of what the game asked for and what the stand-in
answered.

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
- **The public endpoint table covers two of those.** Xbox Live maps each service to the
  relying party its token must name. `title.mgt.xboxlive.com/titles/default/endpoints?type=1`
  answers without authentication, with 88 entries: `playfabapi.com` names
  `http://playfab.xboxlive.com/` and no signature policy, and `*.xboxlive.com` names
  `http://xboxlive.com` and signature policy 0 (version 1, ES256, the first 8192 bytes of the
  body). Nothing names `api.minecraftservices.com`. Until 2026-09-29 this said the table had
  nothing for PlayFab; it has the host the game asks a token for, while the game's requests go
  to `83156.playfabapi.com`, which no entry names. The title's own table is under the sign-in,
  below.
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
- **So the silent add must not fail.** Once it has, the game does not ask again. Until
  2026-09-29 this said that whoever signs in must therefore have done so before the game
  starts. The stand-in had already shown otherwise, and its way is what sake's
  sign-in should look like: in its log the silent add succeeds with a placeholder user (XUID
  1), the game goes on to `LoginWithSteam` and `XUserAddByIdWithUiAsync`, and the stand-in
  starts Microsoft's device-code sign-in when the game first asks for a token — by the owner's
  account, with a browser opening for it — after which the game reached character select.

Later that night SakeKit's own sign-in was run against the real services, with the owner's
account, from a throwaway program compiled against SakeKit. Nothing was sent to PlayFab,
Minecraft's services or `multiplayeractivity.xboxlive.com`, so "issued" below means the
token service agreed, and says nothing about whether the service a token names will.
Microsoft documents some of these requests and not others; where one of its pages covers a
shape it is named, and everything else is here because the service accepted it.

- **The signature** is specified by Microsoft's "Title service calls to Xbox services" (GDK
  documentation, read 2026-09-29): the policy version as four big-endian bytes, a Windows
  file time as eight, then the raw r‖s of an ES256 signature, in standard base64. What is
  signed is the version, the time, the method, the path and query, the `Authorization` value
  and the body, each followed by a zero byte. `device.auth.xboxlive.com` issued a device
  token to a request signed that way, answered 403 when the signature's last byte was flipped
  and 400 when it was missing.
- **The device token**: `ProofOfPossession`, `DeviceType` `Win32`, `Version` `10.0.19045` —
  what a sake bottle reports in `system.reg` — an `Id` in braces and the key as a JWK, all in
  `Properties`, signed. It lasts 14 days.
- **Microsoft's device code**: `oauth20_connect.srf` with the title's `MSAAppId` as the
  client and `service::user.auth.xboxlive.com::MBI_SSL` as the scope. It gave a code for
  `https://www.microsoft.com/link`, valid 15 minutes and polled every 5 seconds, and no
  `verification_uri_complete`, so the code is always typed. The access token lasts 24 hours,
  and refreshing it handed back a new refresh token as well.
- **No sign-in without a code.** An authorization-code flow could run in a window of sake's own
  with nothing to type, but it needs a redirect the app has registered, and
  `oauth20_authorize.srf` refused `https://login.live.com/oauth20_desktop.srf` and
  `ms-xal-<id>://auth` in three spellings: "The expected value is a URI which matches a
  redirect URI registered for this client application". It says so without anyone signing in.
- **The user token.** Microsoft's "Xbox services sign-in for title websites" gives the
  request, with a `d=` ticket for an Entra token; a login.live.com ticket goes as `t=`. It was
  issued both signed with the key in `Properties` and unsigned without it, and lasts 96 hours.
- **XSTS tokens**, lasting 16 hours where Microsoft's "Xbox services authentication" gives
  four as the default: `http://xboxlive.com`, whose claims name the person (XUID, gamertag,
  age group, privileges), and `http://playfab.xboxlive.com/` and
  `rp://api.minecraftservices.com/`, which carry the user hash alone. The last is the relying
  party the Minecraft Wiki's "Microsoft authentication" page (read 2026-09-29) gives for
  `api.minecraftservices.com`, since no table sake can read names one. Each was issued bound
  to the device's key and bound to nothing. A relying party is spelled as the table spells
  it: PlayFab's without its trailing slash was a 400.
- **No title token, so no title table.** `title.auth.xboxlive.com` answered 403 with an empty
  body, and SISU's `/authorize` 401, presumably wanting a session from its `/authenticate`,
  which wants a registered redirect again. The title's own table answers 414 to `?type=1`
  with or without a token. Without the query it is 401 to nobody and 403 to every XSTS token
  above, none of which was minted with a title token.
- **Where a signature is checked.** `title.mgt.xboxlive.com` refused a key-bound token sent
  unsigned or with a corrupted signature, 401 `invalid_request_signature`, and got as far as
  its 403 for a token bound to nothing sent unsigned. `profile.xboxlive.com` read the person's
  gamertag all three ways: bound and signed, bound and unsigned, unbound and unsigned.
- **Finding the title.** `GDKTitle` found Minecraft Dungeons II by its config in
  `steamapps/common`, five levels under `Program Files (x86)`, which is as deep as it looks.

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

**A sign-in in the app, started by the game.** It looks like the stand-in's (above): the
person signs in when the game does, in the browser, rather than before it starts. The runtime
asks sake; sake opens `microsoft.com/link` and shows the code to type there, since there is
no window without one (above). The device-code flow uses the title's own `MSAAppId`, sake
keeps the refresh token in the Keychain, and XSTS tokens are minted for each relying party the
title needs. The title declares that ID for exactly this; sake signs in as no other
application. `XboxSignIn` in SakeKit is the sign-in from a refresh token or a code to the
tokens; the runtime's request and sake's answer to it are not built. This paragraph used to
show the code in sake's window before the game started, and kept the device's proof key in
the Keychain as well; whether there is a key at all is now an open question.

**A session file between them.** sake writes into the bottle the user's XUID, gamertag and the
title's XSTS tokens with their expiry, and the runtime reads it. The refresh token stays out
of the bottle. Whether a key has to go in is open, below.

## Open questions

- ~~**Which relying party a URL needs.**~~ **Answered on 2026-09-29**: not from the title's
  own table, which sake cannot read without a title token (above). The default table covers
  `playfabapi.com` and `*.xboxlive.com`; anything else a title calls needs a table sake keeps
  for that title, which for Minecraft Dungeons II is `api.minecraftservices.com` →
  `rp://api.minecraftservices.com/`. Whether that is what the game's own calls need, the first
  run with a signed-in user will show.
- **Which call starts the sign-in.** The runtime can hold the silent `XUserAddAsync` until the
  sign-in is done, so the game is handed the real user from the start, or pass it with a
  placeholder the way the stand-in does and start at the first token request. The first is
  the proposal.
- **Whether a key goes into the bottle.** Microsoft's page says every call to an Xbox service
  carries a signature from the key its token is bound to. A token bound to nothing needed none
  at the two services measured; if the ones the game calls agree, the runtime is handed
  unbound tokens and no key leaves sake. If one does not, the key can be one made for that
  launch rather than one kept.
- **Whether tokens outlive a session.** XSTS tokens last 16 hours and the user token 96; a
  session longer than that, or a Mac asleep through it, needs a way for the runtime to ask
  sake for fresh ones instead of a file written at launch.
- **The Keychain under ad-hoc signing.** A login-keychain item trusts the signature of the app
  that made it, and an ad-hoc signature changes with every build, so each update may ask the
  person to allow sake again. Not yet measured.
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
2. **The sign-in in SakeKit**, measured against the relying parties above. **The sign-in
   itself is done, on 2026-09-29**: `XboxSignIn` goes from a refresh token or a code to the
   tokens, against the real services. Still to come in this step: the runtime asking sake to
   sign in, sake opening the browser and showing the code, and the refresh token in the
   Keychain.
3. **`XUser` over the session file**, to character select.
4. **SakeKit builds and places the runtime**: `xgameruntime/` compiled with the engine's
   toolchain, libHttpClient fetched as a pinned source, and the DLL put in the `system32` of a
   bottle whose title has a `MicrosoftGame.config`. Last, because the steps before it need
   nothing from it.
