# Android → iOS parity

What the Android app (`../miruro-apk`, phone flavor) does, and where the iOS port stands.
The UI follows the Android app's current Compose code, not its old README screenshots: it is
dynamic (themes, glass, per-show colours), so the code is the reference.

Legend: ✅ done · 🟡 partial · ⏳ planned (phase) · ➖ not applicable on iOS

## Phase 1: design system, shell, Home (pushed)

| Feature | Status | Notes |
| --- | --- | --- |
| Theme engine (AMOLED/dark, monochrome default, 11 accents, custom colour, Vivid/Tonal/Neutral/Vibrant, contrast) | ✅ | Google's material-color-utilities (same library as Android's materialkolor), Android's tests ported |
| Theme presets (Midnight … High contrast) | ✅ | |
| Accent in the player | ✅ | Play button and seek bar |
| Colour anime pages by the show | ✅ | The show page (phase 3) |
| Liquid glass per section (nav bar, Home, Details, Browse, Popups, Refresh) | ✅ | Liquid Glass on iOS 26, frosted materials on iOS 18–25; painted fallback when off |
| Bottom navigation (Home, Search, Downloads, My List, Settings) | ✅ | The system tab bar (SwiftUI `Tab`): Liquid Glass on iOS 26 with Search apart, shrinks on scroll down; Android's floating pill replaced |
| ANILILI wordmark tinted with the accent | ✅ | Android's PNG mask |
| TV layout (Android's `form_factor_preference`): top navigation with Schedule as a tab, full-bleed spotlight, large rails and wide Continue cards, the show page over its artwork with an episode rail, player always fullscreen | ✅ | The iPad's by default (Settings → App → Layout; Phone or tablet goes back); Slide Over and narrow Split View windows get the phone layout. Touch, not D-pad focus. Grids widen to 4/6/7 columns on an iPad |
| Water-fill logo loader | ✅ | |
| Poster card: score, DUB (media index), 18+, title, details line, long-press actions | ✅ | Long press = context menu |
| Card details (which badges show) | ✅ | |
| Home header: wordmark, notifications, schedule, genre pills | ✅ | |
| Spotlight carousel (countdown, pager, meta strip, series logo, genres, 7 s advance) | ✅ | Logo from the media index when Series logos is on, else the title |
| Home rows: Continue Watching, For You, Because you watched, New Episodes, Trending, Popular This Season, Top Rated, Movies, Upcoming | ✅ | For You / Because from the neighbour graph (phase 7) |
| Rail Expand / Carousel | ✅ | Load More in expanded grids too |
| Arrange Home (order + hide, Android's stored encoding) | ✅ | Drag on Home itself: later |
| Dice (random pick) | ✅ | The swipe deck (phase 7) |
| Browse: search, category chips, filters (genres, format, status, season, year, decade, episodes, score, country, source, dubbed only, sort), paging | ✅ | Tags/exclusions, studio search, "hide watched": phase 2 |
| Settings: grid, search and every page | ✅ | Accounts, Subtitles, Downloads, Servers, Notifications and Data since phases 5–6 |
| Android setting keys and defaults | ✅ | Backups will map 1:1 |

## Phase 2: Browse extras, Schedule, Notifications (pushed)

| Feature | Status | Notes |
| --- | --- | --- |
| Genre and tag chips cycling include → exclude → off, tag search over all AniList tags | ✅ | |
| Filter sheet pages: General, Release, Genres, Tags, Studio, with counts | ✅ | |
| Studio filter (search, or a show page's studio chip) via Android's 500-id studio query | ✅ | |
| Hide watched (completed / anything started) | ✅ | From this device's history |
| Active filters as removable chips, search history | ✅ | |
| Local title-list search when AniList's whole-word search comes back thin | ✅ | Media index `index.json`, desktop ranking |
| Schedule: day strip / month calendar with counts, timeline of air times, cards | ✅ | Media index month files, AniList fallback |
| Episode reminders (10 min before, "Episode N airs soon"), tap opens the show | ✅ | Local notifications |
| Notifications page: AniList feed | ✅ | Phase 5; release alerts for saved shows: phase 6 |
| Home: Load More in expanded rows; bars tuck away on scroll | ✅ | |

## Phase 3: show page (pushed)

| Feature | Status | Notes |
| --- | --- | --- |
| Show-coloured page (cover colour as the seed, viewer's canvas/style/contrast kept) | ✅ | |
| Hero: banner, cover with zoom preview, series logo (media index) or title, studio badge → Browse | ✅ | |
| "85% score · 1.1M members · 25 episodes", Add to list menu, Watch / Continue N, series progress | ✅ | List status sheet (phase 5) |
| Series "mark all watched" eye | ✅ | In the list sheet (phase 6) |
| Home / Episodes / Related tabs (Episodes hidden for movies), pinned | ✅ | |
| Home: stat cards, next-episode countdown card, genres, Overview, trailer card, metadata card | ✅ | |
| Episodes: seasons of the franchise, sub/dub, 100-episode blocks, filter/jump, newest/oldest, list/grid | ✅ | |
| Episode rows: stills (Miruro → media index → AniList), EP tag, filler tag, progress, watched eye, spoiler blur, unaired rows with air date | ✅ | |
| Per-episode download button | ✅ | Phase 6 |
| Related: watch order shelves (desktop `franchise.rs` port) numbered on the Episodes tab's season chain, shown from the page's own relations before the walk lands, release/story order, More like this without the franchise, artwork/titles layout toggle, play buttons | ✅ | |
| Share `anilili://anime/<id>` | ✅ | Opened by the app since phase 7 |

## Phase 4: watch page and player (pushed)

| Feature | Status | Notes |
| --- | --- | --- |
| Watch page: player on top, episode info, show row, server picker, sub/dub, episode list with filter and progress | ✅ | |
| Custom controls: play/pause, ±10 s, prev/next, seek bar with intro/outro markers, times, clock and finishing time | ✅ | |
| Gestures: double-tap seek, hold for speed, brightness/volume, drag to seek, lock | ✅ | Volume through the system's hidden slider, mounted only during a drag so the side buttons keep the system's indicator; vertical drags from the top and bottom 56 pt (Control Center, home) are ignored |
| Fullscreen: turning the phone or the button, landscape only in the player | ✅ | iPad: only the button (the app can't turn it); held sideways the page sits beside the player. TV layout: always fullscreen |
| Speed, quality ladder (HLS variants), screen size (fit/stretch/zoom) | ✅ | |
| Soft subtitles (Miruro ssub VTT, SRT), local subtitle import, size, box, delay, default language | ✅ | ASS styling and OpenSubtitles: later |
| Server picker: Sub/Dub and language filters, one line per server (how it carries subtitles, languages, can download, why it failed), failover, stall watchdog | ✅ | `ServerSummary` follows Android's `SourceLanguages`; the watch page's server pill opens the same sheet |
| Skip intro/outro (button + auto with countdown), +85 s skip without timings, timings from the media index's AniSkip mirror, then AniSkip | ✅ | Android's credits rule for outros |
| Up Next card with countdown, autoplay at the end | ✅ | |
| Pause overlay after 15 s (series logo, episode, synopsis) | ✅ | |
| Progress saved every 5 s; watched at 80% | ✅ | |
| Lock-screen info and remote commands, PiP, AirPlay | ✅ | |
| Chromecast | ➖ | AirPlay instead |
| External players (VLC, Infuse) | ✅ | URL schemes; Miruro servers need headers those apps can't send |

## Phase 5: accounts and sync (pushed)

| Feature | Status | Notes |
| --- | --- | --- |
| AniList sign-in (implicit grant, client 45552) in a web view that catches the `localhost` redirect | ✅ | Token in the Keychain; JWT expiry checked; a 401 signs out |
| MyAnimeList sign-in (PKCE plain), token refresh with rotation | ✅ | |
| One service at a time; switching clears the old account's snapshot | ✅ | |
| Accounts page: profile and stats, refresh, sign out, sync switches (Android's keys) | ✅ | |
| List status sheet on long-press and the show page: five statuses, custom lists / MAL tags, remove from list | ✅ | |
| Your score (`AnimeScoreDialog`): whole points 10 to 1 with Android's labels, Remove score, half-point AniList scores shown as they are; for titles on the account only | ✅ | In the list sheet, the long-press menu and the show page's star |
| Progress sync when an episode passes the watched threshold (never regresses; Paused/Dropped/Rewatching kept) | ✅ | Failed pushes retried on the next refresh |
| Watchlist ↔ Plan to watch, both ways (Android's removal rule) | ✅ | |
| My List: every status, custom lists, Favourites, plus the device's lists | ✅ | Sort and new-episode badges: phase 6 |
| My List signed out: "Your anime, in one place" card, Continue with AniList / MyAnimeList with the services' logos | ✅ | Logos drawn from Android's vector drawables (`SVGPath`); Link a TV ➖ |
| Account sheet from the profile pill: banner, avatar, View profile, headline totals; Overview (your anime, continue watching, recent activity), Stats (activity heatmap and streak, highlight tiles, status breakdown, formats, genres, studios, release years, score spread), Activity feed; Sync now, Log out | ✅ | Android's `AccountSheet`. The heatmap merges AniList's `activityHistory` with episodes finished on this device (`WatchActivityStore`, counted from this build on) |
| Continue Watching seeded from the account's Watching list | ✅ | Removing a seeded row hides it here |
| AniList notifications page, unread badge on the bell, marked read on open | ✅ | |
| Rows moved off Watching elsewhere leave Continue Watching | ⏳ | Later |
| Series "mark all watched" eye | ✅ | Phase 6 |
| Token sent on every AniList request once signed in, with a Referer | ✅ | Android's measured outage behaviour |

## Phase 6: library, downloads, settings, data (pushed)

| Feature | Status | Notes |
| --- | --- | --- |
| Backup / restore in Android's `anilili-backup` v1 format, either direction | ✅ | Opens the shared parity fixture; settings, watchlist, Continue Watching, searches |
| Logins sealed under a passphrase (PBKDF2-HMAC-SHA256 + AES-GCM) | ✅ | AniList token both ways; a MAL hand-off code from Android signs in on restore |
| Device-only custom lists from an Android backup | ⏳ | Reported, not kept; account lists sync once signed in |
| MyAnimeList XML export | ✅ | Account list, or the device's saves and history |
| Downloads: HLS/MP4, soft-sub sidecars, single-MP4 conversion, two at a time, failover, resume | ✅ | HLS remains as a fallback when system export cannot convert it; foreground only |
| Per-episode download button, "download these episodes", Downloads tab per show, offline playback | ✅ | The server picker's arrows save from that server (iOS addition; Android's are only a marker), the rest tried behind it if it fails |
| Download quality, space used, remove all | ✅ | Android's `download_quality` |
| Background downloads, save as MP4 for other apps | ⏳ | Later |
| My List: sort, "N NEW" badges, progress tags | ✅ | |
| Series "mark every episode watched" (Completed on the account) | ✅ | In the list sheet |
| Settings → Subtitles: defaults, language, Android's full caption style with preview | ✅ | OpenSubtitles, ASS styling: later |
| Settings → Servers: on/off and order (Android's `disabled_providers`, `server_priority`) | ✅ | |
| Settings → Notifications: new-episode alerts for followed shows | ✅ | Local notifications scheduled on open, two weeks ahead |
| Diagnostics | ✅ | Debug log with copy/share |

## Phase 7: extras (pushed)

| Feature | Status | Notes |
| --- | --- | --- |
| Random swipe deck (right to watch, left for another, WATCH/SKIP stamps, every third card from your taste) | ✅ | Android's deck logic and pool; opens and skips feed the taste signals |
| `anilili://anime|watch|search` links | ✅ | Passes the shared parity corpus; scheme registered |
| For You / Because you watched from the media index neighbour graph | ✅ | Desktop `recs.rs` port with its tests; AniList recommendations as fallback |
| What's new tour | ✅ | Same id and copy as Android, as cards over Home |
| Profiles and profile lock | ➖ | Television only on Android |
| Announcements | ✅ | BIP-340 Schnorr checked in Swift against the project key; mirror then Nostr relays; bounded ones (Android build numbers) skipped |
| App icon matching the theme | ✅ | Ten alternate icons from `scripts/generate_icon_variants.py`, placed by xtool.yml `resources:` |

## Servers (Android's `ProviderCatalog`)

Android asks Miruro's servers and about thirty of its own scrapers. iOS ports them in batches,
each from Android's code with Android's parser tests; live checks are gentle (one title,
sequential, paced) and Cloudflare-gated sites are checked from the Mac, not the PC.

| Server | Status | Notes |
| --- | --- | --- |
| Miruro (bee, sun, hop, kiwi, knob…) | ✅ | Every server with a stream; kiwi (animepahe) back since the proxy writes out Kwik's IVs. The visible `embed` entries (bun: anikoto's MegaPlay pages; cog: animegg's) play in the web player, as on Android |
| AniChan | ✅ | Ported and unit-tested; Cloudflare-gated, so first live check is on the Mac |
| Ani.pm | ✅ | Same |
| Zoko | ✅ | Live-checked: 28 sub / 28 dub found in four requests, 1080p plays |
| AnimeHeaven | ✅ | Recaps ("1100.5") no longer play as the episode below them |
| Lili (xfdm) | 🟡 | Ported (media index URLs) but off: the file host answers 401 since 2026-10 (Android too) |
| AnimeOnsen | ⏳ | DASH; needs a DASH-to-HLS step in the proxy |
| HStream (adult) | ✅ | Live-checked from the PC: Imaizumin-chi (132203) lists 6, episode 1 resolves through the page's session cookie and CSRF token to an MP4 and `eng.vtt` that serve bare. Android's 720p DASH lead is left out (no DASH in AVPlayer); the site's own H.264 MP4 plays instead, on two mirrors in turn. AV1 1080p+ skipped. Playback on a device not yet seen |
| Hentai Haven (adult) | 🟡 | Ported and unit-tested; its Cloudflare challenges Linux's OpenSSL, so its live check is on the Mac. Verified on pages fetched from Windows: 1,051 series, Imaizumin-chi lists 6, the octopus manifest with 26 subtitle files. Those files are rendition URIs AVPlayer won't load, so the proxy drops them (`StreamRewrite.droppingFileSubtitles`) and they're sideloaded; the video has no burned-in subtitles. Playback on a device not yet seen |
| Hanime (adult) | 🟡 | Catalogue and matching are plain HTTP and live-checked (Imaizumin-chi lists 6). Streams come from `HanimeResolver`, a hidden WKWebView (412×892 inside a clipped 1-point box behind the app) with a `JSON.parse` hook, after Android's `HanimeBridge`: written, not yet built or run on the Mac |
| AniKoto (MegaPlay) | ✅ | Live-checked: 28/28, nine subtitle languages; the `enc` blob decrypted as Android does (pinned live fixture). Its MegaPlay page follows as a web player, and stands in when the stream can't be read |
| KickAssAnime | ✅ | Live-checked; sub and dub are one master, the track picked by `VideoSource.audioLanguage` |
| AnimeKai | 🟡 | Ported and unit-tested; unreachable from the PC's network (IPv4 and IPv6 time out), so unverified. When no embed names its stream, the embeds play in the web player (Android's fallback) |
| AniDB App | ✅ | Live-checked through the Anilab catalogue: anidb.app now redirects to anilab.so (Android likely misreads that as "not found") |
| AniZone | ✅ | Live-checked; results, stream and ASS subtitles now come out of the page's Livewire JSON. ASS read as text (`Subtitles.parseASS`) |
| AnimeGG | ✅ | Live-checked: MP4 mirrors, sub and dub |
| AniNeko | ⏳ | Its search answers a near-empty page from here (a script challenge?) |
| 2Dhive | ⏳ | Mostly MegaPlay (AniKoto covers it); BabaStream needs a proof-of-work token |
| AllAnime | ⏳ | Android measured 0/4 resolves; captcha and crypto heavy |
| UniqueStream | ✅ | Live-checked: 28/28 with soft subtitles; its gated AES key is synthesized from the media id and served by the proxy (`VideoSource.aesKey`) |
| AnimeAV1 (Spanish) | ✅ | Live-checked (VOE); declared Spanish, so it leads only when Spanish is the preferred language and trails otherwise. MP4Upload not ported |
| Kartoons (Hindi), AnimeRift (Arabic) | ⏳ | Private APIs: Kartoons runs on the project's pooled account tokens, AnimeRift registers a device through Firebase |
| RareAnimes (Hindi, Tamil, Telugu) | ✅ | Live-checked: 28 dub, the argon player through codedew. RSS search, season posts stitched to AniList's numbering. Declared Hindi. Android's juicycodes pre-check not ported |
| AnimeDekho (Hindi) | 🟡 | Live-checked on animedekho.tv: 28 dub found, but Frieren's mirrors were all the site's own "This Server is Down" page, which iOS doesn't offer (Android lists it last) |
| ToonHub4u (Hindi) | ✅ | Live-checked on toonhub4u.live: 28 dub, nine player pages (AbyssPlayer, VidMoly, Ruby …) |
| AnimeKhor (donghua) | ✅ | Live-checked on Swallowed Star: 26 episodes, five mirrors (ok.ru, StreamLare …). Asked only about Chinese titles, as on Android |
| One Pace | ⏳ | Not on AniList; needs its own entry in the app |
| AnimePahe (direct), ReAnime | ⏳ | Batch 4: a hidden web view on Android too |

The adult-only servers (HStream, Hentai Haven, Hanime) are asked only while Settings → Content →
Hide adult content is off, as on Android, and are hidden from Settings → Servers while it's on.
iOS asks them only about adult titles, and ahead of the other servers there. An adult title AniList
can't count (released, `episodes` null, no next airing: nearly every running hentai OVA series)
takes its episode list from the adult servers alone when any of them has it (Android's 97fadd44),
so a general server's mismatched listing can't put 50 rows on a six-episode title.

The on-device stream proxy (`StreamProxy`, after Android's `LocalStreamProxy`) carries each
server's headers to every request, unwraps segments disguised as images (a PNG in front of the
TS on Miruro's `bee · HD-1`, image content types on most CDNs) and writes out Kwik's implicit
AES IVs. A source that fails through it is tried once directly before the next server.

Servers that only offer a third-party player page ("embeds") play in `EmbedWebPlayer`, after
Android's `EmbedWebView`: a WKWebView that plays inline with the page's own controls, drops
popups, keeps the main frame on the embed's site once it has loaded, refuses Android's list of
ad and analytics origins (a content rule list), and reads the video's clock from every frame
once a second to save progress and go on to the next episode. Web players come after every
stream the app plays itself, don't end the hub's wait for slower servers, and aren't offered for
download or to external players. Not ported: Android's touch shield, caption restyling, the
load and silent-page watchdogs that fail over to the next server, and remote play/pause.

## Settings, row by row (Android's `SettingsScreen.kt`)

The index is Android's: search (ranked like `searchSettings`, recent searches as completions,
the picked row scrolled to and marked) over a grid of eleven section tiles. Every row is title,
one line and the current value; the explanation lives in the picker the row opens.

| Section | Android rows | iOS |
| --- | --- | --- |
| Player | Play on open, open in external player, external player, autoplay next, mini player, details when paused, auto-skip, skip button and its length, watched at, default quality, buffer size, playback speed, audio language and second choice, screen size, prefer dub, clock, hold to change speed and hold speed, brightness/volume gestures, drag to seek, status bar | ✅ every row, wired into the player (VLC/Infuse as the external apps; buffer is AVFoundation's forward buffer; the status bar only shows where iOS allows one, so not on an iPhone in landscape). Plus the iOS player debug overlay |
| Subtitles | Show by default, also on dubs, preferred and second choice language, caption appearance, OpenSubtitles, search language | ✅ Android's three-letter codes (older iOS two-letter values still read); caption appearance in its own sheet with font and horizontal placement added. OpenSubtitles rows shown switched off, as on an Android build without a key |
| Downloads | Resolution, where downloads go, save location | ✅ resolution, space used, remove all. ➖ destination and location: an iPhone keeps an app's files to itself |
| Servers | Enabled servers, server priority (up to 3), preferred server languages, DNS over HTTPS | ✅ the first two as Android's pickers. ➖ server languages (iOS servers carry no language tags yet), DoH |
| Accounts & sync | AniList, MyAnimeList, link a TV, sync progress, sync watchlist with Planning, MAL tags as lists, Discord | ✅ all but ➖ Link a TV and Discord |
| Notifications | Notification alerts, announcements | ✅ |
| Content | Hide adult content, only episodes you can watch | ✅ the second hides caught-up titles from Home's Continue Watching until the next episode is on the servers |
| Appearance | Everything | ✅ (pickers explained, Card details summary as Android). ➖ background image, layout and interface size (TV) |
| Data | Back up, restore, export and import MAL XML, video cache, clear cache, re-download metadata, clear history | ✅ all but ➖ video cache (AVPlayer keeps none on disk). Clear cache clears images and API pages; re-download needs no restart |
| App | Menu language, layout, check for updates, send diagnostics | ✅ menu language (Spanish tab labels), layout (iPad only, Automatic = TV), version, diagnostics as a redacted text report through the share sheet, debug log, and Android's update rows: Check for updates on launch (`update_check_on_launch`) and Check for updates. The signed manifest (`anilili-ios-update`, mirror then relays, `AppUpdate`) pops a new version up with its notes; a rebuild of the same version waits in Settings, as on Android. Install hands the IPA to SideStore or AltStore (or Safari, for Sideloadly); iOS can't replace the app itself |
| About | Discord server with its mark, the sign-off | ✅ |

## Not applicable on iOS

D-pad focus, TV pairing, profiles (television only), Android external-player
intents, APK self-update, Material You wallpaper accent, Discord rich presence (no background IPC
on iOS), DNS over HTTPS (needs a network extension).
