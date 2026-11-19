# Strength tab deployment

## Current curated gym library and progression release

Deployed **2026-11-12 19:08 America/New_York** as
`curated-20261112-4b1c49d7`. Both services use
`local/health-{backend,frontend}:curated-20261112-4b1c49d7`.

This release adds the 24-exercise library matched to the user's gym equipment,
Chinese instructions and filters, planned/completed muscle maps, weekly working-set
distribution, and optional double progression with explanations. Existing templates
retain their prior behavior until progression is enabled. See
[the equipment mapping and usage](gym-exercises.md).

The live baseline was `observation-v2-20261109`, rather than the older version named
below. The pre-change local frontend rebuilt to byte-identical live JS/CSS hashes;
all live backend Python/text files matched local source except the intended strength
model change. Candidate images were built from the current live images without
network access, preserving their runtime dependencies and unrelated application code.

- Release and source: `/home/admin/health/releases/curated-20261112-4b1c49d7/`.
- Protected backup: `/home/admin/health/backups/curated-20261112-4b1c49d7/`.
  Includes consistent SQLite backups, a final backup while the backend was stopped,
  source, live frontend files, compose configuration, `.env`, and data configuration.
- Rollback images: `local/health-{backend,frontend}:rollback-curated-20261112-4b1c49d7`.
- Backend image ID:
  `sha256:328d45426171b00542d8264812e1f1514f0d69255238eb2f0a435b74326b1266`.
- Frontend image ID:
  `sha256:39f8a121fc92b26a098252e9cb2d62e103378d65be81f0e284f4e1d444d00497`.
- JS `/assets/index-DtxGX3OG.js`, SHA-256
  `12395e5d5c5eda9fb71226fb1b3fef54663094f5fc84231290a2dc19d53b6163`.
- CSS `/assets/index-BGcGnbUn.css`, SHA-256
  `0c55f9b38012bc3710e3f8e8821772126a4fe5cec847b0a10e5fa670cea1f8a3`.
- Unchanged push worker SHA-256:
  `a26319f577c61bbc71058db564e18147165f453fd9ac1c83f9271727fd999f04`.

All **89 backend tests passed in the isolated ARM64 candidate**, and all **49 frontend
tests and the production build passed locally**. A network-isolated migration check
on a production database copy added exactly 15 exercises, preserving all pre-existing
exercise rows and every other table's contents. After deployment, stored training
documents, template documents and deletion markers, including their versions, were
hash-identical to the final backup. No production test workout or test notification
was created.

Authenticated internal and public HTTPS checks returned 24 exercises, two preserved
templates and the same saved-session count. Anonymous catalogue access remains HTTP
401. Public HTML points to the new assets and their bytes match the local build.
The push configuration fingerprint is unchanged. Both containers are running with
zero restarts and no startup error lines. The working source and `CURRENT_RELEASE`
were updated. Validation evidence is stored alongside the release.

Application rollback must preserve the live data volume. If new sessions contain
progression/muscle snapshots, retain the compatible backend when rolling back the
frontend; the older API rejects those additional fields. Do not overwrite newer
training records by automatically restoring the pre-deployment database.

Entry: `https://health.frankandpatrick.com/?v=curated-20261112-4b1c49d7#strength`.
Open or refresh the existing website/Home Screen app. Browser screenshot and real
iPhone layout verification remain pending because the computer-use connection was
unavailable; no new native iOS binary was built in this release.

## Previous Liquid Glass native app prototype 0.2

Current frontend: `local/health-frontend:glass-20261108-1fjy20rx`.
Backend remains `local/health-backend:deletefix-20261108-0h3kdpt6`.

The user requested an implementation following Apple's Liquid Glass adaptation
guide. The iPhone project now uses system tab/navigation bars around one persistent
WKWebView, native SwiftUI settings, system workout menus, and native finish/discard
confirmation. The app version is 0.2.0/build 2. Navigation/control materials follow
the system; numeric training rows and reports retain opaque content surfaces.
See the [design mapping and limitations](../ios/DESIGN.md).

The bridge adds capability-gated `chrome-v1`/`menus-v1` messages and preserves the
workout protocol. HTML bars hide only after a supported native acknowledgement.
Login, web forms and live workouts have explicit navigation visibility states.
React owns the selected page and draft; native tabs follow its acknowledged state.
Viewing history or another tab does not replace the active workout snapshot.
Cancelled or stale workout confirmations preserve records. Native settings changes
share the workout mutation queue. Browser/PWA and earlier native hosts retain their
working controls. No CSS glass effect is added to the normal website.

All **37 frontend tests**, **nine compiled Foundation core checks**, the Vite build,
project/plist/extension membership checks and Swift source parsing passed. Tests
cover acknowledgement/fallback, late sign-out replies, tab switching with a draft,
scope-checked commands, menus, modal navigation visibility, cancel/finish and wire
payload validation, plus existing workout/report/deletion/push behavior. **Full
Xcode and the iOS SDK are still absent. UIKit/SwiftUI/ActivityKit compilation,
Liquid Glass rendering, pixel geometry, signing and iPhone testing remain pending
the user's system/Xcode upgrade. There is no installable IPA.**

Use Xcode 27 for iOS 27 SDK builds. The minimum runtime remains iOS 17; explicit
Liquid Glass APIs use availability checks. The build script requires SDK 26 or
newer. System accessibility preferences and four-set keyboard layouts need actual
device validation. Web Push report notifications remain in the Home Screen website.

- Release/source: `/home/admin/health/releases/glass-20261108-1fjy20rx/`.
- Protected frontend/iOS source/compose backup:
  `/home/admin/health/backups/glass-20261108-1fjy20rx/`.
- Frontend rollback image: `local/health-frontend:rollback-glass-20261108-1fjy20rx`.
- JS `/assets/index-CBwfZuW5.js`, SHA-256
  `14e68841baa2a012aa08ee2952b13690157bfc8ebf2590932ac57654d09b57de`.
- CSS `/assets/index-CIMN79TO.css`, SHA-256
  `65399d3b7383caeb8eec60ab87b382d62676c28765b4d0253d3fb57cf441ef44`.
- Local source ZIP: `ios/build/Health-iOS-Liquid-Glass.zip`, SHA-256
  `bf056c14c0570c4d44a7101cd686e538485da140a389662f52234c086a974ac1`.
  Source/configuration/icons only; signing overrides and build caches are excluded.

The live frontend checks validate authenticated API access, exact asset hashes,
native navigation/confirmation bridge presence, and the unchanged Web Push worker.
The backend container is preserved, with no database migration, production test
workout or test notification introduced by this release.

Entry: `https://health.frankandpatrick.com/?v=glass-20261108-1fjy20rx#strength`.
The native design appears in the compiled app; Safari/PWA retains its web UI.

## Previous iPhone prototype and native bridge frontend

Current frontend: `local/health-frontend:native-ui-20261108-b1f8d87e-r2`.
Backend remains `local/health-backend:deletefix-20261108-0h3kdpt6` (2026-11-08).

The user authorized trying an iPhone app and chose to install Xcode later. The
repository now contains `ios/Health.xcodeproj`, a WKWebView app target, an embedded
ActivityKit/WidgetKit extension, native local rest notifications, app icons,
deterministic project generation, unsigned IPA build scripts and a source ZIP.
See the [native app guide](../ios/README.md) for build, signing and device steps.

The deployed React UI publishes a minimal versioned snapshot only inside the
native host. It follows the active workout even when another history report is
selected, sends meaningful changes rather than timer ticks, serializes/coalesces
updates, and republishes on foreground return. Native system timers use the same
start/pause/rest anchors as the website. Pause, resume, rest skip, completion,
discard and sign-out update/clear native state. UUID-checked notification links
open existing workouts; missing/deleted records show an explicit message.

Native-only settings offer Live Activity and local rest reminder controls. System
notification permission is requested only by an explicit settings tap, with time
for the user to answer. Browser/PWA notification settings retain the existing Web
Push control. This prototype has no APNs entitlement and uses `pushType: nil`;
report-ready notifications still come from the Home Screen website. The bridge
rejects untrusted origins/subframes/versions and bounded invalid payloads. It
does not transmit weights, reps, notes, heart samples, passwords or API tokens.

All **34 frontend tests**, the production build, and **six compiled Swift core
checks** passed. The integration test exercises real React workout/settings
components with a mocked native handler. The Foundation model checks cover
pause/resume, rest scheduling eligibility, validation, epoch conversion and safe
routes. Project/plist/scheme/icon checks verify both targets, source membership
and extension embedding; Swift source parsing also passed. **No full iOS SDK is
installed, so UIKit/SwiftUI/ActivityKit compilation, simulator runs, signing and
iPhone behavior remain unverified. No IPA has been produced or installed.**

The frontend was built offline from the existing nginx image and validated for
asset hashes, API authentication, manifest, unchanged push worker and native bridge
presence. The backend container ID was preserved throughout deployment. No schema
change, production test workout or test notification was made.

- Release/source: `/home/admin/health/releases/native-ui-20261108-b1f8d87e-r2/`.
- Protected frontend/source/compose backup:
  `/home/admin/health/backups/native-ui-20261108-b1f8d87e-r2/`.
- Frontend rollback image:
  `local/health-frontend:rollback-native-ui-20261108-b1f8d87e-r2`.
- JS `/assets/index-Co29sUTI.js`, SHA-256
  `21e87530d4ea7851be718a6af08a2b2329956868fae746a22e4f91f6a1bd3010`.
- CSS `/assets/index-BqwAPBrs.css`, SHA-256
  `fb97918f0462755ff60c059d28d29e88b67532321275261e4a3ca5ab1a033ce3`.
- Local source artifact: `ios/build/Health-iOS-Prototype.zip`, SHA-256
  `f1281dcf093677267297cdbee0ad62ec6d8d8bb7d44c8906d28082c4cb3d6327`.
  This includes source/configuration/icons, not signing overrides, credentials,
  build caches or an installable binary.

Entry: `https://health.frankandpatrick.com/?v=native-ui-20261108-b1f8d87e-r2#strength`.
Native features become available when running the app after Xcode/device setup;
opening this URL in Safari does not provide ActivityKit.

## Previous deletion recovery and notification settings release

Current backend and frontend: `local/health-backend:deletefix-20261108-0h3kdpt6`
and `local/health-frontend:deletefix-20261108-0h3kdpt6` (2026-11-08).

Notification controls now appear only under the app header gear **设置**. Training
home and completed reports no longer contain this setting. The four navigation
tabs and existing subscription are preserved.

The deletion dialog can be closed while a request is pending. The browser uses an
authenticated JSON POST action with the same version checking and idempotent
deletion behavior as the compatible DELETE endpoint. A 12-second deadline covers
the request and response body, even when a transport ignores abort. Ambiguous
failures check the record with a separate four-second deadline: a missing/deleted
record is removed locally; an unconfirmed result keeps the record and allows a
retry. Closing an older dialog cannot clear a newly selected report or dialog.

The earlier hang was confirmed to have no client deadline and to disable both
close and cancel controls. No corresponding DELETE request appeared in the
inspected backend/proxy logs, so the precise pre-handler transport cause remains
unconfirmed. The deployed JSON POST successfully deleted the exact user-confirmed
19:20 workout in 31 ms through the authenticated frontend proxy. Its physiology
and push-delivery rows were removed, and database integrity passed. Other workouts
were not selected for deletion. No production test workout or notification was
created.

All 79 backend tests passed locally and in the isolated ARM64 candidate; all
30 frontend tests and the production build passed. Added tests cover stalled
requests, closable pending dialogs, lost deletion responses, bounded verification,
retry, the POST compatibility action and settings-only notification controls.
The migration-copy check preserved pre-existing table counts and session
documents/versions. Live authenticated reports, config, manifest, worker and asset
hashes passed before deletion. These tests do not verify native iPhone rendering.

The deleted latest workout ended at **2026-11-08 20:13:01.672 America/New_York**.
Heart data was collected at **20:17:52.020748**, and the push provider accepted the
notification at **20:17:52.438732**: **290.766732 seconds** after the workout ended,
including **0.417984 seconds** from collection to provider acceptance. The iPhone
display/read time is unavailable. This is one measured workout, not a guaranteed
Google Health synchronization interval. Timing evidence was saved before deleting
the delivery row.

- Release: `/home/admin/health/releases/deletefix-20261108-0h3kdpt6/`.
- Consistent SQLite/source/override backup, protected VAPID backup and private
  `timing-and-deletion.json` audit:
  `/home/admin/health/backups/deletefix-20261108-0h3kdpt6/`.
- Rollback images: `local/health-backend:rollback-deletefix-20261108-0h3kdpt6`
  and `local/health-frontend:rollback-deletefix-20261108-0h3kdpt6`.
- JS `/assets/index-BQbIGqbg.js`, SHA-256
  `2634cfbb36435537ad8c8a0d6861c03f5a0c02e3dc00a8cda8125476bb934491`.
- CSS `/assets/index-Cib45SxW.css`, SHA-256
  `a753eccc1935de36724c7e11efe5f9ca85835c778b4b3bbe23b5fe9825f434e3`.
- Worker `/push-sw.js`, SHA-256
  `c4e6fcfb91823ef0193749fe095ae8290266a1616b2737aa3903f3eae885fd3b`.

Entry: `https://health.frankandpatrick.com/?v=deletefix-20261108-0h3kdpt6#strength`.
Refresh from the existing Home Screen app. Preserve the data volume, VAPID key and
deletion-aware backend on rollback; restoring the pre-deletion database would
restore the removed workout.

## Previous workout Web Push release

Current backend and frontend: `local/health-backend:webpush-20261108-_vbkcyl2`
and `local/health-frontend:webpush-20261108-_vbkcyl2` (2026-11-08).

The user selected Web Push for workout-ready notifications. Training home and
completed reports include a user-tapped notification permission/subscription
control. A standalone manifest, push-only service worker, authenticated VAPID
configuration/subscription routes and a persistent delivery outbox support
notifications when the page is closed. Ready messages use a generic lock-screen
body without numerical health metrics. Tapping opens the matching report, including
records outside the recent list. Missing/deleted reports are handled safely.
Existing Telegram analysis delivery is independent; no workout-ready Telegram
message was added. See [Web Push behavior and setup](web-push.md).

All 78 backend tests passed locally and in the isolated ARM64 candidate; all
27 frontend tests and the production build passed. Tests include real encryption
and VAPID signing with provider HTTP mocked, subscription validation, readiness,
latest-only registration backfill, deduplication, leases, retries, expiry cleanup,
workout deletion, user-gesture permission ordering, unsubscribe and notification
navigation. The migration-copy check preserved all pre-existing table counts and
session documents/versions. Live authenticated config returned a stable public
key, manifest and JavaScript worker were served correctly, and bundle hashes,
private-key mode/backup and protected report endpoints passed validation.

At that release, **device permission and actual iPhone delivery were pending user action**.
Browser/DOM/VM tests do not simulate iOS authorization or prove lock-screen receipt.
The existing latest workout was ready with 239 heart samples when inspected; no
synthetic production workout/subscription or unrelated test notification was made.
The user subsequently enabled the Home Screen subscription. Provider acceptance
was recorded for two real reports before the deletion/settings revision above;
this still does not establish the device display time.

- Release: `/home/admin/health/releases/webpush-20261108-_vbkcyl2/`.
- Consistent SQLite/source/override backup and protected VAPID backup:
  `/home/admin/health/backups/webpush-20261108-_vbkcyl2/`.
- Persistent private VAPID key: `/data/webpush-vapid.pem` in the data volume;
  it is not embedded in the image or frontend. pywebpush 2.5.0 is pinned.
- Rollback images: `local/health-backend:rollback-webpush-20261108-_vbkcyl2`
  and `local/health-frontend:rollback-webpush-20261108-_vbkcyl2`.
- JS `/assets/index-DCFZnFlS.js`, SHA-256
  `d6cdf3364a6bbaace6852e9a306b0d60e6d81b58d5bfccfe355910b48318ccc5`.
- CSS `/assets/index-DdYmMyaf.css`, SHA-256
  `86f42cd5a49720721df3f683fc7f80bb533620e19382c43d1f409fd5293bf214`.
- Worker `/push-sw.js`, SHA-256
  `c4e6fcfb91823ef0193749fe095ae8290266a1616b2737aa3903f3eae885fd3b`.

Entry: `https://health.frankandpatrick.com/?v=webpush-20261108-_vbkcyl2#strength`.
On the iPhone, launch the existing Home Screen icon, use the header refresh, then
**开启通知 → 允许**. Preserve the data volume and VAPID key across deployments.

## Previous history deletion release

Current backend: `local/health-backend:delete-20261108-0k01t1ln`.
Current frontend: `local/health-frontend:delete-ui-20261108-_sbveuwu` (2026-11-08).

Completed history cards have a 44px delete control, and reports have a separate
**删除这场训练** action. Both use one confirmation dialog; cancellation/failure
keeps the record. Deletion requires the saved version and an online connection.
A conflict reloads the latest record before another attempt. Active workouts are
preserved. The API physically removes the strength record and physiology cache,
and invalidates analysis rows whose saved evidence references the deleted ID.
In-flight collectors cannot recreate the cache, and in-flight AI generation checks
for deletion before saving its evidence in a write transaction.

Only ID/version/deletion-time markers remain in `strength_session_deletions`.
Stale saves receive HTTP 410, and deleted IDs are excluded from local merge,
comparison and prefill history even if a late list/save response arrives. Clients
fetch deletion markers on startup/foreground return, share them across tabs,
and persist them separately from the removed records. Marker IDs use canonical
sorted order so tabs with different insertion orders converge without repeated
storage-event writes. New templates/start IDs
remain independent. Server-side deleted records cannot be recreated by an old
browser using their original ID.

All 70 backend tests passed locally and in the isolated candidate container;
all 24 frontend tests and the production build passed. Tests cover cancellation,
failed deletion, report deletion, stale versions, active-workout protection,
lost-response retry, physiological cache cleanup, stale saves/list responses,
external deletion during a save, and deletion during analysis generation. The
additive migration was verified on a consistent live database copy without
changing pre-existing table counts or session versions. Authenticated live routes,
production asset hashes and integrity checks passed before experiment cleanup.

The user's three identified 11.6–14.9 second experiments were then removed via
the authenticated DELETE API using their previously audited versions. Two were
dated November 8 and one November 7 in America/New_York; this was disclosed before
cleanup. Their physiology rows and referencing analysis cache were verified gone,
delete markers present, no completed records remained, and database integrity
passed. No test workout was created in production and no Google Health cloud
record was modified.

- Release: `/home/admin/health/releases/delete-20261108-0k01t1ln/`.
- Consistent pre-change SQLite/source/compose backup and deletion audit:
  `/home/admin/health/backups/delete-20261108-0k01t1ln/`.
- Rollback images: `local/health-backend:rollback-delete-20261108-0k01t1ln`
  and `local/health-frontend:rollback-delete-20261108-0k01t1ln`.
- Frontend cache-convergence revision/source/backup:
  `/home/admin/health/releases/delete-ui-20261108-_sbveuwu/` and
  `/home/admin/health/backups/delete-ui-20261108-_sbveuwu/`. All 24 frontend
  tests/build and production hashes passed; this revision did not restart the backend.
- JS `/assets/index-Do2Hs9Rf.js`, SHA-256
  `161ea66c20082f27cb36abe7b62613a34d2ee5980bcdaaa2b9fcf7645b97f11b`.
- CSS `/assets/index-BKT_Nb_K.css`, SHA-256
  `dffe03daf6512a2b99da10e381813c0ae1d2bbda96b8374af555d376826f133c`.

Entry: `https://health.frankandpatrick.com/?v=delete-ui-20261108-_sbveuwu#strength`.
After cleanup, retain deletion-aware backend behavior on any rollback; a backend
from before this feature does not reject resurrecting stale IDs. Do not overwrite
live SQLite with the pre-deletion snapshot unless restoration is intended.

## Previous automatic-fetch-first report

Current frontend: `local/health-frontend:autofetch-20261108-7_3py3c8` (2026-11-08).
Backend remains `local/health-backend:physiology-20261108-v3z4gj_x`.

After completing a workout the report waits for automatic Google Health collection.
It shows the app-sync link only after a persisted collection result is empty,
partial or fails. It stays hidden while the first request is queued/in flight,
when data is ready, during source selection, for authorization issues and for
unsupported windows. Attempts and checked_at advance at claim time, so the UI
uses a stored heart fetch timestamp or saved collection errors as evidence of a
completed attempt. A previous empty/partial fallback stays visible during later
retries, and disappears when data becomes ready. Returning from Google Health
still requests another collection; the server's durable retry queue is unchanged.

All 20 frontend tests and the production build passed. Existing SSR/DOM tests
now cover pending → in-flight → empty → fallback → app return → ready, along
with a successful first result that never offers the app link. Production asset
hashes, authenticated strength API and nginx-user file access passed. The backend
container ID was unchanged; no migration or production test workout was created.

- Release: `/home/admin/health/releases/autofetch-20261108-7_3py3c8/`.
- Backup: `/home/admin/health/backups/autofetch-20261108-7_3py3c8/`.
- Rollback image: `local/health-frontend:rollback-autofetch-20261108-7_3py3c8`.
- JS `/assets/index-Co0VWW4e.js`, SHA-256
  `747b9b6ab3c6d373e62d9a95a6a559300cf7c09800292a517127df1b93309409`.
- CSS unchanged: `/assets/index-Bl1Inw5W.css`, SHA-256
  `0a3bd8d4a4ef380c0fffb26567e53dd9dd6004527aa3e5b271e7027333269c9b`.

Entry: `https://health.frankandpatrick.com/?v=autofetch-20261108-7_3py3c8#strength`.

## Previous workout physiology rollout

Current backend and frontend: `local/health-backend:physiology-20261108-v3z4gj_x`
and `local/health-frontend:physiology-20261108-v3z4gj_x` (2026-11-08).

Completed strength workouts now queue physical-time Google Health collection in
SQLite and display heart-rate sample statistics, a minute chart with gaps, steps
and estimated active energy. Daily cached recovery metrics are labeled separately.
Background retries continue without the web page for up to seven days. Sensor
cache and source selection stay outside the versioned workout document. The report
uses Google's documented `https://www.fitbit.com/in-app/today` Universal Link for
**打开 Google Health 同步**. It opens from a user tap; returning queues another cloud
check, subject to the existing cooldown. Opening the app is not treated as proof
of synchronization. See [collection and synchronization design](workout-physiology.md).

Validation: all 63 backend tests passed both locally and in the isolated candidate
container; all 20 frontend tests and the production build passed. DOM tests cover
missing versus true zero, chart gaps, source choice, saving before fetching,
late responses, app-link return refresh and foreground-only polling. An additive
migration was tested against a consistent live SQLite copy: existing table counts
and all strength documents/versions were unchanged, integrity check passed, and
three completed workouts were eligible for backfill. Authenticated live report
routes returned matching windows; versions remained unchanged. Unauthenticated
access remained protected. Production JS/CSS hashes matched the build. No
production test workout was created. Native iPhone app handoff remains unobserved.

The host was temporarily unreachable during the earlier isolated candidate test,
before runtime promotion, then recovered without a reboot. The cause was not
established; no matching recent kernel OOM/I/O event was found. Memory cgroups are
disabled on this Pi, so Docker memory flags alone are not effective. Subsequent
candidate tests used a 32 MB tmpfs, constrained allocator arenas, process address
space/CPU limits and a wall-time limit; their observed peak RSS was about 81 MB.

The first promotion attempt's HTML check caught unreadable static artifacts from
the private staging umask and automatically restored both previous images. The
frontend image now explicitly grants read/traverse access to public HTML/assets,
and a check as the nginx user runs before promotion. The corrected deployment
passed its authenticated routes, asset hashes and live integrity checks.

- Release/source stage: `/home/admin/health/releases/physiology-20261108-v3z4gj_x/`.
- Latest pre-promotion SQLite/override/source backup:
  `/home/admin/health/backups/physiology-20261108-v3z4gj_x-retry1/`.
- Initial snapshots also remain in `physiology-20261108-v3z4gj_x/` and
  `physiology-20261108-wrnf1n9t/` under the same backup root.
- Rollback images: `local/health-backend:rollback-physiology-20261108-v3z4gj_x`
  and `local/health-frontend:rollback-physiology-20261108-v3z4gj_x`.
- JS `/assets/index-CYUgVDPE.js`, SHA-256
  `05fe4c5c3a00f50198e99734cc28c9851e8293c2cccdd1253df2154b17b1e44f`.
- CSS `/assets/index-Bl1Inw5W.css`, SHA-256
  `0a3bd8d4a4ef380c0fffb26567e53dd9dd6004527aa3e5b271e7027333269c9b`.

Entry: `https://health.frankandpatrick.com/?v=physiology-20261108-v3z4gj_x#strength`.
Image rollback retains the additive health cache; do not restore a stale database
over newer live training data.

## Last verified bulk-fill release

Last verified live frontend: `local/health-frontend:fillhint-20261108-_q5g1ygj` (2026-11-08).

The bulk-fill panel previously appeared whenever later unchecked sets existed,
even when the workout had only prefilled values. Its presence did not apply
values automatically, but the always-visible action was confusing and consumed
space.

The panel now requires a genuine weight/repetition edit to the selected set,
a complete source value, and at least one differing later unchecked set. Focus
alone and numerically identical input do not count as edits. Per-set baselines
allow reverting a change to hide the panel; baseline weights are compared in
the current unit. Applying values clears the pending baseline and hides the
action. Newly added inherited sets do not create a manual-edit baseline.
Append-source tracking and protection of completed sets remain in place.
These UI-only baselines are scoped by workout/movement/set and are not stored
in the server session document.

All 18 frontend tests and the production build passed. The real-component DOM
test starts from 50 lb × 8 prefilled history and verifies focus/same-value
input remain quiet, a change offers filling, reverting hides it, applying
updates following sets and hides it, and matching future values need no action.
Production JS/CSS hashes and the authenticated strength API passed verification.

- JS `/assets/index-dgUjNyNp.js`, SHA-256
  `3008a26d2c801dc66aeabdf3871576f9b88afdf9c236e35b61b8ef9378ab9cce`.
- CSS remains `/assets/index-zyha0B8j.css`, SHA-256
  `bdb5a7bbb37de4d56c3c0e0a7267f39a7faf71632fb860d8d2f5bea99a68eadc`.
- Release: `/home/admin/health/releases/fillhint-20261108-_q5g1ygj/`.
- Backup: `/home/admin/health/backups/fillhint-20261108-_q5g1ygj/`.
- Rollback image: `local/health-frontend:rollback-fillhint-20261108-_q5g1ygj`.

The backend container was unchanged. No database migration or production test
workout was created.

Entry: `https://health.frankandpatrick.com/?v=fillhint-20261108-_q5g1ygj#strength`.

## Previous compact four-set release

Previous frontend: `local/health-frontend:foursets-20261108-w0w4ufyt` (2026-11-08).

The user confirmed the standalone correction looks substantially better and
requested a four-set workout that needs as little scrolling as possible. Two
phone geometry reports were received: the app frame, client and visual viewport
are all 812px high; the workout header is 105px high. A home-view report placed
the navigation bottom at 812px, confirming it reaches the provided app bounds.
These are actual phone measurements, not DOM-test layout estimates.

This release preserves that viewport/header setup and reduces mobile workout
density below it. Set inputs and completion controls are 44px high, with 4px
row gaps and the existing 20px number text. Header/body padding, bulk-fill panel
and next-exercise card are reduced. Idle and active rest rows both keep 44px
minimum height. Notes and session options now open dialogs from a single 44px
tool row instead of two full-width disclosures. Notes still autosave, and
abandoning a workout still requires the existing confirmation. The note dialog
and other training dialogs follow the keyboard's available height.

Temporary automatic display-geometry reporting has been removed after the
phone measurements and improved appearance were confirmed. The geometry
reports already in private server access logs were not altered.

All 18 frontend tests and the production build passed. The DOM integration
fixture now has four sets and verifies all four remain present, note editing
persists after closing/reopening, and canceling abandonment keeps the active
workout. Production hashes and authenticated strength API checks passed.
Native iPhone rendering of the new density has not yet been observed; larger
text sizes and longer workouts retain normal scrolling.

- JS `/assets/index-D-2Kk4Vm.js`, SHA-256
  `6374661c1ab06c5abf2533bcbfddb352c9925c028cd5abca6ba648764b9f7d87`.
- CSS `/assets/index-zyha0B8j.css`, SHA-256
  `bdb5a7bbb37de4d56c3c0e0a7267f39a7faf71632fb860d8d2f5bea99a68eadc`.
- Release: `/home/admin/health/releases/foursets-20261108-w0w4ufyt/`.
- Backup: `/home/admin/health/backups/foursets-20261108-w0w4ufyt/`.
- Rollback image: `local/health-frontend:rollback-foursets-20261108-w0w4ufyt`.

The backend container was unchanged. No database migration or production test
workout was created.

Entry: `https://health.frankandpatrick.com/?v=foursets-20261108-w0w4ufyt#strength`.

## Previous standalone viewport correction

Previous frontend: `local/health-frontend:standalone-20261108-om30p7fm` (2026-11-08).

The user confirmed launch from a Home Screen icon. Earlier deployed mobile
layouts still showed a blurred blue button edge and a lower gap on that device.
Server access records confirmed the phone loaded the latest unified release.
Those observations are not treated as resolved by DOM tests.

This correction uses `viewport-fit=contain` and removes the legacy status-bar
style key. The mobile app frame fills browser-provided bounds using fixed
insets; it no longer pins the frame to visualViewport.height or adds a second
safe-area inset. JavaScript sets a temporary height only while an editable field
is focused, the viewport is at normal zoom, and its reduction indicates a
keyboard. The end action is now a 44px text button, removing the filled blue
surface from the top edge. Training data and per-set behavior are retained.

The relevant current WebKit discussion recommends removing the deprecated
status-bar style key ([317153](https://bugs.webkit.org/show_bug.cgi?id=317153)).
A separate report describes mismatched standalone viewport heights and a lower
orphan band ([313800](https://bugs.webkit.org/show_bug.cgi?id=313800)); this is
research context, not a confirmed diagnosis of the user's current phone.

Temporary diagnostics: a standalone launch sends one geometry report per
session to the existing same-origin `/api/status` endpoint as a query parameter.
It includes screen/window/visual viewport heights, frame/header/navigation
bounds and standalone state. It does not include workout or account data.
`display_debug=1` can force an additional report. The report is read from private
frontend access logs. Remove this temporary instrumentation after the issue is
verified on the phone. Browser access remains disabled in Work settings.

All 18 frontend tests and the production build passed. The viewport regression
now asserts that an ordinary standalone visual-height discrepancy does not
constrain the frame; keyboard focus, zoom, blur and cleanup are also covered.
Production hashes, contained viewport metadata and authenticated strength API
passed verification. Actual phone layout remains pending geometry/visual evidence.

- JS `/assets/index-BxpOJreC.js`, SHA-256
  `e3259ab9d065d68ad93bd7dd38c61869a8435f6a4dc7ad555f4a43382cf4ddbe`.
- CSS `/assets/index-C-Ru4Uky.css`, SHA-256
  `306b9b9dab32ccf8dcc7ee4c7b6e08e0779f0d72a83520f102203af06a7a5d04`.
- Release: `/home/admin/health/releases/standalone-20261108-om30p7fm/`.
- Backup: `/home/admin/health/backups/standalone-20261108-om30p7fm/`.
- Rollback image: `local/health-frontend:rollback-standalone-20261108-om30p7fm`.

The backend container was unchanged. No database migration or production test
workout was created.

Entry: `https://health.frankandpatrick.com/?v=standalone-20261108-om30p7fm#strength`.

## Previous unified mobile frame release

Previous frontend: `local/health-frontend:unified-20261108-4u9wmemg` (2026-11-08).

Mobile pages now share one app frame: the safe-area inset is applied once at
the frame, without the previous extra 24px guard. Both the normal page header
and workout toolbar occupy a header row outside `.health-page-content`, which
is the only main content scroller. The workout toolbar is portaled into a
shared header slot only while its tab is active. The bottom navigation occupies
a separate grid row. Mobile headers/navigation use opaque backgrounds and no
backdrop blur or fixed/sticky overlap.

Page and workout transitions reset the actual content scroller before paint,
with scroll anchoring disabled there. This addresses the reported covered
movement switcher as well as preserving a consistent top boundary between
home/templates and active training. The viewport height watcher now belongs to
the shell, retaining keyboard and pinch-zoom handling across all mobile tabs.

Home-screen mode changes from `black-translucent` to `default` status-bar style.
Apple documents the latter as placing web content below the status bar in its
[meta-tag reference](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariHTMLRef/Articles/MetaTags.html).
A fresh home-screen app launch may be needed to pick up launch-time metadata.
The actual iPhone 18 Pro appearance remains unverified; browser automation is
disabled. DOM integration checks do not simulate Safari layout or blur effects.

Validation: all 18 frontend tests and the production build passed. The new
JSDOM integration test mounts the real components, checks toolbar placement
outside the scroll pane, entry/exit and tab-change scroll resets, inactive-tab
header cleanup, first-tap number selection and viewport listener cleanup.
JSDOM is a dev-only dependency compatible with the existing Node 18 minimum;
existing dependency versions were preserved in package-lock.json.

Production asset hashes, default status-bar metadata and authenticated strength
API checks passed through the frontend proxy:

- JS `/assets/index-FpJ9gqtj.js`, SHA-256
  `70b31ce7df1fa5f3352748095ec07d523d407b51cd8715f6edd48ada4cc31171`.
- CSS `/assets/index-B0guH_no.css`, SHA-256
  `3db3c222ac00e92e86a8fc8d216a684322a6ea755b0c49cf196b5b47837e6d16`.
- Release: `/home/admin/health/releases/unified-20261108-4u9wmemg/`.
- Backup: `/home/admin/health/backups/unified-20261108-4u9wmemg/`.
- Rollback image: `local/health-frontend:rollback-unified-20261108-4u9wmemg`.

The backend container was unchanged. No database migration or production test
workout was created.

Entry: `https://health.frankandpatrick.com/?v=unified-20261108-4u9wmemg#strength`.

## Previous protected workout viewport release

Previous frontend: `local/health-frontend:mobile-20261108-olst4fxo` (2026-11-08).

Mobile training now uses a bounded app frame with a non-scrolling top inset:
the device safe area plus 24px. The workspace scrolls inside that frame, so
training controls are laid out below the status-bar area even while scrolling.
The toolbar has 8px of internal top padding instead of consuming the safe-area
inset again. This is scoped to the visible active workout and releases the
root scroll lock on exit or completion. Exercise navigation scrolls the actual
workspace as well as resetting the normal page position.

The frame follows VisualViewport height while the keyboard is open, and uses
the layout height during pinch zoom. Listener cleanup removes its CSS state.
Workout modals use the available viewport height. Mobile template buttons,
edit controls, previews and tabs have at least 44px touch targets.

All 17 frontend tests and the production build passed. The new viewport test
covers keyboard resizing, pinch zoom, desktop release and listener cleanup.
Production JS/CSS hashes and the authenticated strength API passed verification:

- JS `/assets/index-DE0UE5MZ.js`, SHA-256
  `f653fa35454291f9eab1c47e845ffb6adc5b9cbf7f332a2d089e6e452e550f02`.
- CSS `/assets/index-DR2nLF3v.css`, SHA-256
  `bc106d767517363b3f770f6ae06214051dd68648baf7d22b455abb4a6194bc94`.
- Release: `/home/admin/health/releases/mobile-20261108-olst4fxo/`.
- Backup: `/home/admin/health/backups/mobile-20261108-olst4fxo/`.
- Rollback image: `local/health-frontend:rollback-mobile-20261108-olst4fxo`.

The backend was not restarted, no schema changed and no production workout was
created. Browser automation remains disabled; the reported iPhone 18 Pro header
appearance has not been verified on that device. The implementation follows
[WebKit safe-area guidance](https://webkit.org/blog/7929/designing-websites-for-iphone-x/),
without assuming an inset from a particular phone model.

Entry: `https://health.frankandpatrick.com/?v=mobile-20261108-olst4fxo#strength`.

## Previous input and batch-fill release

Previous frontend: `local/health-frontend:edit-20261108-jowfvkk0` (2026-11-08).

Set values now use text inputs with decimal/numeric keyboards. Initial focus
selects the whole value, with selection reapplied after the first pointer click
to avoid a touch placing the caret before the number. A local editing buffer
preserves intermediate decimal input; numeric range validation still applies.

The selected row supplies an **应用到后续 N 组** action. It copies weight/reps
only to following unchecked sets, preserving IDs, completed records and warmup
flags. Newly added sets inherit the most recently edited/applied row during
the open workout, even when the last planned row contains different values.
Without an edited source, the last planned row remains the fallback. These UI
source pointers do not add fields to the stored session schema.

The mobile workout toolbar now has a full-width solid background and additional
spacing after the safe-area inset. Its entrance animation is disabled. The
page uses `overflow-x: clip` where supported to avoid introducing a scroll
container around sticky elements. This targets the reported header blur and
positioning issue, but phone visual verification remains unavailable. Safe-area
handling follows [WebKit guidance](https://webkit.org/blog/7929/designing-websites-for-iphone-x/).

Validation: all 16 frontend tests and the production build passed, including
batch-fill protection for completed sets, edited-source inheritance, load modes,
input keyboard markup, prefill and report regression coverage. Deployed resources:

- JS `/assets/index-Dr7n-uaD.js`, SHA-256
  `cc536d5536a26240aa6328516b3459d136aff378da382d760b2a29149ec708c2`.
- CSS `/assets/index-B_7f4szI.css`, SHA-256
  `54f40d3eab9caf2778ec5dbd266507a86c607d21093fb3a8d909f3fb2c0c5e61`.
- Release: `/home/admin/health/releases/edit-20261108-jowfvkk0/`.
- Backup: `/home/admin/health/backups/edit-20261108-jowfvkk0/`.
- Rollback image: `local/health-frontend:rollback-edit-20261108-jowfvkk0`.

Production asset hashes and the authenticated strength API passed through the
frontend proxy. The backend container was unchanged; no database migration or
test workout was created. Browser automation is disabled; selection/touch and
header appearance have not been verified on a real phone.

Entry: `https://health.frankandpatrick.com/?v=edit-20261108-jowfvkk0#strength`.

## Previous focused workout release

Previous frontend: `local/health-frontend:focus-20261108-wc5aqqea` (2026-11-08).

The workout view now focuses on one exercise, with previous/next navigation
and a modal listing all actions and their completed sets. Resuming a workout
opens the first unfinished action. On mobile, its own toolbar replaces the
normal page header and bottom navigation while the workout is open; returning
to templates restores them. Rest countdowns sit inside the exercise card.
Unchecked sets show an empty circle; completed sets show a green check.

Aggregate load/tonnage and its distribution chart have been removed. Editable
per-set weights/repetitions, previous-session prefill, unit conversion and saved
records are retained. The completed report uses one grouped sheet with duration,
completed sets, total repetitions, earlier exercise comparisons and expandable
set details. A completed working set without comparable historical work sets
now correctly says there is no comparable history.

Validation: all 13 frontend tests and the production build passed. Tests cover
restored focus, mobile focus-view isolation from inactive tabs, prefill, pause
and rest persistence, checked-set totals, report rendering and comparisons.
Production resources were verified through the frontend proxy:

- JS `/assets/index-DmBv6ZQo.js`, SHA-256
  `8d660c7727c407859f755e103d2c5de2dc6059f8b9b6d7e59dbfb26be8200645`.
- CSS `/assets/index-DvclOjLN.css`, SHA-256
  `0d45d14bd7d56aeb8e57c2f1ad252075a65e4430de7c2d1619069d78b0f4aa58`.
- Release: `/home/admin/health/releases/focus-20261108-wc5aqqea/`.
- Previous frontend archive, Compose configuration and rollback image:
  `/home/admin/health/backups/focus-20261108-wc5aqqea/` and
  `local/health-frontend:rollback-focus-20261108-wc5aqqea`.

The authenticated strength catalog passed verification. The backend container
was unchanged; no database migration or production test workout was created.
Browser automation is disabled, so these checks do not claim browser or phone
visual verification.

Entry: `https://health.frankandpatrick.com/?v=focus-20261108-wc5aqqea#strength`.

## Previous compact tracking release

Previous frontend: `local/health-frontend:compact-20261108-5ikhlw-r2` (2026-11-08).
This release makes both templates compact launch cards with on-demand movement
previews, replaces the tall workout summary with a compact sticky toolbar and
four-column set editor, and moves optional effort into exercise settings.

New workouts and added exercises prepopulate weight/reps from completed
same-exercise, same-load-mode history. Active drafts fill only empty fields
once history is ready; checked sets and manual entries are preserved. These
draft values never count as performed until checked. Same-day date-only imports
can seed a draft but are excluded from report comparisons with uncertain order.

Completion and **训练 → 历史** now open a dedicated report: duration, performed
sets/reps, external-load volume/distribution, earlier same-exercise comparisons,
and expandable completed-set tables. Empty sessions explicitly report no
performed sets. Reports use saved records and do not invoke an AI model.

All 13 frontend tests and the production build passed. Deployed bundle:

- JS `/assets/index-wFLw9bfT.js`, SHA-256
  `4b9723bb08b6b4ebc41c2e550421557937aea36a0643ce5fe2b6a6f75c2e051f`.
- CSS `/assets/index-De8UKiHG.css`, SHA-256
  `caa32ef99e46e6b734c9987398937347635b66ac3b2e00bf31721d80f0e57d40`.
- Release and rollback files are under
  `/home/admin/health/releases/compact-20261108-5ikhlw-r2/` and
  `/home/admin/health/backups/compact-20261108-5ikhlw-r2/`.

Production asset hashes and the authenticated strength API were verified through
the frontend proxy. Backend remains `strength-20261107-i2rgzv`, without a restart
or database migration. Browser automation remains disabled, so no phone/browser
visual verification is claimed.

Entry: `https://health.frankandpatrick.com/?v=compact-20261108-5ikhlw-r2#strength`.

## Shared design refresh

Previous frontend: `local/health-frontend:design-20261107-5rxrep` (2026-11-07).
The visual refresh follows Wealth and Media's 220px desktop sidebar, mobile
bottom navigation, system typography, blue actions and shared light/dark
surfaces. It updates the app shell, strength pages and login view.
Backend remains `local/health-backend:strength-20261107-i2rgzv` and was not
restarted for this frontend deployment. No database migration was run.

The six frontend tests and production build passed. Authenticated verification
through the production frontend proxy confirmed the strength catalog still
works and that the served JS/CSS match the build hashes:

- JS: `/assets/index-B84QBGUe.js`
  (`a4dc5a666bc6d60de6c4890c8cf3a394be188509cfd22705f29e86be7331aa27`).
- CSS: `/assets/index-NtWAM9i7.css`
  (`ea748866e688ec47329a7236325353ee545882ad93d6d6b3cdc58f9a9662f8e9`).
- Frontend rollback archive and previous Compose image selection:
  `/home/admin/health/backups/design-20261107-5rxrep/`.
- Release sources and deployment script:
  `/home/admin/health/releases/design-20261107-5rxrep/`.
- Current entry point:
  `https://health.frankandpatrick.com/?v=design-20261107#strength`.

## Initial strength release

Deployed 2026-11-07 to the existing Raspberry Pi health stack at
`health.frankandpatrick.com`. Release: `strength-20261107-i2rgzv`.

- Runtime: `fitness-api` and `fitness-ui`, with images tagged
  `local/health-backend:strength-20261107-i2rgzv` and
  `local/health-frontend:strength-20261107-i2rgzv`.
- The existing backend dependencies and nginx configuration were preserved by
  building on the previous production images. Only application code and the
  compiled frontend were replaced.
- Production image selection persists in
  `/home/admin/health/docker-compose.override.yml`; normal Compose commands load
  this together with the existing `docker-compose.yml`.
- Release sources and validation logs:
  `/home/admin/health/releases/strength-20261107-i2rgzv/`.
- Consistent SQLite backups, previous source archive and image identifiers:
  `/home/admin/health/backups/strength-20261107-i2rgzv/`.
- Previous images are also tagged
  `local/health-backend:rollback-strength-20261107-i2rgzv` and
  `local/health-frontend:rollback-strength-20261107-i2rgzv`. Image rollback does not require
  restoring the database: the new schema is additive.

Validation: all 42 backend tests passed in an isolated container on the Pi,
with networking disabled. A copy of the production database migrated without
changing existing row counts. An authenticated request through the production
frontend proxy confirmed 9 exercises, two templates with 15 and 16 sets, and
the new session endpoints. The served frontend bundle is
`/assets/index-BQQtdFa7.js`, SHA-256
`475c429d324221c1d3da1989aa1bd6a54a755b70d2d447075fb9c479015b8fa7`.
No test workouts were created in the production database.

The public hostname returned HTTP 403 to command-line requests before and
after deployment; browser automation is disabled in the current Work settings.
Verification therefore used the production origin and its authenticated proxy,
not a browser session. Existing access/security settings were left as configured.

Entry point: `https://health.frankandpatrick.com/?v=strength-20261107#strength`.
