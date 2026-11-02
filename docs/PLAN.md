# Port plan: Android → iOS, phase by phase

The working plan for finishing the iOS port. `docs/PARITY.md` is the status table; this file says
**how** each phase gets done, in order. Update both as phases land.

## Ground rules (every session)

- **Start with `git pull`.** The Mac also commits (build fixes). Commit as
  `sanilili <338052299+sanilili@users.noreply.github.com>` only; push only to `origin`
  (iosrepo1, private) with `gh auth switch -u sanilili`, then switch gh back. See `AGENTS.md`.
- **Reference is the Android app's current code** in `../miruro-apk/app/src/main/java/com/anilili`,
  not its old screenshots. Fresh screenshots: emulator `anilili_phone` (emulator-5554), package
  `com.miruronative.debug`, `adb exec-out screencap -p`. Install the latest
  `miruro-apk/app/build/outputs/apk/mobile/debug/Anilili-debug.apk` first. Copying from the Android
  repo is fine; never push from it.
- **The desktop app (`../anilili-desktop/crates/core/src`) has Rust ports** of most Android logic
  (`backup.rs`, `links.rs`, `franchise.rs`, `aniskip.rs`, `mal.rs`, `anilist.rs`, `recs.rs`,
  `opensubtitles.rs`, `storyboard.rs`). They are often shorter to port than the Kotlin.
- **Logic goes in `AnililiCore`** (Foundation only, Swift 6) with Swift Testing tests run in WSL:
  `wsl -d Ubuntu-24.04 -- bash -lc 'rsync -a --delete --exclude .git --exclude .build /mnt/c/Users/Admin/Documents/anilili-ios/ ~/src/anilili-ios/ && cd ~/src/anilili-ios && swift test'`
  Live checks: `ANILILI_LIVE=1 swift test --filter Live`.
- **UI goes in `Sources/Anilili`** (SwiftUI, iOS 18, Swift 5 mode). It cannot compile on the PC
  unless a `darwin.xtoolsdk` from the Mac is installed (`xtool sdk install <path>`), so be
  conservative: iOS 18 APIs only (iOS 26 ones such as `glassEffect` behind
  `#available(iOS 26, *)`), no tuple destructuring in view builders, no names that shadow
  SwiftUI (`State`, `Section`, `Type`), groups of ≤ 10 views where unsure.
- **Read colours from `@Environment(\.palette)`**, fonts from `AppFont`, sizes from `Metrics`. Use
  Android's setting keys (`Setting` in `LibraryStore.swift`, `AppearanceStore`).
- **Log** every network call, decision and failure through `Log` (Library → Settings → App →
  Debug log), so Mac testing can be debugged from a copied log.
- After each phase: Linux tests green → commit in logical pieces → push → update `PARITY.md` →
  ask the user to `git pull && scripts/run-simulator.sh` and paste `build.log` if it fails.

## Phase 1.5: settle phase 1 on the Mac (first thing next session)

1. `git pull`; read any Mac fix commits to learn which APIs failed to compile.
2. Fix whatever the user reports from the simulator: header and hero overlap, nav bar inset,
   glass look, rail heights, Settings rows.
3. Wire the two stored-but-unused settings: **Keep the bars on screen** (`static_app_chrome`: the
   Home header and nav bar tuck away on scroll down unless on) and **Accent in the player**.
4. Home polish from Android `ui/home/HomeScreen.kt`: Load More in expanded grids (paged
   `newest`/`trending`/... queries; Android `HomeViewModel.loadMore`), drag-to-reorder on Home
   itself (`HomeRowDrag.kt`), the startup still-loading state.

## Phase 2: Browse extras, Schedule, Notifications (local)

**Android sources:** `ui/search/SearchScreen.kt` (2.2k), `SearchViewModel.kt`,
`ui/schedule/ScheduleScreen.kt`, `ScheduleCalendar.kt`, `ScheduleViewModel.kt`,
`data/LocalCatalog.kt`, `data/remote/KonohaClient.kt` (media index schedule).

- **Core**
  - `DiscoverFilters`: tags + excluded genres/tags (AniList `MediaTagCollection` query), studio
    filter (`studioId` → id list, `studioSearch` route), "hide watched" (`id_not_in` from history).
  - Media index title list (`index.json`) + `LocalCatalog` search fallback (desktop
    `media_index::search_titles`), for half-typed queries AniList misses.
  - Media index monthly schedule (`schedule/{yyyy-mm}.json`) with AniList fallback (Android
    `MiruroRepository.schedule`).
  - Search history store (`SearchHistoryStore.kt`).
- **App**
  - Browse: tag/exclusion chips in the filter sheet (long-press a chip = exclude), studio page,
    search history and suggestions, collapsible header (`browse_header_collapsed`).
  - Schedule: Android's day strip + calendar view (`schedule_calendar_view`), "only my shows",
    airing reminders entry point, time format from `AppearanceStore.uses24Hour()`.
  - Notifications page shell: local "is out" alerts list (fed by phase 5/6 data), empty state.
- **Done when:** Browse matches Android's filter set; Schedule matches the Android screen.

## Phase 3: the show page

**Android sources:** `ui/detail/DetailScreen.kt` (2.1k), `DetailViewModel.kt`, `WatchOrder.kt`,
`SeasonLabels.kt`, `MovieUiPolicy.kt`, `ui/components/EpisodeBrowser.kt`, `EpisodeArtwork.kt`,
`SeriesLogo.kt`, `SynopsisDialog.kt`, `CoverImagePreview.kt`, `AnimeListActions.kt`,
`WatchedToggleButton.kt`, `ui/theme/ShowColourTheme.kt`. Desktop: `franchise.rs`.

- **Core**
  - Episode metadata merge: Miruro titles/stills → media index `episodes.json` → AniList
    `streamingEpisodes` (Android's precedence), filler from `filler-index.json`.
  - Franchise / watch order (port desktop `franchise.rs`: season chain from media index `series`,
    PREQUEL/SEQUEL walk, airing vs chronological order).
  - Watched-titles model (mark episode/series watched, Android `WatchedTitles.kt`).
- **App**
  - Rewrite `DetailView.swift` after `DetailScreen.kt`: banner + cover (tap to zoom) + title or
    series logo (`MediaIndex.logo`), "85% score · 1.1M members · 25 episodes", **Add to list**
    menu, eye (watched) toggle, **Continue N** button, "Episode 1 of 25 / 0%" progress line.
  - Pill tabs **Home / Episodes / Related**. Home: stat cards (Status, Format, Year…), next-episode
    card, genre chips, members/favourites, synopsis with More (sheet), studio chip → studio search,
    trailer card. Episodes: `EpisodeBrowser` (filter field, Newest/Oldest, list/grid
    `episode_layout`, EP badges, thumbnails, spoiler blur, Sub/Dub, per-episode download button
    stub). Related: relations, watch order grid, recommendations (`related_layout`).
  - Apply `AppearanceStore.showPalette(media.coverImage?.color)` to the whole page
    (`.environment(\.palette, …)`), and the Details glass header once scrolled.
  - Share (`anilili://anime/<id>` + AniList URL).
- **Done when:** side-by-side with the emulator, the page matches tab for tab.

## Phase 4: watch page and the custom player

**Android sources:** `ui/watch/WatchScreen.kt` (3.2k), `WatchViewModel.kt` (3.1k),
`PlayerControlsScaffold.kt`, `PlayerSeekBar.kt`, `PlayerSeekMarkers.kt`,
`PlayerGestureControls.kt`, `PlayerSettingsSheet.kt`, `PlayerSourcesSheet.kt`, `SourceFilter*.kt`,
`NextEpisodeCard.kt`, `AutoSkipCountdown.kt`, `InPlayerEpisodeList.kt`, `PlayerPauseOverlay.kt`,
`PlayerClock.kt`, `PlayerScreenLock.kt`, `SubtitleSyncTargets.kt`, `OpenSubtitlesPanel.kt`,
`data/settings/CaptionStyle.kt`. Desktop: `aniskip.rs`, `opensubtitles.rs`, `storyboard.rs`.

- **Core**
  - Sources model gains subtitles, quality ladder, per-server language tags; Miruro `ssub` tracks
    with their subtitle files; AnimeHeaven unchanged.
  - WebVTT + ASS parser for soft subtitles (render as an overlay; AVPlayer can't side-load
    subtitles into HLS). Subtitle delay; persistent per-show delays.
  - AniSkip fallback (media index `skip/` mirror, then AniSkip API) when Miruro has no windows.
  - Server priority / disabled providers / preferred languages (Android `server_priority`,
    `disabled_providers`, `preferred_source_languages`).
  - Watched threshold (`watched_threshold_percent`), resume rules.
- **App**
  - Watch page (portrait): player on top; below it the episode title, score · Episode N,
    synopsis + More, show row (cover, title, popularity, heart), source dropdown ("Anikoto ★")
    and Sub/Dub chip, Episodes N with filter and grid toggle, "Now playing" row.
  - Replace `AVPlayerViewController` with an `AVPlayerLayer` view + custom controls: back, title,
    big play/pause, ±10 s, prev/next, thick seek bar with intro/outro markers and storyboard
    thumbnails, time, CC, AirPlay (`AVRoutePickerView`), fullscreen (landscape), settings gear.
  - Gestures: double-tap seek, hold for speed (`hold_playback_speed`), vertical brightness/volume,
    horizontal drag to seek, screen lock.
  - Settings sheet: speed, quality, screen size (fit/fill/zoom), subtitles (track, delay, style),
    audio. Sources sheet with language filter.
  - Skip button + auto-skip countdown, next-episode card and countdown at the outro, pause overlay
    with details and series logo, clock and finishing time (`player_clock`).
  - PiP with `AVPictureInPictureController` (custom-controls player), Now Playing info and remote
    commands (lock screen), background audio.
  - External players: "Open in VLC / Infuse" via URL schemes (`vlc-x-callback://`,
    `infuse://x-callback-url/play?url=`).
- **Done when:** a dub episode with soft subs plays, seeks, skips, switches server, enters PiP,
  and autoplays the next episode, matching the Android controls.

## Phase 5: accounts and sync

**Android sources:** `data/auth/AuthManager.kt` (AniList implicit grant, client id `45552`,
redirect `http://localhost`), `MalAuthManager.kt`, `AccountService.kt`, `SecureTokenStore.kt`,
`data/remote/AniListClient.kt` (viewer, lists, `SaveMediaListEntry`, notifications),
`data/library/CustomLists.kt`, `ui/components/AnimeListActions.kt`,
`ui/components/AnimeListStatusDialog.kt`. Desktop: `anilist.rs`, `mal.rs`, `library.rs` (sync rules).

- **Core**: AniList viewer + MediaListCollection, save/delete entry, custom lists, notifications
  query; MAL OAuth (PKCE) + list API; the sync policy (Android `planMediaListProgressUpdate`,
  desktop "account wins except newer local change"); token storage in the Keychain.
- **App**: sign-in in a `WKWebView` sheet that catches the `http://localhost#access_token=…`
  redirect (ASWebAuthenticationSession can't take an http callback); Account sheet; the list
  status dialog on long-press everywhere (replaces the watchlist-only context menu); progress sync
  at the watched threshold; Planning ↔ watchlist sync (`sync_saved_to_anilist`); Favourites and
  custom lists in My List; AniList notifications page with unread badge on the bell.
- **Done when:** signing in shows the AniList lists in My List and watching an episode updates
  AniList progress.

## Phase 6: library, downloads, the rest of Settings, backup

**Android sources:** `ui/downloads/DownloadsScreen.kt`, `ui/detail/SeasonDownloads.kt`,
`SeasonDownloadDialog.kt`, `data/library/*`, `ui/settings/*` (`IndexedSettingsContent.kt`,
`SettingsSearchIndex.kt`), `data/backup/AppBackup.kt`, `BackupCrypto.kt`, `MalExport.kt`,
`MalImport.kt`, `data/reminder/*`. Desktop: `backup.rs`, `download.rs`.

- **Core**: download queue model (two at a time, disk-space checks); Android's `anilili-backup` v1
  format (settings under Android's keys, library, progress, sealed login with PBKDF2-SHA256
  210k + AES-GCM; test against `fixtures/parity/backup-sealed.json` from the desktop/Android
  repos); MAL XML export/import; new-episode counts ("3 NEW").
- **App**: Downloads tab (HLS via `AVAssetDownloadURLSession`, MP4 via `URLSession` background
  downloads, offline playback, season download dialog); My List complete (status lists, sort, new
  badges, progress tags); every remaining Settings page (Subtitles with caption appearance,
  Downloads, Servers, Accounts, Notifications, Data with backup/restore via the Files picker);
  local release notifications (`UNUserNotificationCenter` + background refresh for airing shows).
- **Done when:** a backup made on Android restores on iOS and the other way round.

## Phase 7: extras

**Android sources:** `ui/random/*` (swipe deck), `ui/profiles/*` + `data/profiles/*`,
`ui/nav/AnililiLink.kt` + `docs/LINKS.md`, `ui/announce/*`, `data/announce/*`, `ui/tour/*`,
`data/settings/AppIcon.kt`, `data/recs/*`. Desktop: `links.rs`, `recs.rs`.

- Random swipe deck replacing the dice's quick pick (`RandomAnimeDeck`).
- Profiles (who's watching, per-profile settings and library) and profile lock (PIN).
- `anilili://anime|watch|search` deep links (test against `fixtures/parity/links.json`).
- Announcements and the What's new tour.
- Alternate app icons matching the accent preset.
- For You / Because you watched from the media index neighbour graph (port desktop `recs.rs`),
  replacing the AniList-recommendations stand-in.

## Decisions still open (ask the user)

- **Signing for a real iPhone:** free Apple ID (7-day re-sign) or paid developer key. Deferred.
- **TV-only Android features** (pairing, D-pad UI) stay out unless an Apple TV target is wanted.
