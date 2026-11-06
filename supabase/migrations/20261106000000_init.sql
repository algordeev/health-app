-- Wearable Health Companion: initial schema
-- Principles (see docs/ARCHITECTURE.md):
--   * Daily aggregates only, never raw intraday streams.
--   * RLS on every table. Health data and game state are written only by the
--     service role (Edge Functions) or by narrow SECURITY DEFINER RPCs.
--   * Friends see game fields only, via get_friend_board(), never daily_metrics.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
-- supabase_vault is enabled by default on Supabase projects; refresh tokens live there.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Profiles & consent
-- ---------------------------------------------------------------------------
create table public.profiles (
  user_id            uuid primary key references auth.users on delete cascade,
  display_name       text check (char_length(display_name) <= 40),
  timezone           text not null default 'UTC',
  health_consent_at  timestamptz,
  coach_consent_at   timestamptz,
  sharing_consent_at timestamptz,          -- opt-in to appear on friends' boards
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.consent_events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users on delete cascade,
  kind       text not null check (kind in ('health_data','ai_coach','friend_sharing')),
  granted    boolean not null,
  at         timestamptz not null default now()
);
create index on public.consent_events (user_id, at desc);

-- Keep profiles.*_consent_at in sync with the consent log.
create or replace function public.apply_consent_event()
returns trigger language plpgsql security definer set search_path = '' as $$
declare ts timestamptz := case when new.granted then new.at else null end;
begin
  update public.profiles set
    health_consent_at  = case when new.kind = 'health_data'    then ts else health_consent_at  end,
    coach_consent_at   = case when new.kind = 'ai_coach'       then ts else coach_consent_at   end,
    sharing_consent_at = case when new.kind = 'friend_sharing' then ts else sharing_consent_at end
  where user_id = new.user_id;
  return new;
end $$;
create trigger consent_events_apply after insert on public.consent_events
  for each row execute function public.apply_consent_event();

-- ---------------------------------------------------------------------------
-- Google Health connection (tokens are in Vault; only the secret id is here)
-- ---------------------------------------------------------------------------
create table public.health_connections (
  user_id                 uuid primary key references auth.users on delete cascade,
  health_user_id          text not null unique,
  refresh_token_secret_id uuid not null,   -- vault.secrets.id
  scopes                  text[] not null default '{}',
  status                  text not null default 'active'
                          check (status in ('active','revoked','error')),
  last_error              text,
  connected_at            timestamptz not null default now(),
  last_synced_at          timestamptz,
  updated_at              timestamptz not null default now()
);
create trigger health_connections_updated_at before update on public.health_connections
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Daily aggregates (one row per user per local civil date)
-- ---------------------------------------------------------------------------
create table public.daily_metrics (
  user_id          uuid not null references auth.users on delete cascade,
  date             date not null,
  -- sleep (attributed to the date the user woke up)
  sleep_minutes    int,
  sleep_efficiency numeric(5,2),
  deep_min         int,
  rem_min          int,
  light_min        int,
  awake_min        int,
  bedtime          timestamptz,
  wake_time        timestamptz,
  -- heart
  resting_hr       numeric(5,1),
  hrv_ms           numeric(6,1),
  spo2_avg         numeric(4,1),
  -- activity
  steps            int,
  active_zone_min  int,
  active_min       int,
  total_calories   int,
  exercise_count   int,
  source_updated_at timestamptz,
  updated_at       timestamptz not null default now(),
  primary key (user_id, date)
);
create trigger daily_metrics_updated_at before update on public.daily_metrics
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Sync queue (webhook + nightly reconcile + "Sync now" all enqueue here)
-- ---------------------------------------------------------------------------
create table public.sync_queue (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users on delete cascade,
  data_type   text not null,          -- Google Health dataType, e.g. 'sleep', 'steps'
  date        date not null,
  status      text not null default 'pending'
              check (status in ('pending','running','done','failed')),
  attempts    int not null default 0,
  run_after   timestamptz not null default now(),
  last_error  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
-- Idempotency: duplicate webhook deliveries collapse into one pending job.
create unique index sync_queue_pending_uniq
  on public.sync_queue (user_id, data_type, date) where status = 'pending';
create index sync_queue_claim_idx on public.sync_queue (run_after) where status = 'pending';
create trigger sync_queue_updated_at before update on public.sync_queue
  for each row execute function public.set_updated_at();

-- Worker claims a batch atomically (service role only).
create or replace function public.claim_sync_jobs(batch_size int default 25)
returns setof public.sync_queue language sql security definer set search_path = '' as $$
  update public.sync_queue q
     set status = 'running', attempts = q.attempts + 1
   where q.id in (
     select id from public.sync_queue
      where status = 'pending' and run_after <= now()
      order by run_after
      limit batch_size
      for update skip locked)
  returning q.*;
$$;

-- "Sync now" from the app: enqueue the user's own recent dates.
create or replace function public.request_sync(days_back int default 1)
returns int language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  tz  text;
  n   int;
begin
  if uid is null then raise exception 'not authenticated'; end if;
  if not exists (select 1 from public.health_connections
                  where user_id = uid and status = 'active') then
    raise exception 'google health not connected';
  end if;
  select timezone into tz from public.profiles where user_id = uid;
  insert into public.sync_queue (user_id, data_type, date)
  select uid, t.data_type, d::date
    from unnest(array['sleep','steps','daily-resting-heart-rate',
                      'daily-heart-rate-variability','active-zone-minutes',
                      'activity-level','total-calories','daily-oxygen-saturation',
                      'exercise']) as t(data_type),
         generate_series((now() at time zone coalesce(tz,'UTC'))::date - least(greatest(days_back,0),7),
                         (now() at time zone coalesce(tz,'UTC'))::date, interval '1 day') as d
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- AI coach
-- ---------------------------------------------------------------------------
create table public.weekly_insights (
  user_id     uuid not null references auth.users on delete cascade,
  week_start  date not null,
  summary_md  text not null,
  facts_json  jsonb not null default '{}',
  model       text not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, week_start)
);

create table public.coach_messages (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users on delete cascade,
  thread_id   uuid not null,
  role        text not null check (role in ('user','assistant')),
  content     text not null,
  facts_json  jsonb,                  -- tool results the answer relied on
  created_at  timestamptz not null default now()
);
create index on public.coach_messages (user_id, thread_id, created_at);

-- Demo Day target (b): "does this match the official app?"
create table public.summary_feedback (
  user_id          uuid not null references auth.users on delete cascade,
  date             date not null,
  matches_official boolean not null,
  note             text check (char_length(note) <= 500),
  created_at       timestamptz not null default now(),
  primary key (user_id, date)
);

-- ---------------------------------------------------------------------------
-- Game layer
-- ---------------------------------------------------------------------------
create table public.characters (
  user_id     uuid primary key references auth.users on delete cascade,
  name        text not null default 'Pip' check (char_length(name) between 1 and 20),
  avatar_key  text not null default 'default',
  level       int not null default 1,
  xp          int not null default 0,
  mood        text not null default 'content'
              check (mood in ('energized','content','sleepy','sluggish','proud')),
  mood_reason text,
  updated_at  timestamptz not null default now()
);
create trigger characters_updated_at before update on public.characters
  for each row execute function public.set_updated_at();

-- Ledger: the scoring engine deletes and rewrites a (user, date) slice, so recomputing is idempotent.
create table public.point_events (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users on delete cascade,
  date         date not null,
  source       text not null check (source in ('sleep','activity','recovery','task','streak','challenge')),
  rule_id      text not null,
  rule_version int  not null,
  points       int  not null,
  meta         jsonb not null default '{}',
  created_at   timestamptz not null default now(),
  unique (user_id, date, source, rule_id)
);
create index on public.point_events (user_id, date);

create table public.streaks (
  user_id      uuid not null references auth.users on delete cascade,
  kind         text not null check (kind in ('sleep_window','step_goal','any_goal')),
  current      int not null default 0,
  best         int not null default 0,
  last_date    date,
  freezes_left int not null default 1,
  primary key (user_id, kind)
);

create table public.tasks (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users on delete cascade,
  title       text not null check (char_length(title) <= 80),
  metric      text not null,          -- daily_metrics column, e.g. 'steps', 'bedtime'
  comparator  text not null check (comparator in ('gte','lte')),
  target      numeric not null,
  period      text not null check (period in ('daily','weekly')),
  origin      text not null check (origin in ('user','coach')),
  status      text not null default 'active'
              check (status in ('suggested','active','completed','expired','cancelled')),
  due_date    date,
  created_at  timestamptz not null default now()
);
create index on public.tasks (user_id, status);

-- Friendships are stored once per pair, with user_a < user_b.
create table public.friendships (
  user_a       uuid not null references auth.users on delete cascade,
  user_b       uuid not null references auth.users on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);

create table public.friend_invites (
  code        text primary key default encode(extensions.gen_random_bytes(6), 'hex'),
  inviter_id  uuid not null references auth.users on delete cascade,
  expires_at  timestamptz not null default now() + interval '7 days',
  used_by     uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);

create table public.challenges (
  id          bigint generated always as identity primary key,
  creator_id  uuid not null references auth.users on delete cascade,
  title       text not null check (char_length(title) <= 60),
  type        text not null check (type in ('competitive','coop')),
  metric      text not null,          -- 'points' | 'steps' | 'active_zone_min' | 'sleep_window'
  target      numeric,                -- required for coop
  starts_at   date not null,
  ends_at     date not null,
  created_at  timestamptz not null default now(),
  check (ends_at >= starts_at and ends_at - starts_at <= 31)
);

create table public.challenge_members (
  challenge_id bigint not null references public.challenges on delete cascade,
  user_id      uuid not null references auth.users on delete cascade,
  progress     numeric not null default 0,   -- written by scoring engine
  joined_at    timestamptz not null default now(),
  primary key (challenge_id, user_id)
);

create table public.team_streaks (
  user_a     uuid not null references auth.users on delete cascade,
  user_b     uuid not null references auth.users on delete cascade,
  current    int not null default 0,
  best       int not null default 0,
  last_date  date,
  primary key (user_a, user_b),
  check (user_a < user_b)
);

-- ---------------------------------------------------------------------------
-- New user bootstrap
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, display_name)
  values (new.id, left(coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)), 40));
  insert into public.characters (user_id) values (new.id);
  insert into public.streaks (user_id, kind)
  values (new.id,'sleep_window'), (new.id,'step_goal'), (new.id,'any_goal');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Friend helpers & RPCs
-- ---------------------------------------------------------------------------
create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friendships
                  where user_a = least(a,b) and user_b = greatest(a,b));
$$;

create or replace function public.create_friend_invite()
returns text language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into public.friend_invites (inviter_id) values (auth.uid()) returning code into c;
  return c;
end $$;

create or replace function public.accept_friend_invite(invite_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare inv public.friend_invites;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into inv from public.friend_invites
   where code = invite_code and used_by is null and expires_at > now()
   for update;
  if not found then raise exception 'invalid or expired invite'; end if;
  if inv.inviter_id = auth.uid() then raise exception 'cannot befriend yourself'; end if;
  insert into public.friendships (user_a, user_b)
  values (least(inv.inviter_id, auth.uid()), greatest(inv.inviter_id, auth.uid()))
  on conflict do nothing;
  update public.friend_invites set used_by = auth.uid() where code = invite_code;
  return inv.inviter_id;
end $$;

create or replace function public.remove_friend(friend_id uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.friendships
   where user_a = least(auth.uid(), friend_id) and user_b = greatest(auth.uid(), friend_id);
$$;

create or replace function public.set_character(new_name text, new_avatar_key text)
returns void language sql security definer set search_path = '' as $$
  update public.characters set name = new_name, avatar_key = new_avatar_key
   where user_id = auth.uid();
$$;

create or replace function public.accept_suggested_task(task_id bigint)
returns void language sql security definer set search_path = '' as $$
  update public.tasks set status = 'active'
   where id = task_id and user_id = auth.uid() and status = 'suggested';
$$;

create or replace function public.join_challenge(cid bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare creator uuid;
begin
  select creator_id into creator from public.challenges where id = cid and ends_at >= current_date;
  if creator is null then raise exception 'challenge not found or ended'; end if;
  if creator <> auth.uid() and not public.are_friends(creator, auth.uid()) then
    raise exception 'only friends of the creator can join';
  end if;
  insert into public.challenge_members (challenge_id, user_id) values (cid, auth.uid())
  on conflict do nothing;
end $$;

-- Friends leaderboard: game fields only, and only for friends who opted in to sharing.
create or replace function public.get_friend_board()
returns table (
  user_id uuid, display_name text, character_name text, avatar_key text,
  level int, xp int, mood text, points_today int, points_week int, best_streak int,
  is_me boolean
) language sql stable security definer set search_path = '' as $$
  with people as (
    select auth.uid() as uid
    union
    select case when f.user_a = auth.uid() then f.user_b else f.user_a end
      from public.friendships f
     where auth.uid() in (f.user_a, f.user_b)
  )
  select p.user_id, p.display_name, c.name, c.avatar_key, c.level, c.xp, c.mood,
         coalesce((select sum(pe.points) from public.point_events pe
                    where pe.user_id = p.user_id
                      and pe.date = (now() at time zone p.timezone)::date), 0)::int,
         coalesce((select sum(pe.points) from public.point_events pe
                    where pe.user_id = p.user_id
                      and pe.date >= date_trunc('week', now() at time zone p.timezone)::date), 0)::int,
         coalesce((select max(s.current) from public.streaks s where s.user_id = p.user_id), 0),
         p.user_id = auth.uid()
    from people x
    join public.profiles p on p.user_id = x.uid
    join public.characters c on c.user_id = p.user_id
   where auth.uid() is not null
     and (p.user_id = auth.uid() or p.sharing_consent_at is not null)
   order by 9 desc;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles           enable row level security;
alter table public.consent_events     enable row level security;
alter table public.health_connections enable row level security;
alter table public.daily_metrics      enable row level security;
alter table public.sync_queue         enable row level security;
alter table public.weekly_insights    enable row level security;
alter table public.coach_messages     enable row level security;
alter table public.summary_feedback   enable row level security;
alter table public.characters         enable row level security;
alter table public.point_events       enable row level security;
alter table public.streaks            enable row level security;
alter table public.tasks              enable row level security;
alter table public.friendships        enable row level security;
alter table public.friend_invites     enable row level security;
alter table public.challenges         enable row level security;
alter table public.challenge_members  enable row level security;
alter table public.team_streaks       enable row level security;
-- sync_queue: no policies at all, so it's service-role only.

-- Own-row read access
create policy own_select on public.profiles           for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.consent_events     for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.health_connections for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.daily_metrics      for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.weekly_insights    for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.coach_messages     for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.summary_feedback   for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.characters         for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.point_events       for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.streaks            for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.tasks              for select to authenticated using (user_id = (select auth.uid()));
create policy own_select on public.friend_invites     for select to authenticated using (inviter_id = (select auth.uid()));

-- Narrow client writes
create policy own_update on public.profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- Consent timestamps can be changed only through consent_events.
revoke update on public.profiles from authenticated;
grant update (display_name, timezone) on public.profiles to authenticated;

create policy own_insert on public.consent_events for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy own_upsert on public.summary_feedback for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy own_update on public.summary_feedback for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- User-created tasks only. Completion is decided server-side by the scoring engine.
create policy own_insert on public.tasks for insert to authenticated
  with check (user_id = (select auth.uid()) and origin = 'user' and status = 'active');
create policy own_delete on public.tasks for delete to authenticated
  using (user_id = (select auth.uid()));

-- Friendships & team streaks: visible to either side.
create policy pair_select on public.friendships for select to authenticated
  using ((select auth.uid()) in (user_a, user_b));
create policy pair_select on public.team_streaks for select to authenticated
  using ((select auth.uid()) in (user_a, user_b));

-- Challenges: visible to creator and members, created by self.
-- The membership check bypasses RLS via SECURITY DEFINER; a policy that queries its own table recurses forever.
create or replace function public.is_challenge_member(cid bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.challenge_members
                  where challenge_id = cid and user_id = auth.uid());
$$;

create policy member_select on public.challenges for select to authenticated
  using (creator_id = (select auth.uid()) or public.is_challenge_member(challenges.id));
create policy own_insert on public.challenges for insert to authenticated
  with check (creator_id = (select auth.uid()));
create policy member_select on public.challenge_members for select to authenticated
  using (public.is_challenge_member(challenge_members.challenge_id));
create policy own_leave on public.challenge_members for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Function privileges: RPCs are for signed-in users. Worker helpers are service-role only.
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.request_sync(int),
  public.create_friend_invite(),
  public.accept_friend_invite(text),
  public.remove_friend(uuid),
  public.set_character(text, text),
  public.accept_suggested_task(bigint),
  public.join_challenge(bigint),
  public.get_friend_board(),
  public.is_challenge_member(bigint)
to authenticated;
revoke execute on function public.claim_sync_jobs(int) from authenticated;
revoke execute on function public.are_friends(uuid, uuid) from authenticated;
