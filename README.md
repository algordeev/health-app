# Wearable Health Companion

A better companion app for the Fitbit Air. It shows a daily summary, trends, an AI coach and a game layer (a character, points, streaks and friend challenges), built on the official Google Health API.

- **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Google Health API notes:** [docs/API_NOTES.md](docs/API_NOTES.md)
- **One-time setup:** [docs/GCP_SETUP.md](docs/GCP_SETUP.md)

## Layout
```
app/        Flutter app (iOS + Android)
supabase/   Postgres migrations + Edge Functions (Deno/TypeScript)
docs/       Architecture, API notes, demo script
```

## Prerequisites
```
brew install --cask flutter
brew install supabase/tap/supabase deno
```
