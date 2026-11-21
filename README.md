# Health / Pine

A native SwiftUI iPhone app, Raspberry Pi FastAPI server, and companion React web
dashboard with AI observations using a ChatGPT Plus/Pro plan.

This repository contains the complete build source and required app assets for
Pine **1.3.0 (10)**, plus the verified Pi server/web baseline
`dialog-diagnostics-20261118`. Start with [恢复与交接说明](docs/RESTORE.md).
The [archived IPA and source package](artifacts/ios/1.3.0/) include checksums and
build validation. Private credentials and health records require the separate
encrypted server backup; they are not part of this public source repository.

| Area | Entry point |
| --- | --- |
| Native iPhone app | [`ios/README.md`](ios/README.md), [`ios/DESIGN.md`](ios/DESIGN.md) |
| API, models, prompts, catalogues | [`backend/`](backend/) |
| Companion web UI and muscle geometry source | [`frontend/`](frontend/) |
| Pi production deployment | [`docker-compose.yml`](docker-compose.yml) |
| Portable source deployment and host scripts | [`ops/`](ops/) |
| Server byte provenance | [`docs/provenance/raspberrypi-20261118.json`](docs/provenance/raspberrypi-20261118.json) |

## Architecture

```
┌─────────────────────────────────────────────┐
│  Frontend (React + Vite + Tailwind)         │
│  Port 5173 (dev) / 80 (prod via nginx)      │
├─────────────────────────────────────────────┤
│  Backend (FastAPI + SQLite)                  │
│  Port 8000                                   │
│  ├── Google Health + saved Xunji archive    │
│  ├── APScheduler (3 daily analyses)         │
│  ├── ChatGPT-plan Responses API             │
│  └── Optional Telegram notifications        │
└─────────────────────────────────────────────┘
```

## Quick Start (Development)

### Prerequisites
- Python 3.11+
- Node.js 24 (see `.nvmrc`)

### Backend

```bash
cd backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

Open http://localhost:5174 — the Vite dev server proxies `/api` to the backend.

## Native iPhone app

[`ios/Health.xcodeproj`](ios/Health.xcodeproj) now builds Pine 1.3 as a SwiftUI app:
login, overview, training entry, templates, native charts/muscle maps, saved reports,
observations and settings. There is no WKWebView in the app target. It reuses the
current Raspberry Pi API and the user's existing saved records and templates.

The baseline was verified against the running `dialog-diagnostics-20261118` release,
including its active asset hashes, before local development. See
[baseline provenance](docs/native-ios-baseline.md) and the
[native build/install guide](ios/README.md). The guide also describes offline drafts,
conflicts, existing Live Activities/reminders and notification/signing boundaries.

## Deploy on Raspberry Pi (Docker)

### 1. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in
```

### 2. Choose a recovery mode

Follow [docs/RESTORE.md](docs/RESTORE.md). The root compose file is the actual Pi
production configuration: external `health_fitness-data` volume, non-root users,
read-only filesystems, HTTPS cookies, LAN binding and optional media bridge mounts.
It needs the existing private configuration and storage to be restored first.

For a clean, local source build, use `ops/compose.standalone.yml` as documented in
that guide; it serves only `http://localhost:9999` and needs no cloud-reel service.

### Connect a ChatGPT plan

ChatGPT authorization uses a browser callback on the computer running the browser. For a headless Raspberry Pi, complete OAuth locally and transfer the protected credential file over SSH:

```bash
python3 -m venv .login-venv
. .login-venv/bin/activate
pip install -r tools/requirements-login.txt
python tools/chatgpt_login.py --output secrets/chatgpt-oauth.json
scp secrets/chatgpt-oauth.json admin@raspberrypi:/home/admin/health/secrets/
```

The backend refreshes the OAuth token automatically. It never falls back to an API key or API billing.

### Optional Telegram notifications

Create a private bot with `@BotFather`, then run:

```bash
python tools/telegram_setup.py --output-dir secrets
scp secrets/telegram-bot-token secrets/telegram-chat-id admin@raspberrypi:/home/admin/health/secrets/
```

The setup sends a test message. New morning, evening and weekly reports queue a
Web Push notification after saving. When no Web Push subscription is registered,
the configured Telegram bot can deliver the same report-ready reminder.

The morning analysis starts at 08:30 America/New_York and retries every 15
minutes through 12:15 while waiting for the main sleep to sync. The evening
analysis runs at 21:00, and the weekly review runs on Mondays at 09:00.

### 4. Monitor

```bash
docker compose logs -f
docker compose ps
```

## Deploy without Docker (systemd)

### Backend Service

Create `/etc/systemd/system/fitness-api.service`:

```ini
[Unit]
Description=Fitness Dashboard API
After=network.target

[Service]
User=pi
WorkingDirectory=/home/pi/fitness/backend
Environment=OPENAI_MODEL=gpt-6.1-sol
Environment=CHATGPT_CREDENTIALS_FILE=/home/pi/fitness/secrets/chatgpt-oauth.json
Environment=DB_PATH=/home/pi/fitness/data/fitness.db
ExecStart=/home/pi/fitness/backend/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
MemoryMax=256M

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable fitness-api
sudo systemctl start fitness-api
```

### Frontend (Static Build)

```bash
cd frontend
npm run build
# Serve dist/ with nginx or python -m http.server
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_MODEL` | `gpt-6.1-sol` | ChatGPT-plan model used by the Responses API. |
| `OPENAI_REASONING_EFFORT` | `low` | Reasoning level used for scheduled and manual analysis. |
| `CHATGPT_CREDENTIALS_FILE` | `/run/secrets/fitness/chatgpt-oauth.json` | Protected Sign in with ChatGPT credential record. |
| `TELEGRAM_NOTIFICATIONS_ENABLED` | `true` | Enables notifications when protected Telegram secret files are present. |
| `DASHBOARD_USER` | required | Dashboard login username. |
| `DASHBOARD_PASS` | required | Dashboard login password. |
| `JWT_SECRET` | required | Long random secret used to sign the HTTP-only session cookie. |
| `COOKIE_SECURE` | auto | Set to `true` behind HTTPS; use `false` only for direct HTTP/LAN access. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | required for health data | Google OAuth client credentials. |
| `GOOGLE_REDIRECT_URI` | required for health data | Exact OAuth callback URL configured in Google Cloud. |
| `DB_PATH` | `fitness.db` | Path to SQLite database file. |

## Features

The strength tab now has a curated **24-exercise** library matched to the user's
gym equipment, with Chinese steps, muscle/equipment filters, template and report
body maps, and a Monday-based weekly working-set distribution. Templates can opt
into double progression with a configurable rep range and load increment; every
target includes its reason and unfinished sets never count as progression success.
Existing templates and training history are preserved. See
[the equipment mapping and behavior](docs/gym-exercises.md).

The activity log combines completed App workouts, previously imported Xunji
records and the frozen Google Health activity archive in one timeline.
首页 → 今日观察 shows morning, evening and weekly reports alongside the archive
of previously saved sleep, health and training analyses.

### Daily and weekly observations

The morning report covers the main sleep and its recent baseline. The evening
report reviews activity and health for the day through the recorded snapshot.
If a strength workout was completed in the App that day, the report uses the
morning report, current health data and comparable past sets where available.
Supporting dates, sample counts and limitations appear under **查看依据**.

The sleep context includes up to 28 calendar days of personal history, actual
sleep windows and paired-night decomposition of time asleep versus time awake.
Missing physiological values remain null in analysis inputs. Naps and duplicate
main sleeps are excluded from baselines. Identical inputs reuse stored reports.

**每周观察** appears in Summary. It covers the seven complete days
ending yesterday and compares with the preceding five weeks, including sample
coverage, distributions, individual nights and cached workout records. It shows
zero to three findings with no forced categories or next-week plan. Missing
nights are shown as gaps, never zero sleep. It runs on Mondays at 09:00 in the
configured timezone; **生成分析** creates a rolling review on demand.

New endpoints: `GET /api/insights/weekly` and
`POST /api/insights/weekly/generate`. Generation is explicit; GET is read-only.
Existing historical text reports remain available collapsed. SQLite migrations
add report JSON, prompt version and input snapshots without removing history.

Verification: `PYTHONPATH=backend python -m unittest discover -s backend/tests -v`.

- **Bento Grid Dashboard** — Steps, sleep, calories, active minutes, HRV
- **Training Insights** — AI analysis of recent workout trends
- **Strength tracking** — A dedicated **训练** tab with the two supplied routines:
  背·三角肌后束·二头 (15 sets) and 胸·三角肌中束·三头 (16 sets), sharing a
  library of nine exercises. Templates can be edited; each workout keeps its
  own snapshot. Templates use compact launch cards; their movement lists open
  on demand. Weight/reps are prepopulated from the previous completed sets of
  the same exercise and load mode, including exact-name matches from cached
  Xunji history. Extra planned sets repeat the last known values. A reopened
  active draft fills empty fields once history loads, preserving manually
  entered values and already completed sets. Prefilled sets still need a check
  mark to count as performed. Date-only imports from the current local day
  cannot establish an earlier session and are excluded from comparisons.
  Supports kg/lb, assistance and bodyweight, warmups, optional exercise effort,
  inline rest countdowns, pause/resume, notes, custom exercises and saving a workout
  as a new template. The workout view focuses on one exercise at a time, with
  previous/next navigation and an all-exercise switcher. Mobile workouts use a
  dedicated toolbar in place of the normal header and bottom navigation. Mobile
  pages share a single frame with solid headers outside the scrolling content.
  Browser-contained viewport settings own the screen insets. The app fills the
  provided window without a permanent JavaScript height override; visual viewport
  height is used only for a focused field with an open keyboard. The workout
  toolbar uses the same header slot; page transitions reset the actual content
  scroller before paint. Its ending action is a text button. Home-screen status
  bar styling follows the platform default. Mobile set rows and completion
  controls retain 44px touch targets, with compact fill/rest and action rows
  designed to fit a four-set exercise on one screen. Notes and session options
  open from a single tool row. Temporary display diagnostics have been removed
  after the phone geometry and improved appearance were confirmed.
  Template controls use at least 44px touch targets on phones. Tapping
  a set value selects the entire number for replacement. Bulk fill appears only
  after a real weight/reps change and when following unchecked sets differ;
  focusing a value or reverting the change leaves it hidden. Applying it hides
  the action again. It fills all following unchecked sets; completed records and
  warmup flags are preserved. New sets inherit the most recently edited row
  during the open workout, falling back to the last planned row. Only
  checked sets count toward performance; aggregate load/tonnage is not displayed.
  Changes are saved to the browser immediately and synchronized to SQLite.
  Reopening the same browser restores an active draft; transient connection
  failures retry while the page is open. Conflicting server versions require a
  choice and preserve the other copy locally. First use requires a connection;
  offline reloading of the app shell is not supported. Completion timestamps
  do not infer set start times or start a Google Health/device workout.
  Completed records feed the existing training, daily and weekly observations.
  Completing a workout opens a separate report with duration, performed sets,
  repetitions and per-exercise comparisons in one grouped report. Per-set
  weights remain in expandable details. Warmups and assistance are separated; only
  equivalent set counts receive a same-load repetition delta. Zero completed
  sets produce an explicit empty report, never inferred performance. Reports
  for existing sessions remain available under **训练 → 历史** and are computed
  from saved records without a model call.
  Reports also match Google Health heart-rate samples to the saved physical
  start/end window, including rests and pauses, without requiring a matching
  device workout. They show sample mean/min/max, a minute chart with gaps,
  coverage, wearable steps and estimated active energy. Daily sleep/HRV/resting
  heart rate are labeled separately as cached recovery context. A durable SQLite
  queue fetches after completion and retries delayed cloud data for up to seven
  days even when the page is closed; manual refresh also works for older history.
  Multiple heart-rate sources require a choice instead of being averaged together.
  Missing data is never displayed as zero. The report first waits for automatic
  collection; only empty, partial or failed results offer the official Universal
  Link to Google Health Today for synchronization. Ready data hides the link;
  returning from the app queues a fresh fetch.
  See [workout physiology](docs/workout-physiology.md)
  for synchronization limits and retry behavior.
  History cards and completed reports include deletion with confirmation. Deletion
  requires a saved, online record and removes its strength/physiology rows and
  dependent analysis caches. Only ID/version/time markers remain to reject stale
  saves (HTTP 410); clients reconcile these markers on refresh/foreground return
  and clear local records and comparison hints, including unsynced stale copies.
  Existing databases receive additive tables; startup never resets edited templates.
- **AI Timeline** — Morning/Noon/Evening AI-generated health reports
- **Scheduled AI** — APScheduler triggers ChatGPT-plan analysis 3x/day and analyzes new training/sleep data
- **Phone notifications** — Optional private Telegram delivery after each completed analysis; Home Screen Web Push for workout heart-rate reports. Enable with a user tap under the header gear **设置**. See [Web Push setup and behavior](docs/web-push.md).
- **Dark Mode** — Follows the device color scheme
- **Raspberry Pi optimized** — Low memory footprint, SQLite, Docker memory limits

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/status` | Health check |
| GET | `/api/webpush/config` | Authenticated VAPID public key |
| POST / DELETE | `/api/webpush/subscriptions` | Enable/disable this browser subscription |
| GET | `/api/webpush/subscription?id=...` | Read whether this browser is subscribed |
| GET | `/api/health/today` | Today's metrics |
| GET | `/api/health/history?days=14` | Historical metrics |
| GET | `/api/workouts/recent?limit=10` | Recent workouts |
| GET | `/api/workouts/stats` | Workout statistics |
| GET | `/api/strength/catalog` | Exercise library and saved templates |
| POST | `/api/strength/exercises` | Add a custom exercise |
| PUT | `/api/strength/templates/{id}` | Save a template with version checking |
| GET | `/api/strength/sessions` | Active and most recent 100 recorded sessions |
| GET / PUT | `/api/strength/sessions/{id}` | Read or save a recorded session |
| POST | `/api/strength/sessions/{id}/delete` | Browser deletion with JSON expected_version, timeout and result reconciliation |
| DELETE | `/api/strength/sessions/{id}?expected_version=N` | Compatible version-checked deletion API |
| GET | `/api/strength/session-deletions` | Deletion markers for reconciling local caches |
| GET | `/api/strength/sessions/{id}/physiology` | Read cached workout-window health data and sync status |
| POST | `/api/strength/sessions/{id}/physiology/refresh` | Queue another cloud fetch (30-second cooldown) |
| PUT | `/api/strength/sessions/{id}/physiology/source` | Choose a returned heart-rate source |
| GET | `/api/insights/today` | Today's AI insights |
| GET | `/api/insights/history?days=7` | Insight history |
| POST | `/api/insights/generate/{slot}` | Trigger AI insight (morning/noon/evening) |
| GET | `/api/insights/training` | Latest training analysis |
| POST | `/api/insights/training/generate` | Trigger new training analysis |
| PUT | `/api/strength/exercises/{id}/setup-note` | Save or clear an exercise's standing setup note |
| GET | `/api/body` | Girths and daily protein recorded on the phone |
| PUT / DELETE | `/api/body/measurements/{id}` | Save (idempotent by id) or delete one girth reading |
| PUT | `/api/body/protein/{date}` | Set a day's protein total (0 removes it) |
| GET | `/api/insights/sleep` | Read today's stored sleep analysis |
| POST | `/api/insights/sleep/generate` | Trigger a new sleep analysis |

Strength verification: run the Python test command above, then `cd frontend &&
npm test && npm run build`. Tests use isolated SQLite databases and do not call
Google Health, Xunji, ChatGPT or Telegram. For a phone check after deployment,
open **训练**, start either template, record one set, pause/resume, refresh,
then complete the workout and open **历史**. Verify that the unchecked sets are
excluded and that kg/lb and assisted loads retain their meanings.
