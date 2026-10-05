# Changelog

## [0.2.1](https://github.com/typester/sake/compare/v0.2.0...v0.2.1) (2026-10-02)


### Bug Fixes

* find what runs in a symlinked bottle by what the link points at, because Stop killed only its wineserver ([#23](https://github.com/typester/sake/issues/23)) ([16cc4f2](https://github.com/typester/sake/commit/16cc4f2933704e5acbb2089261afd308326c09b7))
* log what runs in each bottle to a directory of its own, because the same title in two bottles shared one log ([#24](https://github.com/typester/sake/issues/24)) ([ca8f5f7](https://github.com/typester/sake/commit/ca8f5f716eab51fc95aa60ca074498db0c75e4a3))

## [0.2.0](https://github.com/typester/sake/compare/v0.1.2...v0.2.0) (2026-10-01)


### Features

* run GDK titles with a runtime and an Xbox sign-in of sake's own, because Wine has no Gaming Services and they will not start without it ([#16](https://github.com/typester/sake/issues/16)) ([8d9e050](https://github.com/typester/sake/commit/8d9e05049661b96c572bdd743bd703bb3f54ed97))


### Bug Fixes

* answer ForceRefresh from the session, because a service refusing every new token had sake sign in every few seconds ([#20](https://github.com/typester/sake/issues/20)) ([d75f646](https://github.com/typester/sake/commit/d75f646fa1839196adaaecc90449fc57822c926b))
* leave macOS's AppleDouble files out of directory listings, because on exFAT a game read one as its settings ([#18](https://github.com/typester/sake/issues/18)) ([3551d01](https://github.com/typester/sake/commit/3551d0136186a70dc3ad3aa755475e0c52933f97))
* mint PlayFab's token from the same user token as the rest, because under another user hash linking failed ([#19](https://github.com/typester/sake/issues/19)) ([dd4f885](https://github.com/typester/sake/commit/dd4f88527a43091c2abedc8ba6dc5d3aaeb80f41))
* send an engine built from other patches back to its step, because a new patch never reached an engine already built ([#21](https://github.com/typester/sake/issues/21)) ([902cf5c](https://github.com/typester/sake/commit/902cf5cac2c1fd7b8050ca665ed96fe54398a99d))

## [0.1.2](https://github.com/typester/sake/compare/v0.1.1...v0.1.2) (2026-09-28)


### Bug Fixes

* generate Wine's include/ first, because makedep leaves some objects not depending on headers they include ([#12](https://github.com/typester/sake/issues/12)) ([471f790](https://github.com/typester/sake/commit/471f7906b8b43f25557ea6d1261f858eadb4b979))

## [0.1.1](https://github.com/typester/sake/compare/v0.1.0...v0.1.1) (2026-09-21)


### Features

* hand a bottle Wine's own tools, because what they set lives in the bottle and not in sake ([#6](https://github.com/typester/sake/issues/6)) ([514a99d](https://github.com/typester/sake/commit/514a99dc30ad360622f271c474b9814c106de60f))
* let a title carry its own environment, because a variable one game needs is not the bottle's business ([#5](https://github.com/typester/sake/issues/5)) ([c82b105](https://github.com/typester/sake/commit/c82b1055b16abaf5f68dca55f9c3aa11c6c44062))


### Bug Fixes

* drop a glyph that distinguished nothing and an import with no bottle to take from ([#2](https://github.com/typester/sake/issues/2)) ([46c102b](https://github.com/typester/sake/commit/46c102bc77a092051f4f5174f2fe0595f5337d44))

## [0.1.0](https://github.com/typester/sake/compare/v0.1.0...v0.1.0) (2026-09-21)


### Documentation

* record the two runs that were only ever spoken, and hand the README a brew line ([77901a7](https://github.com/typester/sake/commit/77901a7795587ed2aa9f2ee878c5a310adf2ba72))
