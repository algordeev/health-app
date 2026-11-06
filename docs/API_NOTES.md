# Google Health API: working notes

Sources: https://developers.google.com/health (webhooks, migration/api-specifications, app-verification, release-notes). Checked 2026-11-06.

## Basics
- Base URL: `https://health.googleapis.com/v4`
- The legacy Fitbit Web API and Fitbit OAuth endpoints were turned off on 2026-11-02, so they can't be used.
- OAuth scopes use the format `https://www.googleapis.com/auth/googlehealth.<scope>`

| Scope we request | Covers |
|---|---|
| `sleep.readonly` | sleep |
| `activity_and_fitness.readonly` | steps, AZM, activity-level, calories, exercise |
| `health_metrics_and_measurements.readonly` | resting HR, HRV, SpO2 |
| `profile.readonly` | identity / profile |

## Data types → `daily_metrics` columns
| Google `dataType` | Read via | Our column(s) |
|---|---|---|
| `sleep` | list (session) | sleep_minutes, sleep_efficiency, deep/rem/light/awake_min, bedtime, wake_time |
| `steps` | dailyRollUp | steps |
| `active-zone-minutes` | dailyRollUp | active_zone_min |
| `activity-level` | dailyRollUp | active_min (moderately + very active) |
| `total-calories` | dailyRollUp | total_calories |
| `daily-resting-heart-rate` | list / dailyRollUp | resting_hr |
| `daily-heart-rate-variability` | list / dailyRollUp | hrv_ms |
| `daily-oxygen-saturation` | list / dailyRollUp | spo2_avg |
| `exercise` | list (session) | exercise_count (used for the run bonus) |

To read one day's summary: `POST /v4/users/me/dataTypes/<type>/dataPoints:dailyRollUp` with `windowSizeDays: 1`.
⚠️ Confirm the exact request and response shapes in week 1 against a real account, and save fixtures to `supabase/functions/_shared/fixtures/`.

Some types depend on the device. The Fitbit Air may not report SpO2 or HRV, so the UI hides cards that have no data.

## Webhooks
- Create a subscriber once per GCP project:
  ```
  POST /v4/projects/{PROJECT_NUMBER}/subscribers?subscriberId=health-companion-dev
  ```
  - Use the project **number**, not the project ID.
  - The body has `endpointUri`, `subscriberConfigs` (one per data type, with policy `AUTOMATIC`) and `endpointAuthorization` (our secret).
  - PATCH replaces `subscriberConfigs` completely; it doesn't merge.
- **Endpoint verification:** Google sends two POSTs with the body `{"type":"verification"}`.
  1. The first carries our Authorization header. We must answer 200 or 201.
  2. The second has no credentials. We must answer 401 or 403.
- **Notifications:**
  - They arrive as a JSON array of up to 99 items.
  - Each item has `healthUserId`, `dataType`, `operation` (UPSERT/DELETE) and `intervals` (civil dates).
  - They carry **no values**: we enqueue a job, then fetch the data ourselves.
  - The user-deleted and user-revoked events mean we mark the connection as revoked.
- **Signature:** the `GOOGLE-HEALTH-API-SIGNATURE` header is ECDSA P-256 / SHA-256 in Tink format. The public keyset is at `https://www.gstatic.com/googlehealthapi/webhooks/webhooks_public_keyset.json`. Keys rotate every 30 days, so cache the keyset for a short time.
- **Responses and retries:** reply **204 immediately**. Any other response causes retries with backoff for up to 7 days, so duplicates happen. Our partial unique index on `sync_queue` collapses them.

## Verification and limits
- Most Google Health scopes are **restricted**. An unverified app is limited to 100 users, which is enough for the demo.
- Full verification needs a CASA security assessment ($500–4,500, 2–6 weeks). Out of scope for now.
- ⚠️ When the OAuth consent screen is in "Testing" status, refresh tokens expire after about 7 days. Check this in week 1. Before onboarding the 5 testers, either switch the app to "In production" (unverified, testers see a warning screen) or plan weekly re-consent.
- The app must show an in-app disclosure of health data use before consent. A privacy policy alone isn't enough.
