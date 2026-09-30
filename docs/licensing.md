# The licence boundary

sake builds everything from source except two things, and the distinction decides what the
app may and may not do on the user's behalf.

## MoltenVK: redistributable

Apache-2.0. The upstream Khronos release is used as-is purely to save a build; rebuilding it
would change nothing legally.

## Apple's D3DMetal: not redistributable

D3DMetal is closed source under an evaluation-only licence. **sake must never ship it,
download it on the user's behalf, or copy it out of an installed CrossOver.app** — that copy
is one CodeWeavers licensed, not ours to move.

What sake may do is guide the user through supplying it themselves:

1. Point them at <https://developer.apple.com/download/all/> and the Game Porting Toolkit.
   A free Apple ID is enough; the paid Developer Program is not needed.
2. Have them open the `.dmg`, which gives the outer volume.
3. Mount the nested evaluation-environment dmg and copy `redist/lib` into the Wine install.

Accepting Apple's licence is the user's act, not something the app should perform for them.
This is why no open-source launcher bundles D3DMetal and why they all make you supply it.

### What sake actually does

Implemented and measured on 2026-09-19. `redist/lib` on the evaluation-environment volume is
68 MB and holds exactly this:

```
external/D3DMetal.framework        67 MB, three symlinks inside it
external/libd3dshared.dylib
wine/x86_64-unix/*.so              d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx
wine/x86_64-windows/*.dll          the same six
```

sake mounts the nested image with `hdiutil attach -nobrowse -readonly`, copies that tree into
`~/Library/Caches/Sake/d3dmetal`, **unmounts it again**, and copies it from there into the
engine. Unmounting is the point of keeping the copy: nothing afterwards needs the image, and
an image left mounted follows the app around — `runtime.md` has what that cost. An image
the user opened themselves is left alone; only what sake mounted is put back.
Added 2026-09-20.

Three things about that worth keeping:

- **The PE half replaces Wine's own d3d10/d3d11/d3d12/dxgi.dll.** Apple's are a fifth to a
  third of the size and carry `D3DMetalDLLs` where Wine's import `vkd3d_*`, which is how sake
  checks the right ones are in place. Wine builds no unix-side `d3d*.so` at all, so only the
  PE half is ever undone.
- **The image does not have to stay mounted, and must not.** See above.
- **There is no `i386` directory.** D3DMetal is x86_64-only, so 32-bit processes get nothing
  from it. CrossOver fills that gap with DXVK and DXMT for i386; the d4-mac prototype did not,
  and covered the 32-bit GPU need with `--use-angle=vulkan` instead.

### Why the cache copy is inside the line

Wine's `make install` writes its own d3d11/d3d12/dxgi back over Apple's, so D3DMetal has to
go in again after every one. Sending the user back to find the image each time would be
miserable, so sake keeps its own copy of `redist/lib`.

That copy is **the user's**, made on their machine from media they obtained under Apple's
licence. sake does not distribute it, does not put it on a network, and deletes it with the
cache. That last one stopped being a promise on 2026-09-19: uninstalling takes
`~/Library/Caches/Sake` away whole, and a test asserts both that `d3dmetal` is inside it and
that it is gone afterwards, so the day somebody moves the cache copy elsewhere the test says
so. The three things sake must never do are unchanged: it does not ship D3DMetal, does not
download it on the user's behalf, and does not take it out of an installed CrossOver.

## Importing out of a CrossOver bottle

sake can clone a game the user already installed under CrossOver into one of its own
bottles. That is a different act from the one forbidden above, and the line is worth stating
because the two look alike.

What moves is the user's own software: the game and its data, installed under its own
licence, staying on the machine it was installed on. sake copies it locally, distributes
nothing, and only ever reads the source.

What does not move is **anything in `drive_c/windows`**. That is CrossOver's Wine — their
build, their licence, and in a bottle with D3DMetal in it, exactly the copy the section
above says sake must never take. The import looks at `Program Files`, `Program Files (x86)`
and `ProgramData` and at nothing else, so it is kept away from that directory by
construction rather than by a filter someone could later relax.

## Running an installer the user supplied

The other way into a bottle is the game's own installer, and it stays on the same side of
the line as the toolkit. **sake never fetches one.** Downloading a game's installer means
accepting the terms of whoever made it, and that is the user's act — the same reason the
D3DMetal step points at Apple's download page instead of reaching for it.

What sake does is run a `.exe` or `.msi` the user already has, in the bottle they chose,
with the environment `runtime.md` describes. The file stays where it is; nothing is copied
into the app, and nothing about the installer is redistributed.

## Wine and the patches

Wine is LGPL, which is why CodeWeavers publish CrossOver's sources at all, and why this whole
approach is possible.

Any patch sake carries against Wine's own source is a derivative of LGPL code and is
**LGPL-2.1-or-later**, regardless of the licence on the rest of this repository. They live in
`patches/`, which carries Wine's own `COPYING.LIB` as its `LICENSE` and says so in its
`README.md`. A patch belongs nowhere else — burying one in `Sources/` to make a build system
happy would hide the one thing about it that has to be visible.

## GDK titles

For titles built on Microsoft's GDK, sake provides its own stand-in for the Gaming Runtime
(`gdk.md`). It never ships, downloads or copies Microsoft's GDK or Gaming Services, and it
takes nothing from the community stand-in, whose repository has no licence. Its task queue
and `XAsync` are libHttpClient's, which is Microsoft's and MIT-licensed: fetched at a pinned
commit rather than kept in this repository, and contained in any DLL built from it, so
libHttpClient's licence goes wherever that DLL goes. From WineGDK it takes facts and no text:
which IDs the interfaces have and the order of their slots. This section used to say code
would start from the part of WineGDK its author declared CC0; the part worth taking turned out
to be libHttpClient's, under an LGPL header there (`gdk.md`). Signing in uses the title's own
`MSAAppId` from its `MicrosoftGame.config`; sake signs in as no other application, and every
request made while finding out how used that ID alone. Its requests are the shapes Microsoft's
documentation gives where it gives them and otherwise what the services accepted
(`gdk.md`); none comes from the stand-in or from Xodus.

## Why D3DMetal cannot simply be avoided

Metal is documented and anyone may write against it, but it is not open the way Vulkan is —
no external governance, no conformance suite, no independent implementations. Non-Apple
DirectX→Metal translators do exist: **DXMT** (open source, Metal-native D3D9/10/11, bundled
by CrossOver as `winemetal`), **DXVK + MoltenVK**, and for DX12 **VKD3D-Proton + MoltenVK**,
whose source is even in CrossOver's own tarball. So an open path for DX12 exists; it is just
not usable yet. Two structural reasons, both only Apple can fix:

1. **Metal has no GPU virtual addresses.** DX12 refers to resources by GPU VA, which ray
   tracing needs intrinsically. Apple holds that argument buffers suffice, but an argument
   buffer encodes references into a separate buffer, so raw pointers cannot be emulated
   cheaply.
2. **DXIL → Metal IR.** Open translators must go DXIL → SPIR-V → MSL, losing information at
   each hop. Apple's Metal Shader Converter goes straight from DXIL to Metal IR, and Apple
   own the compiler and the IR.

The most telling fact: CodeWeavers, the one company with a commercial incentive to avoid it,
licensed Apple's D3DMetal rather than writing their own.

## Alternatives that were rejected

- **Sikarugir** (the renamed Kegworks, itself the maintained Wineskin successor) advertises a
  D3DMetal toggle, but it is not open source: no licence in its repository, 775 KB with no
  application source, and a Homebrew cask that installs a prebuilt `.tar.xz` whose postflight
  strips quarantine and re-signs the app. Not auditable. It does *not* redistribute D3DMetal,
  so the closed parts are a choice rather than a licensing necessity.
- **Apple's `apple/apple/game-porting-toolkit` Homebrew formula** is genuinely LGPL and was
  useful as a reference for build configuration, but its last commit is 2023-11-16 and it
  builds CrossOver 22.1.1.
- **Bourbon 26** is commercial and closed, which defeats the purpose.

## Rosetta, and the real long-term constraint

Wine here is x86_64 and D3DMetal ships x86_64 only, so this depends on Rosetta 2. macOS 27
is the last release with full Rosetta; macOS 28 keeps only a subset aimed at older games, and
whether a current x86_64 Wine qualifies is not documented.

CodeWeavers are not waiting to find out: as of 2026-07-31 they ship Mac ARM64 CrossOver builds
using a custom FEX, and Wine 10.0 has full ARM64EC support. **The longer-term constraint is
not Rosetta but D3DMetal being x86_64-only** — `d3dmetal.c` is itself wrapped in
`#if defined(__x86_64__)`.
