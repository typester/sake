# GDK titles: what sake provides in place of Gaming Services

A title built on Microsoft's Game Development Kit (GDK) calls into `xgameruntime.dll`, the
Gaming Runtime that Xbox Gaming Services installs on Windows, for its task queues, its user and
its tokens. Wine has neither. sake provides both itself: a runtime DLL it builds, in
[`xgameruntime/`](../xgameruntime/README.md), and an Xbox sign-in it performs with the title's
own app ID. The runtime asks sake to sign the person in when the game first wants a token, sake
does it through files in the bottle, and the runtime hands the game its user and tokens.

Minecraft Dungeons II plays on them (sake, 2026-09-30):

| | |
|---|---|
| signing in | a code the first time the game wants a token, silent after that; character select with no community stand-in |
| the runtime | built by setup and put in the bottle by sake, with nothing done by hand |
| account link | unlinking the Steam account from the Microsoft one and linking it again works |
| playing with others | joining a party by code works both ways with the game on a Nintendo Switch 2, and the two played a mission with the Mac hosting |
| Xbox multiplayer activity | refused: it needs a title token sake cannot get; what a player loses without it was not tried |
| a session past 16 hours | not tried |

What was measured says so and gives the date; the rest is a decision or an open question.

## How a title reaches the runtime

**No module imports `xgameruntime.dll`: the GDK's thunks in each one load it themselves with
`LoadLibraryExW`, and `system32` is where it goes.** The launcher's thunks look up six
exports and search `system32`, and the executable's own folder as well only when a copy is
already there (`GetFileAttributesW`) and either `ForceUseLocalServices` is set under
`HKLM\Software\Microsoft\GamingServices` or the Microsoft Store is not installed. They tell the
runtime which through bit 0x8 of their initialisation flags. With sake's copy in `system32`
alone, the launcher and the game both passed 0x2: the folder was not searched (sake,
2026-09-29). From then on every call asks `QueryApiImpl` for an object by class ID and interface
ID, calls one slot of its vtable, and releases it.

## The runtime

**sake builds its own `xgameruntime.dll`**, C++, with the engine's toolchain and outside Wine's
build. It is not a Wine patch: it replaces no Wine code. The task queue and `XAsync` are
libHttpClient's, compiled unmodified from a pinned commit; the interfaces' IDs and slot order
are WineGDK's, each checked against the title's thunks
([measurements](#the-title-and-what-it-calls)); the rest, `XUser` included, is written there.
llvm-mingw's `clang++` links it with libc++ inside, importing nothing but the UCRT, `KERNEL32`
and `ole32`, the last because libHttpClient waits for an async call through COM when the
waiting thread is in a single-threaded apartment (sake, 2026-09-29).

**Where it goes.** Setup builds it in a step of its own, from the copy of `xgameruntime/` inside
Sake.app, and keeps it in the engine with libHttpClient's licence beside it. Before sake starts
a title or an installer in any bottle, it puts both in that bottle's `system32`, the one place
the launcher looks. That is every bottle, and not only one where a `MicrosoftGame.config` is
found: sake starts Steam before Steam installs the game, so at the only moment sake can put
anything there, there is no config to find, and nothing but a GDK title loads the DLL. A copy of
sake's own is replaced when it differs from the engine's, and a copy that is not sake's, such as
the community stand-in, is left where it is; sake tells the two apart by a string its build
carries. The step counts as done only while the engine's copy was built from the source that
Sake.app carries, so an update that changes the runtime leaves the step to do again, which the
library's sidebar points out.

An installer is given it too, because Steam's can start Steam as it finishes, and a game
installed in that Steam never passes through sake's Play; that has not been tried. A copy is
written beside the one it replaces and renamed over it, so nothing ever reads half a DLL. On
APFS a game that has the old one loaded keeps it; on exFAT, where the `ex` bottle is, what that
rename does under a running game has not been measured, and sake cannot yet see what runs in a
symlinked bottle ([#15](https://github.com/typester/sake/issues/15)) to wait for it. The engine
is one per Mac, so two copies of sake that carry different runtime source each take the other's
build for stale and build their own again; only a development build run beside a release does
that.

**libHttpClient is pinned by what it unpacks to.** The step fetches it itself rather than with
the other sources, so that nothing else in setup waits on it. GitHub's page on downloading
source code archives promises that an archive of a commit ID always has the same files, and not
the same bytes: the compression may change, with six months' notice (read 2026-09-30). A hash of
the archive would be a way for setup to stop one day with nothing wrong, so SakeKit hashes the
unpacked tree instead — the path and contents of every file in it that is not hidden — and
compares that with the hash it carries. The archive itself hashed the same three times in two
days (sake, 2026-09-29 and 2026-09-30).

**The user it hands over.** One user, whose handle is one object's address. The silent add
returns at once: with the person the session names while its identity token lasts five more
minutes, and otherwise with a placeholder, XUID 1, the way the stand-in answers, which takes the
XUID the game then adds by ID. After it, the runtime sends the one `SignedInAgain` and, on every
registration for connectivity changes, the initial notification, both as the stand-in does
([measurements](#the-runtime-in-the-game)). A token request looks the URL's host up in the
session; a token that is missing or lasts less than five minutes sends the runtime to sake, and
a URL no relying party covers gets `E_GAMEUSER_NO_TOKEN_REQUIRED`. Every answer is completed
inside `XAsyncBegin` or from the runtime's own thread, never from the caller's queue.

**`ForceRefresh` goes to sake only when no ask of sake has ended in the last 15 minutes**,
whatever that ask's answer; otherwise the request is answered as if the option were not there.
XSAPI puts that option on the person's next token request after any 401, whatever its URL, and
retries the refused call once (`Source/Shared/http_call_wrapper_internal.cpp` and `user.cpp` in
Microsoft's xbox-live-api, read 2026-09-30). So a refusal no new token cures, such as
multiplayer activity's, had cost a silent sign-in every few seconds
([measurements](#forcerefresh)), and since the option can ride on another service's request,
what it gets is the session's token rather than a failure.

## The sign-in

**The game starts it, and it looks like the stand-in's**: the person signs in when the game
does, in the browser, rather than before it starts. The runtime asks sake at the game's first
token request; sake opens `microsoft.com/link` and shows the code to type there, in a panel of
its own that floats above the browser, since there is no sign-in without a code
([measurements](#signing-in-against-the-real-services)). Asking at the silent add instead holds
the game's start until the sign-in is done, before the game has drawn a window
([measurements](#the-runtime-in-the-game)).

**The device-code flow uses the title's own `MSAAppId`**, from its `MicrosoftGame.config`. The
title declares that ID for exactly this, and sake signs in as no other application. In SakeKit,
`XboxSignIn` goes from a refresh token or a code to the tokens.

**XSTS tokens** are minted for `http://xboxlive.com`, for `http://playfab.xboxlive.com/`, and for
whatever a table sake keeps names for the title, which for Minecraft Dungeons II is
`rp://api.minecraftservices.com/`: the title's own table cannot be read without a title token
([measurements](#relying-parties-and-the-endpoint-table)). Only PlayFab's is bound to a device,
because the stand-in's README says PlayFab will not link an account otherwise, and it comes from
the same user token as the rest: the runtime labels every token with one user hash, and a user
token bound to the key would give PlayFab's another, which made account link fail
([measurements](#account-link-and-playing-with-others)). The rest are bound to nothing, every
token goes to the game unsigned, and the device's key never leaves sake.

**What sake keeps.** The refresh token and the device, in `~/Library/Sake/sign-ins`, one file per
app ID, readable by the person alone: not the Keychain, which asks for the login password on
every read under an ad hoc signature
([measurements](#the-keychain-under-an-ad-hoc-signature)). A file costs this: any program the
person runs can read it, every Windows program in every bottle included, through `Z:`. With it,
someone can sign in to Xbox Live as the person, with this title's app ID, until it is revoked;
changing the account's password should do that, and has not been tried. Nothing measured says
whether it reaches anything beyond Xbox Live. With a Developer ID signature the Keychain may stop
asking, which is not measured either.

**Files between the runtime and sake.** In `%LOCALAPPDATA%\Sake\<title ID>\` in the bottle,
which from sake's side is `drive_c/users/crossover/AppData/Local/Sake/`, since every sake
bottle's Windows user is `crossover`. The runtime writes `request`, holding an ID of its own;
sake writes `answer` and, once the person is signed in, `session`. Each file is `key value`
lines under a first line of `sake 1`, and each is written whole and renamed into place. `answer`
says `waiting` as soon as sake has the request, then `signed-in`, `failed` with a reason, or
`cancelled`. `session` carries the XUID, gamertag, user hash, age group and privileges, a line
`token <relying party> <expiry in Unix seconds> <token>` for each relying party, and a line
`endpoint <host> <relying party>` for each host a relying party covers: the host itself, or one
ending in it after a dot, so that the runtime keeps no table of its own. A title asks for several
tokens at once and there is one `request` per title, so a request made while another is out
joins it rather than replacing it. The runtime gives up when nothing says `waiting` within 10
seconds, and waits 20 minutes at most for the rest, a device code lasting 15. Files, because a
Windows DLL cannot reach a socket sake listens on: Wine's Winsock converts no `AF_UNIX` address
(read in CrossOver 26.3.0's sources, 2026-09-29). The refresh token stays out of the bottle.

## WineGDK

`Weather-OS/WineGDK` implements `xgameruntime` inside Wine 11.14. Its author declares their own
code CC0 — "derive, redistribute and reimplement ... without any attributions" — except code by
Olivia Ryan and the Xodus interop, which stay under Wine's LGPL. At its 2026-08-22 head:

- task queues, `XAsync`, threading, `XSystem`, feature queries and networking are implemented,
  and its IDL describes the runtime's COM-style interfaces;
- `XUser` is not: `XUserAddAsync`, `XUserGetId` and `XUserGetTokenAndSignatureAsync` return
  `E_NOTIMPL`, and the sign-in in progress hands token requests to Xodus, a separate GPL-3.0
  service;
- it is C++, built by Wine's C++ support for PE modules, which the Wine 11.0 in CrossOver
  26.3.0's sources does not have, so it cannot become a patch against sake's tree.

**Not all of it is its author's to declare.** The files behind its task queues and `XAsync` open
with "From https://github.com/microsoft/libHttpClient" — Microsoft's code, MIT-licensed —
beneath an LGPL header; `InitInternalGDKC.cpp`, `UserImpl.*` and `XodusService.cpp` carry Olivia
Ryan's copyright; and its IDL has the Wine project's LGPL header rather than the CC0
declaration. What sake takes from WineGDK is therefore facts and no text: the interfaces' IDs and
the order of their slots. libHttpClient it compiles from Microsoft's own repository.

## Open questions

- **Whether tokens outlive a session.** XSTS tokens last 16 hours and the user token 96. The
  runtime asks sake again for a token with less than five minutes left, and a kept sign-in makes
  that silent, but no session has yet run long enough to need it.
- **sake has to be running.** A request that nobody picks up fails after 10 seconds, and the game
  goes on without a user. A sake quit while its game runs cannot answer; whether quitting should
  be refused, or warned about, while a title runs is open.
- **Whether the game needs `SignedInAgain`.** The runtime sends it because the stand-in does, and
  the game answers it; a run with the connectivity notification and no change event would say
  whether it has to.
- **The game executable's own thunks.** Its code is encrypted on disk, so only the calls it made
  have been checked.
- **Security information for a URL** is answered with TLS 1.2 and no pinned certificates. The
  game asks for it, in UTF-16, before every request it sends, and its requests went through with
  that answer (sake, 2026-09-30).
- **What a player loses without multiplayer activity.** Not tried: the game's own parties and
  invites are Mojang's and were answered, and joining a party by code worked both ways.
- **Linking a Steam account PlayFab does not know yet.** Unlinking and linking again works, with
  PlayFab's token bound to the device the way the stand-in's README asks; a PlayFab token bound
  to nothing was not tried, and neither was an account PlayFab has not seen.
- **A first install through Steam**, which is the reason the runtime goes into every bottle, has
  not been run, since the game was installed already; nor has Steam's installer starting Steam
  as it finishes, or replacing sake's copy under a running game on exFAT (The runtime, above).
- **What stops a game before any of this matters.** The launcher's Gaming Services check is
  answered by the runtime. The VC++ false positive is still open: the `ex` bottle gets past it
  with a DLL override sake does not set.

## Measurements

### The title and what it calls

*2026-09-29, in the `ex` bottle, with Minecraft Dungeons II started through Steam. What the game
calls and asks tokens for was recorded with the community stand-in for Gaming Services in place
([runtime.md](runtime.md#gdk-titles-winhttp-options-xcurl-cannot-do-without) has the WinHTTP
half of that run); the GDK edition and the IDs were read from the title's binaries the same day,
and `GDKTitle` found the title that night. The stand-in's repository has no licence, so its code
is not a source for anything here; its log is used only as a record of what the game asked for
and what the stand-in answered.*

- **The title carries its own identity.** `MicrosoftGame.config` beside the executable has
  `<MSAAppId>00000000497C1B94</MSAAppId>`, `<TitleId>6B9DE498</TitleId>` and
  `<RequiresXboxLive>false</RequiresXboxLive>`. The stand-in signed in with that same `MSAAppId`
  as its OAuth client — Microsoft's device-code flow on `login.live.com`, scope
  `service::user.auth.xboxlive.com::MBI_SSL`, then a user token from `user.auth.xboxlive.com`, a
  device token from `device.auth.xboxlive.com` and XSTS tokens from `xsts.auth.xboxlive.com` —
  and the game reached character select.
- **What the game calls.** The `XTaskQueue` family (create, composite, register monitor,
  terminate); `XUserAddAsync` and `XUserAddResult`, `XUserAddByIdWithUiAsync`, `XUserGetId`,
  `XUserRegisterForChangeEvent`; `XSystemGetXboxLiveSandboxId`,
  `XNetworkingGetConnectivityHint`, `XGameProtocolRegisterForActivation`,
  `XGameGetXboxTitleId`, `XGameRuntimeIsFeatureAvailable`, `XErrorSetOptions`,
  `XErrorSetCallback`; and `XblMultiplayerActivitySetActivityAsync` and
  `XblMultiplayerActivityDeleteActivityAsync`. XCurl, the GDK's HTTP client, asks the runtime for
  each URL's TLS requirements before it connects.
- **What it asks tokens for.** `XUserGetTokenAndSignature` for `https://playfabapi.com/`,
  `https://api.minecraftservices.com` and `multiplayeractivity.xboxlive.com`.
- **Which GDK edition.** The `.xbld` section says: "April 2026 GRDK Update 1" for the launcher,
  `XCurl.dll` and `GameChat2.dll`. The game's executable holds objects from that edition and from
  "October 2025 GRDK", which is what `libHttpClient.GDK.dll` was built with.
- **What the game can ask for.** Its executable's code is encrypted on disk, but its `.rdata`
  lists the 18 pairs of class and interface ID its thunks pass to `QueryApiImpl`. WineGDK's IDL
  describes five of those classes — XThreading (`XAsync`, `XTaskQueue`, `XThread`),
  XGameRuntimeFeature, XSystem, XUser and XNetworking — and every interface version the game
  names for them is one WineGDK lists. XError and XGameProtocol, which the game also uses before
  signing in, are in no IDL. Their slots come from the argument shapes of the thunks in
  `libHttpClient.GDK.dll`, which carries thunks for 23 classes, far more than it calls. Where
  both exist, the shapes agree with WineGDK's slot order for every slot the game used. A title
  built with a later edition may name another version; the runtime refuses a version it does not
  know and logs it, which is where to look.
- **Finding the title.** `GDKTitle` found Minecraft Dungeons II by its config in
  `steamapps/common`, five levels under `Program Files (x86)`, which is as deep as it looks.

### Relying parties and the endpoint table

- **The public endpoint table covers two of the three hosts.** Xbox Live maps each service to
  the relying party its token must name. `title.mgt.xboxlive.com/titles/default/endpoints?type=1`
  answers without authentication, with 88 entries: `playfabapi.com` names
  `http://playfab.xboxlive.com/` and no signature policy, and `*.xboxlive.com` names
  `http://xboxlive.com` and signature policy 0 (version 1, ES256, the first 8192 bytes of the
  body). Nothing names `api.minecraftservices.com`. The table has the host the game asks a
  PlayFab token for, while the game's requests go to `83156.playfabapi.com`, which no entry
  names (sake, 2026-09-29).
- **Anything else needs a table sake keeps.** For Minecraft Dungeons II that is
  `api.minecraftservices.com` → `rp://api.minecraftservices.com/`, the relying party the
  Minecraft Wiki's "Microsoft authentication" page gives for that host (read 2026-09-29). It was
  what the game's own calls needed: they reached character select (sake, 2026-09-30).
- **A relying party is spelled as the table spells it**: PlayFab's without its trailing slash was
  a 400 (sake, 2026-09-29).

### Signing in against the real services

*The night of 2026-09-29, with the owner's account, from a throwaway program compiled against
SakeKit. Nothing was sent to PlayFab, Minecraft's services or
`multiplayeractivity.xboxlive.com`, so "issued" below means the token service agreed, and says
nothing about whether the service a token names will. Microsoft documents some of these
requests and not others; where one of its pages covers a shape it is named, and everything else
is here because the service accepted it.*

- **The signature** is specified by Microsoft's "Title service calls to Xbox services" (GDK
  documentation, read 2026-09-29): the policy version as four big-endian bytes, a Windows file
  time as eight, then the raw r‖s of an ES256 signature, in standard base64. What is signed is
  the version, the time, the method, the path and query, the `Authorization` value and the body,
  each followed by a zero byte. `device.auth.xboxlive.com` issued a device token to a request
  signed that way, answered 403 when the signature's last byte was flipped and 400 when it was
  missing.
- **The device token**: `ProofOfPossession`, `DeviceType` `Win32`, `Version` `10.0.19045` — what a
  sake bottle reports in `system.reg` — an `Id` in braces and the key as a JWK, all in
  `Properties`, signed. It lasts 14 days.
- **Microsoft's device code**: `oauth20_connect.srf` with the title's `MSAAppId` as the client and
  `service::user.auth.xboxlive.com::MBI_SSL` as the scope. It gave a code for
  `https://www.microsoft.com/link`, valid 15 minutes and polled every 5 seconds, and no
  `verification_uri_complete`, so the code is always typed. The access token lasts 24 hours, and
  refreshing it handed back a new refresh token as well.
- **No sign-in without a code.** An authorization-code flow could run in a window of sake's own
  with nothing to type, but it needs a redirect the app has registered, and
  `oauth20_authorize.srf` refused `https://login.live.com/oauth20_desktop.srf` and
  `ms-xal-<id>://auth` in three spellings: "The expected value is a URI which matches a redirect
  URI registered for this client application". It says so without anyone signing in.
- **The user token.** Microsoft's "Xbox services sign-in for title websites" gives the request,
  with a `d=` ticket for an Entra token; a login.live.com ticket goes as `t=`. It was issued both
  signed with the key in `Properties` and unsigned without it, and lasts 96 hours.
- **XSTS tokens**, lasting 16 hours where Microsoft's "Xbox services authentication" gives four
  as the default: `http://xboxlive.com`, whose claims name the person (XUID, gamertag, age group,
  privileges), and `http://playfab.xboxlive.com/` and `rp://api.minecraftservices.com/`, which
  carry the user hash alone. Each was issued bound to the device's key and bound to nothing.
- **No title token, so no title table.** `title.auth.xboxlive.com` answered 403 with an empty
  body, and SISU's `/authorize` 401. The title's own table answers 414 to `?type=1` with or
  without a token. Without the query it is 401 to nobody and 403 to every XSTS token above, none
  of which was minted with a title token. SISU's `/authenticate` hands out a session without a
  registered redirect, and `/authorize` refuses the device code's token with that session too
  (sake, 2026-09-30; [below](#account-link-and-playing-with-others)).
- **Where a signature is checked.** `title.mgt.xboxlive.com` refused a key-bound token sent
  unsigned or with a corrupted signature, 401 `invalid_request_signature`, and got as far as its
  403 for a token bound to nothing sent unsigned. `profile.xboxlive.com` read the person's
  gamertag all three ways: bound and signed, bound and unsigned, unbound and unsigned.

### The Keychain under an ad hoc signature

*The night of 2026-09-29, with a throwaway app signed the way `scripts/build-app.sh` signs sake:
ad hoc. Three builds of it differed in one constant, and so in their code directory hash alone.*

- **A build that did not make an item is asked for the login password to read it.** The build
  that added a generic password read it back with no dialog. The next build's read brought
  SecurityAgent's "wants to use your confidential information … To allow this, enter the “login”
  keychain password", with Always Allow, Deny and Allow.
- **Always Allow does not stick.** With the password entered and Always Allow pressed, that same
  build was asked again on its next read. The item's access list still named only the build that
  made it; what had grown was its partition list, by the second build's `cdhash:`. Under an ad
  hoc signature, then, sake would be asked every time it read.
- **The dialog outlives the process that asked, and takes the keyboard.** Ending the process left
  the dialog up, and it answered the next request from the same app. Keys typed elsewhere while
  it was up went into its password field.
- **Two things asked nothing**: a query for attributes alone from a build the item did not trust,
  and deleting the item from the build that made it. The Data Protection Keychain refused the app
  outright, `-34018`, "A required entitlement is not present".

### The runtime in the game

*In the `ex` bottle, with sake's runtime in `system32` and the stand-in's three copies set aside
for the game's runs.*

**The first run** (2026-09-29), with the runtime built by hand and no sign-in yet:

- The launcher passed its Gaming Services check and started the game a second later. The game
  called XError, `XTaskQueue`, XNetworking, XGameProtocol and XUser, and nothing it asked for was
  refused. XGameProtocol is the class `95fd18d2`, registered right after the XGame feature check;
  the other class of its shape, `0651aae2`, is then XGameInvite, which the runtime reports absent
  and the game never asked for. XUser was asked for under its base interface ID, `01acd177`.
- The silent `XUserAddAsync` failed with `E_GAMEUSER_NO_DEFAULT_USER`, and the game drew its
  title scene with "SIGNING IN .." and waited: 3.5 minutes with no further `XUser` call, no
  sign-in window asked for and no HTTP request. Closed from its window, it ran its XSAPI and
  libHttpClient cleanups through the runtime in a quarter of a second and was gone at the next
  three-second sample. `GamingRepair.exe`, which Steam runs before every start, still exited
  `0x80040154`, as it had with the stand-in.
- **So the silent add must not fail**: once it has, the game does not ask again. The stand-in
  shows the way: in its log the silent add succeeds with a placeholder user (XUID 1), the game
  goes on to `LoginWithSteam` and `XUserAddByIdWithUiAsync`, and the stand-in starts Microsoft's
  device-code sign-in when the game first asks for a token — by the owner's account, with a
  browser opening for it — after which the game reached character select.

**The sign-in asked at the silent add** (2026-09-30), first from a probe and then from the game:

- **The probe** loaded the runtime by its path, beside a copy of the game's
  `MicrosoftGame.config`, and asked the way a title may: the silent `XUserAddAsync`, then
  `XTaskQueueTerminate` on the call's queue at once, then dispatching its completion port until
  the termination landed. With no sake to answer, the runtime gave up after 10.1 seconds and
  completed the call. With sake running, sake picked the request up after a second and showed
  its panel, and Cancel there came back as `cancelled`. Both times the call completed on a queue
  already terminating, nothing was refused, and the termination finished.
- **The game, with no sign-in kept.** The silent add came 2.7 seconds after the launcher loaded
  the runtime, before the game had a window. sake picked the request up 3.5 seconds later, most
  of it spent walking the bottle's `Program Files` for the title, so sake now says `waiting`
  before it looks. It showed the code, the browser opened at `microsoft.com/link`, the owner
  signed in there, and 2 minutes 24 seconds after the pickup sake wrote a session holding a token
  for each of the three relying parties. Only then did the add return, and only then did the
  game open its window, on its title scene and "SIGNING IN ..". While the add was pending the
  game called `XAsyncGetStatus` without waiting and dispatched the completion port with no
  timeout, 4.19 million times in two minutes, and made no other call. It terminated the add's
  queue after it had seen the call complete.
- **The game again, with the sign-in kept.** sake answered 2.5 seconds after the request, 1.0 of
  them to pick it up, with no panel, and the kept refresh token was replaced by the new one
  Microsoft handed back.
- **So the silent add is the wrong place to ask.** The sign-in has to start once the game is
  showing its own screen, which is where the stand-in starts it: at the first token request. The
  trap is believing the game already shows "SIGNING IN .." while the add waits; it has not drawn
  anything yet.

**The runtime answering `XUser` itself** (2026-09-30): the silent add at once, with a placeholder
until there is a session, and sake asked at the first token request.

- **The slots, first.** Every `XUser` thunk in `libHttpClient.GDK.dll`, 44 of them, and the one
  for `XUserGamertag`, reach the slot `runtime.h` gives that function with the number of
  arguments its signature has. That edition asks for `XUser` under `26f3c674`, which the runtime
  answers from the same table as the base ID the game uses.
- **The game sent nothing until the runtime sent the notifications the stand-in sends.** With
  the add answered, it drew its window and "SIGNING IN .." and sent nothing, not even a question
  about a URL's TLS. The stand-in, run from outside in a probe, showed two things the runtime was
  not sending:
  - After the silent add, the first dispatch of the completion port of the queue the title
    registered for `XUser` changes brings one `SignedInAgain` for local user 1. With that added,
    the game answered it with `FindUserByLocalId` and still sent nothing.
  - Registering for connectivity hint changes brings one notification, also on the completion
    port, with the hint `XNetworkingGetConnectivityHint` gives. Microsoft's reference for
    `XNetworkingRegisterConnectivityHintChanged` says so as well: it "sends an initial
    notification callback". The game registers twice, the second time from the module that sends
    its HTTP, and with this notification added as well it sent its first request five seconds
    after the change event.

  Whether the game needs `SignedInAgain` too was not tried: every run that got as far had both.
- **The game, with no sign-in kept.** Its window came up, then "SIGNING IN ..", and the game
  logged in to PlayFab with Steam and added, by ID, the XUID PlayFab links to that Steam account.
  Its first token request, for `https://playfabapi.com/`, came 23 seconds after launch, and sake
  picked it up a second later: the panel and the browser opened while the game was showing its
  sign-in, the way the stand-in's sign-in looks. The owner signed in, and 62.6 seconds after the
  request sake had a session and the game its token; the game's telemetry went on meanwhile.
  Tokens for `api.minecraftservices.com`, `rta.xboxlive.com`, `peoplehub.xboxlive.com` and
  `userpresence.xboxlive.com` then came from the session at once, and the game went on through
  `vex.minecraftservices.com` to character select.
- **The game again, with the sign-in kept and the session good.** The silent add returned the
  person, every token came from the session, and the game reached character select with no panel
  and no sign-in.
- **Unsigned tokens were enough.** All 20 token requests were the UTF-8 kind, and every token
  went out with no signature: PlayFab's bound to the device, the rest bound to nothing.
  Microsoft's page says every call to an Xbox service carries a signature from the key its token
  is bound to, and yet the stand-in's log had none of the 416 requests whose headers it recorded
  carrying a `Signature`. `multiplayeractivity.xboxlive.com` looks to have refused its token,
  since the game asked again with `ForceRefresh`, four requests at a time. Each such wave cost
  sake a silent refresh of two to three seconds, and whether the calls got through afterwards
  the runtime cannot see. The stand-in's failed, with an error of its own, and neither run needed
  them for character select.

### Setup builds and places it

*2026-09-30: the GDK Runtime step in setup, then Steam started from sake in the `ex` bottle.*

- **The step** took under five seconds from the button to a runtime in the engine, most of it
  fetching libHttpClient's 3.5 MB. The archive hashed as it had on 2026-09-29, and what it
  unpacked to matched, file for file, the tree unpacked from it then. The DLL carries no path
  from the person's home: libHttpClient is compiled by absolute path, and `__FILE__` had put five
  of those paths into the hand build, which the Makefile now maps to `libHttpClient`. The 82
  `/Users/runner/…` paths still in it are where llvm-mingw built its own libraries.
- **A copy that is not sake's.** With the stand-in's copy in `system32`, starting Steam from sake
  left it alone and said so in the title's log; it hashed as before, and nothing was written
  beside it.
- **sake's own.** With the stand-in's three copies set aside, the next start put sake's copy and
  libHttpClient's licence in `system32`, the copy hashing as the engine's does. Steam's client
  loaded none of it: the runtime's log had no new line 40 seconds after Steam started. Minecraft
  Dungeons II's launcher and game both loaded `C:\windows\system32\xgameruntime.dll`, and with the
  sign-in kept the game reached character select, every token from the session. The start after
  that found the copy already there.

### Account link and playing with others

*The evening of 2026-09-30, in the `ex` bottle with sake's runtime in `system32` and the game's
WinHTTP traced, and against the owner's Windows PC, where Steam runs the same game on Gaming
Services.*

- **Account link is the game's own.** Its settings link the Steam account to a Microsoft one
  through Mojang's service: `POST vex.minecraftservices.com/account/steam/link` with the PlayFab
  and Minecraft tokens the runtime hands over and a Steam ticket, and `…/unlink` to undo it. With
  sake's tokens, unlinking worked and linking answered 500 with no reason in its body, nine times
  in three tries, which the game showed as "Error code: 0029". On Windows the same link worked.
  The person's characters stayed while the accounts were unlinked.
- **The user hash was the difference.** An XSTS token minted from a user token bound to the
  device's key names a different user hash from one minted from the unbound user token, and the
  runtime puts one user hash, the identity's, into every `Authorization` value. sake had minted
  PlayFab's from the bound one, so the game sent PlayFab's token under another hash. Minted
  instead from the unbound user token, with the device's token beside it and the request signed
  by the device's key, the link answered 200 and the game said the accounts were linked.
  Minecraft's token was bound to nothing throughout, so the link does not need a title claim.
- **Multiplayer activity needs a title.** `multiplayeractivity.xboxlive.com` answered 401 with
  `"debugMessage": "Missing title Id claim."` to sake's token, bound or unbound, signed or not.
  XSAPI asks for a new token with `ForceRefresh` on every 401, so each wave cost sake a silent
  sign-in, and enough of them brought 429.
- **No title token through SISU's page either.** SISU's `/authenticate` hands out a session for
  this `MSAAppId` without checking the redirect. The page it returns sends the person to
  `oauth20_authorize.srf` with `ms-xal-00000000497c1b94://auth`, which login.live.com refuses as
  not registered for the app, before anyone signs in, and `/authorize` refuses the device code's
  token with the session or without.
- **Playing together.** Parties, invites and matchmaking are Mojang's, `/spicewood/…` on the same
  service, and the game servers PlayFab's. Joining a party by code worked both ways with the game
  on a Nintendo Switch 2, and with the Mac hosting, the two played a mission together.

### ForceRefresh

*2026-09-30, the game run again in the `ex` bottle once the runtime took `ForceRefresh` to sake
only when no ask had ended in the last 15 minutes.*

- **Before, every one went to sake.** In the day's nine runs of the game on sake's runtime, 112
  token requests went to sake: the first run's sign-in, and 111 with `ForceRefresh`, every one
  for `multiplayeractivity.xboxlive.com`. Each wave of those cost a silent sign-in that rewrote
  the session and the kept sign-in: in the 1.9 minutes of the last run, 26 requests in six
  sign-ins, 4 to 23 seconds apart and 2.0 to 3.5 seconds each.
- **After, one did.** The owner went into the game's world and walked around, and nothing looked
  different. In the 2.5 minutes of the run, eleven token requests carried `ForceRefresh`, all for
  `multiplayeractivity.xboxlive.com`: the seven of the first wave went to sake together and cost
  one silent sign-in of 2.5 seconds, and the four that came 21 and 24 seconds after it were
  answered from the session. The session and the kept sign-in were written once.
