# HEAD — Project Status

> Living status document. Updated at the end of every phase of work.
> Legend: ✅ done · 🔧 in progress · ⏳ pending · ❌ blocked · 🗑 removed

**Last updated:** 2026-10-02 — Phases 0–7 complete. `flutter analyze` clean
(7 pre-existing issues), **83/83 tests pass**.

---

## Current work

Nothing in flight. Next candidates are listed under [Backlog](#backlog).

| Phase | Feature | State |
|---|---|---|
| 0 | `HEAD.md` status document | ✅ |
| 1 | UUID core: `media_index.dart`, `UploadJob.uuid`, migration | ✅ |
| 2 | Embed UUID tag in YouTube title + Telegram caption | ✅ |
| 3 | `videos.update` (YouTube) + `editMessageCaption` (Telegram) primitives | ✅ |
| 4 | Matching engine `uuid_backfill.dart` | ✅ |
| 5 | Backfill review screen | ✅ |
| 6 | Apply backfill (quota warning + resumable checkpoint) | ✅ |
| 7 | Tests, `flutter analyze`, final HEAD update | ✅ |

---

## The UUID system — how it works

**Format.** Every media item gets a v4 UUID (36 chars, stored locally) plus an
8-character **short tag** drawn from its first 8 hex digits, always containing
at least one letter `a-f` so an all-digit date fragment (`[20261002]`) can
never be mistaken for one. The tag appears in both destinations:

```
YouTube title   02 October 2026 15:30 [a1b2c3d4]
Telegram cap.   #Holiday
                02 October 2026 15:30 [a1b2c3d4]
```

Titles are stored **tag-free** locally; the tag is applied at send time by
`UploadJob.taggedTitle` (`MediaIndex.fitTitle`, capped at YouTube's 100 chars).

**Identity rules.**

| Rule | Where |
|---|---|
| A UUID is minted once per **asset**, not per job | `MediaIndex.resolveOrCreate` |
| Re-queueing an asset **reuses** its existing UUID | same |
| `destination: both` → one job → one UUID for both sides | `UploadScheduler.addJobs` |
| A tag already on a remote item is **authoritative** and adopted, never replaced | `MediaIndex.adoptTag` |
| An existing UUID is never rewritten | `UuidBackfillService._writeLocal` |

**Storage.** Registry lives in `FlutterSecureStorage` under **`media_index_v1`**;
the queue under **`upload_queue`** (`uuid` + `shortTag` per job). Jobs written
by a pre-UUID build are migrated on `UploadScheduler.load()`.

**Matching back-fill** (`lib/services/uuid_backfill.dart`) — 4 tiers:

| Tier | Confidence | Signal |
|---|---|---|
| 1 | `certain` | UUID tag already on the item, or a stored `youtubeVideoId` / `telegramMessageId` |
| 2 | `exact` | Tag-stripped titles byte-identical |
| 3 | `strong` | Original filename matches (`DocumentAttributeFilename` / `titleAsync`) |
| 4 | `probable` | Date within 5 min **and** bytes or duration agree |
| — | `none` | Nothing lined up |

Ambiguous titles (2+ locals in the same minute) are reported as `probable`
with **no** asset chosen — never a coin flip. Date alone is never sufficient.

**Apply order** (`UuidBackfillService.apply`): local index → Telegram (free) →
YouTube (50 quota units each, checkpointed under `uuid_backfill_done` so an
interrupted run resumes without double-charging).


---

## Feature status

### Queue & upload core
- ✅ Upload queue with JSON persistence (`FlutterSecureStorage` key `upload_queue`)
- ✅ 15/day YouTube quota spread; overflow days become `scheduled`
- ✅ Pause / resume whole queue; rate-limited UI notifications
- ✅ Retry, remove, clear; per-channel & per-account & per-TG-account counters
- ✅ Single upload funnel `_processNextIfNeeded()` in `upload_queue_page.dart`
- ✅ Background service + app badge count

### YouTube
- ✅ Resumable upload (5 MB chunks, 5× retry with backoff) — `youtube_uploader.dart:143`
- ✅ Find-or-create playlist by folder title, then `playlistItems.insert`
- ✅ Channel browser with search, pagination, private-video fallback
- ✅ "Still exists" verification (`youtube_sync.dart` — by videoId, fallback by title)
- ✅ Download video to device; open in YouTube; folder tagging
- ✅ `videos.update` title rewrite (read-modify-write, preserves categoryId /
  description / tags) — `youtube_uploader.dart` `updateVideoTitle`
- ✅ `https://www.googleapis.com/auth/youtube` scope — **requires one
  re-consent on next sign-in**
- ⚠️ Title rewrites cost **50 quota units each**; warned in the review UI

### Telegram
- ✅ MTProto client over raw TCP socket; session/DC persistence
- ✅ Phone + code + 2FA auth
- ✅ Upload video / photo / document to Saved Messages (512 KB parts, resume, thumbnails)
- ✅ Saved Messages browser with type tabs, thumbnail prefetch, multi-select
- ✅ Delete messages; download to device; loopback HTTP stream server for playback
- ✅ Caption-only verification via `messages.search` (now UUID-tag aware)
- ✅ `messages.editMessage` caption rewrite — `TelegramService.editMessageCaption`
- ✅ `DocumentAttributeFilename` parsing → `SavedMessageItem.fileName`
- ✅ Saved-message title probes prefer the unique UUID tag over the date title

### Local media & folders
- ✅ Gallery grid (image/video/audio) with multi-select and trash delete
- ✅ Folders scoped `local` / `youtube` / `telegram`, colour, drag-drop, export/import
- ✅ Folder-strip chips shared across all three grids
- ❌ Local media database — **never existed**; metadata is JSON blobs only

### Auto sync
- ✅ `MasterSync` 15-minute timer, 4 targets, master + per-target toggles
- ✅ Gallery scan oldest-first, dedupe by `assetId`, unique-title dedupe (`#2`, `#3`)
- ✅ Stats dashboard with week/month/year charts and recent/history lists

### UUID identity system (new)
- ✅ `uuid: ^4.6.0` declared in `pubspec.yaml`
- ✅ `lib/services/media_index.dart` — UUID registry keyed by assetId /
  videoId / messageId / shortTag; `resolveOrCreate` / `link` / `adoptTag`
- ✅ `UploadJob.uuid` + `shortTag` fields and legacy-job migration
- ✅ Tag format `dd MMMM yyyy HH:mm [a1b2c3d4]` on the YouTube title
- ✅ Tag in the Telegram caption (after the `#folder` header lines)
- ✅ UUID reuse when the same asset is queued again (either destination)
- ✅ `lib/services/uuid_backfill.dart` — 4-tier matcher (pure, testable)
- ✅ `lib/services/uuid_backfill_service.dart` — gallery/YouTube/Telegram
  collection + apply with checkpoint
- ✅ `lib/pages/uuid_backfill_page.dart` — review screen, drawer entry
  "UUID back-fill", confidence chips, live quota estimate, progress + report
- ✅ All title matchers now compare tag-stripped forms (YouTube verify,
  browser local badge, `resolveLocalAssetId`, Telegram caption check)

### Quality
- ✅ 6 test files: `upload_scheduler` (~28), `master_sync`, `folder_store`,
  `youtube_sync`, **`media_index` (16)**, **`uuid_backfill` (15)**
- ✅ 83/83 tests pass (`flutter test`)
- ✅ `flutter analyze` — only the 7 issues that predate this work
- ⚠️ `analysis_options.yaml` includes `package:flutter_lints/flutter.yaml`,
  which does not resolve (package not in `dev_dependencies`) — so no lints
  are actually enforced. Add `flutter_lints` to fix.

---

## Architecture map

```
photo_manager (device gallery)
    ├─ manual pick ………… upload_queue_page.dart:511 `_addAssetsToQueue`
    └─ MasterSync 15 min … master_sync.dart:369 `syncNow`
              │
              ▼
   UploadScheduler.addJobs()          ← MediaIndex.resolveOrCreate assigns UUID
   FlutterSecureStorage `upload_queue`
              │
   claimNext() → upload_queue_page.dart `_processNextIfNeeded`
        ├── YouTube  → youtube_uploader.uploadResumable → videoId  ┐ tag in
        └── Telegram → telegram_service.uploadToSavedMessages       ┘ the title
              │
              └─ both ids linked back into MediaIndex

   Drawer → UuidBackfillPage → UuidBackfillService
        collectLocal / collectYoutube / collectTelegram
              → UuidBackfill.match (4 tiers)
              → review + quota warning
              → apply: local → Telegram edit → YouTube videos.update
```

### New files added by the UUID work

| File | Role |
|---|---|
| `lib/services/media_index.dart` | UUID registry + tag helpers |
| `lib/services/uuid_backfill.dart` | Pure matching logic (4 confidence tiers) |
| `lib/services/uuid_backfill_service.dart` | Collection + apply + checkpoint |
| `lib/pages/uuid_backfill_page.dart` | Review / quota / progress UI |
| `test/media_index_test.dart` | 16 tests |
| `test/uuid_backfill_test.dart` | 15 tests |
| `HEAD.md` | This document |

### Storage key reference

| Key | Store | Owner | Contents |
|---|---|---|---|
| `upload_queue` | secure | `upload_scheduler.dart` | `{jobs, deletedTelegram, deletedYoutube, paused}` |
| `media_index_v1` | secure | `media_index.dart` | UUID registry |
| `uuid_backfill_done` | secure | `uuid_backfill_service.dart` | checkpoint of already-rewritten remote ids |
| `media_folders_v1` | prefs | `folder_store.dart:101` | folders + membership |
| `selected_channel_id` | prefs | `account_manager.dart:31` | YouTube channel |
| `master_sync_enabled` / `master_sync_target_*` | prefs | `master_sync.dart:84,88` | sync toggles |
| `telegram_auth_session`, `telegram_session_dc` | secure | `telegram_service.dart:14,20` | MTProto session |
| `telegram_account_key`, `telegram_account_phone` | secure | `telegram_service.dart:26,27` | signed-in TG user |
| `telegram_default_destination` | secure | `telegram_service.dart:21` | youtube/telegram/both |

### Other repos in the parent folder

| Path | Relation |
|---|---|
| `../backend/` | Node YouTube-upload proxy — **unused**; the app uploads directly to Google |
| `../chrome_extension/` | "Auto Job Applier" extension — **unrelated** to this project |

---

## Known constraints / risks

1. **YouTube title rewrite** costs **50 quota units per video** (default
   10 000/day) and needs the `youtube` scope → **one forced re-consent** on
   the next sign-in. The review screen shows the cost before applying and the
   applier aborts the YouTube pass on a 403/429 instead of burning the rest.
2. **YouTube `videos.update` is read-modify-write** — `categoryId`,
   `description`, `tags` are re-sent verbatim so nothing is cleared.
3. **Title cap 100 chars** on YouTube; `MediaIndex.fitTitle` shortens the
   readable part and never the tag.
4. **Same-minute duplicate titles** (the `#2` dedupe hack) are reported as
   ambiguous with no asset chosen — a human decides.
5. **Date alone is never a match.** Tier 4 requires bytes or duration to
   corroborate, otherwise two items from the same five minutes would pair at
   random.
6. **Telegram captions cannot exceed 1024 chars**; `rebuildCaption` keeps the
   leading `#folder` lines and re-fits the body.
7. **No content hashing** exists; `photo_manager` exposes no hash API.
   Matching relies on filename / date / size / duration / UUID tag.
8. `AssetEntity.title` is **empty on iOS** unless `titleAsync` or
   `needTitle: true` is used — the back-fill collector uses `titleAsync`.
9. `flutter_lints` is referenced by `analysis_options.yaml` but not installed,
   so **no lints are enforced**.

---

## Backlog — not started

- [ ] Content hashing (MD5/SHA-1 of the file bytes) as a fifth, strongest
      match tier — needs `crypto` added as a direct dependency.
- [ ] Parse YouTube `contentDetails` duration into `YoutubeVideoInfo` so the
      browser page can show it.
- [ ] Install `flutter_lints` so `flutter analyze` actually lints.
- [ ] Surface the UUID tag on queue / Telegram / YouTube tiles so matches are
      visible without opening the back-fill screen.
- [ ] Delete `lib/MultiVideoPickerUploadPage.dart` (dead code, never imported).
- [ ] Delete or wire up `../backend/` (unused Node upload proxy).
- [ ] `../chrome_extension/` is unrelated to this project — consider moving it
      out of the repo.
- [ ] Root git repo has **zero commits** with all three folders untracked.

---

## Changelog

- **2026-10-02** Phases 0–7 — `HEAD.md`; UUID registry (`media_index.dart`);
  `UploadJob.uuid` + legacy migration; tag embedded in YouTube titles and
  Telegram captions; `videos.update` + `youtube` OAuth scope;
  `editMessageCaption` + `DocumentAttributeFilename` parsing; 4-tier matcher;
  review screen with quota warning and resumable checkpoint; 31 new tests
  (83 total, all passing); `flutter analyze` clean.
- **2026-10-02** Phase 0 — created `HEAD.md`; full project analysis.
