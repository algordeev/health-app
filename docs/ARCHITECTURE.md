# Wearable Health Companion: Architecture & Plan

## Context
We're building a better companion app for Google's $99 Fitbit Air (launched May 2026). It pulls sleep, heart rate and activity through the official **Google Health API (v4)**, shows a one-screen daily summary with weekly and monthly trends, and adds an AI coach (Claude) that explains trends in plain language. The legacy Fitbit Web API was turned off on Nov 2, 2026, so Google Health API v4 is the only option.

**Team and cadence:** two developers, with a progress demo every week. **Platforms:** Android and iOS.

**Demo Day targets:** (a) a real Fitbit Air syncing live, (b) 5 users compare our morning summary with the official app, (c) "Why did I sleep badly this week?" answered with the numbers behind it.

---

## 1. Facts from the Google Health API that shape the design
- Base URL: `https://health.googleapis.com/v4`. Auth is Google OAuth 2.0 with scopes `https://www.googleapis.com/auth/googlehealth.{scope}`.
- **Scopes we need (read-only):** `sleep.readonly`, `activity_and_fitness.readonly`, `health_metrics_and_measurements.readonly`, `profile.readonly`.
- **Data types for the MVP:** `sleep`, `daily-resting-heart-rate`, `daily-heart-rate-variability`, `steps`, `active-zone-minutes`, `activity-level` (gives active minutes), `total-calories`, `daily-oxygen-saturation`. We skip intraday `heart-rate` for the MVP.
- **Read method:** `dataPoints:dailyRollUp` (with `windowSizeDays: 1` for one day). Because these are Google's own daily rollups, our morning numbers should match the official app, which is what Demo Day target (b) tests. We don't recompute them ourselves.
- **Webhooks:** one subscriber per GCP project with the `AUTOMATIC` policy. Notifications carry metadata only (`healthUserId`, `dataType`, intervals), so we fetch the data afterwards. Each one comes with an `Authorization` secret and an ECDSA P-256 signature (`GOOGLE-HEALTH-API-SIGNATURE`; public keyset on gstatic, rotated every 30 days). We must reply 204 quickly, and retries can deliver duplicates.
- **Restricted scopes:** an unverified app is capped at 100 users, which is fine for the demo. Full verification needs a CASA assessment and is out of scope. ⚠️ Google OAuth apps in "Testing" status get refresh tokens that expire after about 7 days. Before the 5-user test we must either publish the consent screen as "In production" (unverified, which shows a warning screen) or plan for weekly re-consent. Verify this in week 1.

## 2. System architecture

```
 Flutter app (iOS/Android)
   │  supabase_flutter (JWT)                    ┌──────────────────────────┐
   ├──────────────► Supabase Postgres (RLS) ◄───┤ Edge Functions (Deno/TS) │
   │                daily_metrics, insights…    │                          │
   │                                            │ health-oauth-start       │──► Google OAuth consent
   ├── open browser ───────────────────────────►│ health-oauth-callback    │◄── code → tokens (stored encrypted)
   │                                            │ health-webhook           │◄── Google Health webhooks
   ├── invoke ─────────────────────────────────►│ sync-worker (pg_cron 1m) │──► health.googleapis.com/v4 dailyRollUp
   │                                            │ nightly-reconcile (cron) │
   ├── invoke (streaming) ─────────────────────►│ coach-chat               │──► Claude API (tool use over SQL)
   │                                            │ weekly-insight (cron)    │
   └── invoke ─────────────────────────────────►│ export-data / delete-account │
                                                └──────────────────────────┘
```

**Two-step auth (decided):**
1. **Identity:** native Google Sign-In (`google_sign_in`), then `supabase.auth.signInWithIdToken`. This requests basic scopes only.
2. **Connect Google Health:** the app opens the `health-oauth-start` URL in a browser via `flutter_web_auth_2`. That function builds the Google consent URL with `access_type=offline`, `prompt=consent`, the health scopes, and `state` (a signed nonce tied to the Supabase user). `health-oauth-callback` exchanges the code, calls `users.getIdentity` to get the `healthUserId`, stores the refresh token encrypted (Supabase Vault / pgsodium), queues a 90-day backfill, and redirects to the app deep link `healthcompanion://connected`.

**Sync pipeline:**
- `health-webhook` checks the Authorization header and signature, inserts rows into `sync_queue` (idempotent unique key on user, data type and date), and returns 204. It does no heavy work.
- `sync-worker` runs every minute via pg_cron + pg_net. It claims queue rows, refreshes the access token, calls `dailyRollUp` for the affected dates and data types, upserts into `daily_metrics`, and records `last_synced_at`.
- `nightly-reconcile` re-pulls the last 3 days for every connected user, as a safety net for missed webhooks.
- The app has a "Sync now" control that queues today's date, so the live-sync demo doesn't depend on webhook timing.
- We store **daily aggregates only**. Raw intraday streams are never stored.

## 3. Data model (Postgres, RLS on every table: `user_id = auth.uid()`)
| Table | Key columns |
|---|---|
| `profiles` | user_id PK, display_name, timezone, health_consent_at, coach_consent_at |
| `health_connections` | user_id PK, health_user_id UNIQUE, refresh_token_secret_id (Vault), scopes[], status (active/revoked/error), connected_at, last_synced_at |
| `daily_metrics` | (user_id, date) PK; sleep_minutes, sleep_efficiency, deep/rem/light/awake_min, bedtime, wake_time, resting_hr, hrv_ms, spo2_avg, steps, active_zone_min, active_min, total_calories, updated_at |
| `sync_queue` | id, user_id, data_type, date, status, attempts, last_error, UNIQUE(user_id, data_type, date, status='pending') |
| `weekly_insights` | (user_id, week_start) PK, summary_md, facts_json, model, created_at |
| `coach_messages` | id, user_id, thread_id, role, content, facts_json (numbers cited), created_at |
| `consent_events` | id, user_id, kind, granted, at (audit trail) |
| `summary_feedback` | user_id, date, matches_official (bool), note — for Demo Day target (b) |

The service role writes `daily_metrics` and `health_connections`. Clients can only read them.

## 4. AI coach (Claude)
- **Model:** `claude-sonnet-5-5` for chat and weekly insights (confirm the current ID via the claude-api skill at implementation time). It's called only from Edge Functions; the API key never ships in the app.
- **"Light RAG" = tool use over aggregates, not vector search.** Tools exposed to Claude:
  - `get_daily_metrics(start, end, fields[])`
  - `compare_periods(metric, period_a, period_b)`, which returns means, deltas, best and worst days
  - `get_past_insights(n_weeks)`
  Each call retrieves only the user's own rows, server-side, and never raw streams.
- The system prompt is wellness-only: no diagnosis or medical claims, suggest seeing a clinician for concerning patterns, and cite the numbers for every claim.
- Each response returns `facts_json` (the tool results it used). The app renders those as a "Numbers behind this" card under the answer, which delivers Demo Day target (c).
- `weekly-insight` runs on cron every Monday per user, and is also triggerable from the app.

## 4b. Game layer: character, points, streaks, tasks, friends
**Principles**
- Points are computed **deterministically server-side** from `daily_metrics`, never by the LLM. That keeps them fair and explainable, and they can't be gamed by chatting.
- Claude only supplies the character's *voice* and suggests tasks.
- Health-safe scoring: points peak inside healthy ranges rather than rewarding "more is better" without limit. Daily caps prevent overtraining, rest days earn credit, and sleeping less never earns points.
- **Fair between friends:** most points come from progress against *your own* 28-day baseline, so a beginner who walks can beat a marathoner who skipped a day.
- **Privacy:** friends see only character, level, points, streaks and mood. They never see raw health numbers. Sharing is opt-in, and its own consent is recorded in `consent_events`.

**Scoring engine** (`supabase/functions/_shared/scoring/`, pure TypeScript, unit-tested, rules versioned)
- Runs after `sync-worker` upserts a date, and recomputes that date's points from scratch, so late-arriving data is handled and the result is idempotent.
- Example rules for v1:
  - **Sleep:** duration in the 7–9h band, bedtime consistency within ±45 min of your median, and efficiency.
  - **Activity:** step tiers against your baseline, active-zone minutes, plus a bonus for a logged exercise session such as a run (`exercise` data type).
  - **Recovery:** HRV or resting heart rate at or better than baseline.
  - **Tasks:** completing them.
  - **Streak multipliers:** applied on top, with a cap.

**Character**
- An original mascot with a name the user picks. It levels up from XP (total points).
- **Mood** is derived from the last 3 days (e.g. *energized / content / sleepy / sluggish / proud*). Mood drives its animation state and its tone in the coach. Animations are simple Rive or Lottie states such as idle, happy, yawning or stretching.
- The character comments on the day ("You slept 38 min more than your usual. I feel great!"). Claude generates these lines using a persona prompt plus the same `facts_json`, with the same no-diagnosis guardrails.

**Streaks:** daily streaks for hitting the sleep window, for a step goal, and for "any goal". Each has one freeze per week so a single bad day doesn't wipe out progress. **Team streaks** (shared with a friend) only grow when both people hit their goal that day.

**Tasks (goals):** created by the user or *suggested by the coach* from weak spots ("Lights out before 23:30 for 3 nights"). They can be daily or weekly, and are checked automatically against `daily_metrics`.

**Friends & events**
- Friends are added with an invite code or link.
- The **friends leaderboard** for today and this week shows points only.
- **Challenges/events** are time-boxed, e.g. "Weekend 20k steps", "Early-bed week", or a co-op "Together 300 AZM". They're either competitive (most points) or co-op (shared target).
- An activity feed shows items like "Alex's character leveled up" and "Team streak: 5 days".
- **Optional, if time allows:** push notifications via FCM for "streak at risk", "friend challenged you" and "challenge ends tonight".

**Extra tables (RLS on all)**
| Table | Key columns |
|---|---|
| `characters` | user_id PK, name, avatar_key, level, xp, mood, mood_reason, updated_at |
| `point_events` | id, user_id, date, source (sleep/activity/recovery/task/streak/challenge), rule_id, rule_version, points, meta, UNIQUE(user_id, date, source, rule_id) |
| `streaks` | (user_id, kind) PK, current, best, last_date, freezes_left |
| `tasks` | id, user_id, title, metric, comparator, target, period, origin (user/coach), status, due_date |
| `friendships` | (user_a, user_b) PK, status (pending/accepted), invite_code |
| `challenges` / `challenge_members` | id, creator_id, title, type (competitive/coop), metric, target, starts_at, ends_at / (challenge_id, user_id), points |
| `team_streaks` | (user_a, user_b) PK, current, best, last_date |

Friends read each other's data only through a `security definer` RPC, `get_friend_board()`, which returns just public game fields. There are no direct cross-user table reads.

## 5. Flutter app
- **Stack:** Flutter stable, Riverpod, go_router, supabase_flutter, fl_chart, google_sign_in, flutter_web_auth_2, intl.
- **Screens:** Onboarding & consent → Sign in → Connect Google Health → **Today** (character + mood at the top, today's points, sleep / heart / activity cards, last-synced time, Sync now, "Matches the official app?" feedback) → **Trends** (week/month toggle, per-metric charts with fl_chart) → **Coach** (weekly insight + chat with fact cards; character voice) → **Play** (tasks, streaks, friends leaderboard, challenges, feed) → **Settings** (export JSON/CSV, disconnect, delete account, sharing toggle, privacy text).
- Extra packages: `rive` (or `lottie`) for character animation, `share_plus` for invite links, `firebase_messaging` (optional).
- Data access goes through a repository layer over Supabase, so screens never call the network directly.

## 6. Repo layout (monorepo)
```
health-app/
  docs/ARCHITECTURE.md, docs/API_NOTES.md, docs/DEMO_SCRIPT.md
  app/                      # Flutter project (lib/features/{auth,today,trends,coach,play,settings}, lib/data/)
  supabase/
    migrations/20261106000000_init.sql
    functions/{_shared,health-oauth-start,health-oauth-callback,health-webhook,sync-worker,nightly-reconcile,coach-chat,weekly-insight,export-data,delete-account}/
    config.toml
  .env.example              # GOOGLE_CLIENT_ID/SECRET, HEALTH_WEBHOOK_SECRET, ANTHROPIC_API_KEY…
```
Development runs against a hosted Supabase dev project, because webhooks need a public HTTPS endpoint. Local Supabase covers schema and unit work.

## 7. Weekly milestones (A = mobile, B = backend + AI)
| Week | A (Flutter) | B (Supabase/Google/Claude) | Weekly demo |
|---|---|---|---|
| 0 (now) | Install Flutter, scaffold app, theme, navigation shell | GCP project + Health API + OAuth client, Supabase project, the init migration, ARCHITECTURE.md | Architecture walkthrough, empty app running on both platforms |
| 1 | Sign-in + Connect Health flow, deep link | OAuth start/callback, encrypted tokens, 90-day backfill via dailyRollUp | Real Fitbit Air account connected, raw numbers in DB |
| 2 | Today screen, Sync now | Webhook subscriber + verification, sync_queue, worker, nightly reconcile | **Live sync** (target a) |
| 3 | Trends week/month charts; character on Today (static mood art) | Scoring engine v1 + `point_events`, streaks, character XP/mood; weekly-insight function | Charts, points and character mood from real data |
| 4 | Coach chat UI + "numbers behind it" cards; character animations | coach-chat with tool use, streaming; character voice lines | **"Why did I sleep badly?"** (target c) |
| 5 | Play tab: tasks, streaks, friends leaderboard; Settings export/delete | Tasks (user + coach-suggested), friendships + `get_friend_board()`, export/delete, token revoke | Onboard 5 testers as friends (target b) |
| 6 | Challenges UI, feed, polish, empty/error states | Challenges + team streaks, optional FCM, demo seed accounts, DEMO_SCRIPT.md | Demo Day rehearsal: two friends racing a challenge live |

If we fall behind, cut in this order: push notifications, then the feed, then team streaks, then challenges. Points, character, streaks, tasks and the leaderboard stay.

## 8. Risks
- Testing-mode refresh tokens expire after about 7 days (section 1). We verify this early.
- Fitbit Air may not report every data type (e.g. SpO2 and HRV are device-dependent). The UI hides cards with no data.
- Webhook timing is unpredictable for a live demo. Mitigation: Sync now plus a pre-connected demo account.
- Timezones: dailyRollUp uses civil dates. We store the user's timezone and key everything by local date.

## Verification
- `supabase db reset` applies the migration. An RLS test confirms user A can't read user B's rows.
- Deploy the webhook function, create the subscriber, and confirm both verification POSTs pass (200/201, then 401/403).
- Connect a real Fitbit Air account and check that the `daily_metrics` rows for the last 7 days match the Google Health app by hand.
- Edge-function unit tests (Deno) for signature verification, queue idempotency and rollup mapping. Flutter widget tests for Today and Trends using fixture data.
- Scoring unit tests (Deno) on fixture weeks:
  - recomputing a date twice gives the same `point_events`
  - scores are capped
  - short sleep never earns sleep points
  - two users with different baselines are scored fairly
- An RLS test confirms a friend can read `get_friend_board()` but not your `daily_metrics`. A non-friend gets nothing.
- Coach eval: 5 canned questions over a fixture user. Each answer must cite numbers present in `facts_json` and contain no diagnostic language.

Sources: developers.google.com/health/webhooks, /health/migration/api-specifications, /health/app-verification, /health/release-notes
