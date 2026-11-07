# Third-party components

BiliKit-Mac by shiinayane, MIT license, pinned at `0d6cb46db6bfc3b54020f3cb20b46c92d5395c4a`.
Source: https://github.com/shiinayane/BiliKit-Mac

The `Vendor/BiliKitCore` directory contains the BiliModels, BiliApplication, BiliNetworking and BiliPlayback modules and playback tests. Original license: `Vendor/BiliKitCore/LICENSE`. A `BiliGlassBridge.swift` adapter exposes the existing DASH bridge and accepts the app's bounded parallel video streamer. The vendor manifest only builds these modules. Local changes add explicit VIDEO-RANGE / SUPPLEMENTAL-CODECS attributes, optional in-memory initialization segment overrides for Dolby Vision compatibility brands, and corresponding bridge routing. The media streaming client exposes a bounded per-host connection limit (default unchanged for upstream callers), while BiliGlass applies its own shared adaptive video limit. Small bounded requests use a bounded pending buffer instead of suspending for every chunk. Transport errors drain already accepted callbacks before propagating, preventing suffix retries from racing prior delivery. The local manifest also enables iOS 26+, and the audio normalization tap declares the iOS 27 availability required by the SDK; older iOS versions retain the playback fallback. The CDN URL policy also exposes HTTPS normalization for scheme-relative and HTTP media sources; host/port/public-address checks still apply to every candidate, including backups. Original notices are retained. No upstream branding or artwork is included.

The media streaming client also accepts an optional per-session proxy dictionary, preserving its credential-free configuration and response validation; upstream defaults are unchanged.

The app UI, API adapter, session storage, download manager and playback lifecycle are implemented separately for Bilibili NEXT.

References consulted, no code copied:
- LyricsX Next (MPL-2.0): https://github.com/wzk112/LyricsX-Next — first-run versus upgrade detection, version/revision receipts, and guide reopening behavior informed an independent Bilibili NEXT guide. No LyricsX source or artwork is bundled.
- Bilibili-thread-ripper (MIT), commit `ee3adaa8cc1afbb29a3d7153e1295e09e42b29e2`: https://github.com/MrTangLuyao/Bilibili-thread-ripper — partial-prefix resume, bounded pieces, shared connection scheduling and CDN recovery informed the independent Swift implementation. The Electron UI and downloader JavaScript are not bundled.
- IINA / mpv architecture: https://github.com/iina/iina
- IINA+ DASH representation model: https://github.com/xjbeta/iina-plus
- Video interactions and favorite-folder API reference: https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/video/action.md and https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/fav/info.md
- Client coin authorization protocol reference: PiliPlus (`1edcc46777619cbbda3049363554a4cbbb453ee0`, `lib/http/login.dart`, `lib/http/video.dart`, `lib/utils/app_sign.dart`) at https://github.com/bggRGjQaUbCoE/PiliPlus and biliuwp-lite (`cbf1572d0177353d73f73781b17308bcfe5a109f`, `src/BiliLite.UWP/Api/VideoAPI.cs`) at https://github.com/xiaoyaocz/biliuwp-lite . Independent Swift implementation of signed QR authorization and the app coin endpoint; no Dart/C# implementation bundled. The protocol application key and signing salt are published client identifiers, not account credentials. User-issued tokens stay in the macOS Keychain and are never included in web cookies or logs.
- DASH URL/SegmentBase variants and notification counter/object schemas: https://github.com/bggRGjQaUbCoE/PiliPlus (`lib/models/video/play/url.dart`, `lib/http/msg.dart`, `lib/models_new/msg/msg_like/content.dart`) and https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/message/msg.md — independently implemented Swift parsing, unread state and native presentation; no Dart code bundled.
- bilibili-API-collect API documentation: https://github.com/pskdje/bilibili-API-collect
- Private-message share schemas, comment submission responses and emote metadata: https://github.com/pskdje/bilibili-API-collect/blob/main/docs/message/private_msg_content.md , https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/comment/action.md and https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/comment/list.md — independent Swift parsing and native views; no implementation or sample account data bundled.
- Official BAS language specification (independent Swift parser and native renderer; no JavaScript runtime or implementation copied): https://bilibili.github.io/bas/ and https://github.com/bilibili/bas
- DanmakuFlameMaster mode 7 data format reference (no implementation copied): https://github.com/bilibili/DanmakuFlameMaster
- Apple Liquid Glass: https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views
- Account video-history cursor schema: https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/historytoview/history.md — independently implemented native paging, source selection and playback resume.
- Viewing-progress report schema: https://github.com/pskdje/bilibili-API-collect/blob/main/docs/video/report.md — independently implemented throttled progress sync; old device history is not replayed.
- Official Bilibili video page interaction behavior: https://www.bilibili.com/ — inspected the public player bundle for the unified archive relation endpoint and one-click triple response fields; no site JavaScript or account data bundled.
- AVPlayer fast-forward behavior and I-frame fallback: https://developer.apple.com/library/archive/qa/qa1772/_index.html

This is an unofficial client. Bilibili names, videos, thumbnails and account data belong to their respective owners.
