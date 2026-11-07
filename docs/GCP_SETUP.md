# Google Cloud and Supabase setup checklist (manual, about 30 minutes)

These steps need your Google account, so they can't be scripted. Tick them off and paste the values into `.env` (see `.env.example`).

## Google Cloud Console
- [ ] Create project `health-companion-dev`. Write down both the **project ID** and the **project number**; webhook URLs use the number.
- [ ] APIs & Services → Library → enable **Google Health API**.
- [ ] Set up the OAuth consent screen (Google Auth Platform):
  - [ ] User type: External. Fill in the app name, support email and developer contact.
  - [ ] Data access: add the scopes `googlehealth.sleep.readonly`, `googlehealth.activity_and_fitness.readonly`, `googlehealth.health_metrics_and_measurements.readonly`, `googlehealth.profile.readonly`, plus `openid`, `email` and `profile`.
  - [ ] Audience: add both developers and the Fitbit Air owner as **test users**.
- [ ] Create these OAuth clients (Credentials → Create OAuth client ID):
  - [ ] **Web application** "supabase-auth": add the Supabase redirect URI `https://<project-ref>.supabase.co/auth/v1/callback`.
  - [ ] **Web application** "health-connect": add the redirect URI `https://<project-ref>.supabase.co/functions/v1/health-oauth-callback`.
  - [ ] **iOS**: bundle ID `com.healthcompanion.healthCompanion`.
  - [ ] **Android**: package `com.healthcompanion.health_companion` plus the SHA-1 of the debug keystore (`keytool -list -v -keystore ~/.android/debug.keystore -storepass android`).

## Supabase
- [ ] Create project `health-companion-dev` in an EU or US region near you. Write down the project ref, URL, publishable key and secret (service-role) key.
- [ ] Auth → Providers → Google: turn it on, enter the "supabase-auth" web client ID and secret, and add the iOS and Android client IDs under authorized client IDs (needed for native sign-in).
- [ ] Database → Extensions: confirm `pg_cron`, `pg_net` and `supabase_vault` are available.
- [ ] Link and push the schema:
  ```
  supabase link --project-ref <ref>
  supabase db push
  ```

## Anthropic
- [ ] Create an API key for the coach and store it only as a Supabase secret:
  ```
  supabase secrets set ANTHROPIC_API_KEY=...
  ```

## Week 1 check
- [ ] After the first real connection, check whether the refresh token still works 7 days later. If it doesn't, Testing mode is expiring tokens; see API_NOTES.md.
