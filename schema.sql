-- ============================================================
-- PRAXIS SCHEMA — Run this in Supabase SQL Editor
-- ============================================================

-- Enable UUID extension
create extension if not exists "pgcrypto";

-- ── CASES ────────────────────────────────────────────────────
create table if not exists cases (
  id           uuid primary key default gen_random_uuid(),
  slug         text unique not null,
  name         text not null,
  subtitle     text,
  difficulty   text,
  series       text,
  description  text,
  is_active    boolean default true,
  created_at   timestamptz default now()
);

-- ── SESSIONS ─────────────────────────────────────────────────
create table if not exists sessions (
  id             uuid primary key default gen_random_uuid(),
  code           text unique not null,
  case_id        uuid references cases(id),
  cohort_name    text not null,
  admin_email    text not null,
  current_round  int default 1,
  round_open     boolean default true,
  status         text default 'active',
  created_at     timestamptz default now(),
  expires_at     timestamptz
);

-- ── TEAMS ────────────────────────────────────────────────────
create table if not exists teams (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid references sessions(id) on delete cascade,
  slot          text not null,
  display_name  text not null,
  access_code   text not null,
  email         text,
  activated_at  timestamptz,
  expires_at    timestamptz,
  unique(session_id, slot)
);

-- ── DECISIONS ────────────────────────────────────────────────
create table if not exists decisions (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid references sessions(id) on delete cascade,
  team_id      uuid references teams(id) on delete cascade,
  round        int not null,
  domain_id    text not null,
  field_id     text not null,
  value        text,
  submitted_at timestamptz default now(),
  unique(session_id, team_id, round, field_id)
);

-- ── OUTCOMES ─────────────────────────────────────────────────
create table if not exists outcomes (
  id               uuid primary key default gen_random_uuid(),
  session_id       uuid references sessions(id) on delete cascade,
  team_id          uuid references teams(id) on delete cascade,
  round            int not null,
  revenue          numeric,
  gross_margin     numeric,
  cash_runway      numeric,
  market_share     numeric,
  product_health   numeric,
  team_capability  numeric,
  score            int,
  published_at     timestamptz default now(),
  unique(session_id, team_id, round)
);

-- ── CURVEBALLS ───────────────────────────────────────────────
create table if not exists curveballs (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid references sessions(id) on delete cascade,
  round        int not null,
  title        text not null,
  body         text not null,
  injected_at  timestamptz default now(),
  injected_by  text
);

-- ── SEED: DEFAULT CASES ──────────────────────────────────────
insert into cases (slug, name, subtitle, difficulty, series, description) values
  ('volta', 'VOLTA Motors', 'Navigating the Inflection', 'Complex', 'Series C',
   'Scale, survival, and the weight of decisions. VOLTA has 18 months to prove unit economics before an IPO conversation.'),
  ('arc', 'ARC Motors', 'The Velocity Trap', 'Intermediate', 'Series B',
   'A product 12 months from launch in a market that has shifted. Three competitors have already launched what you have not built.'),
  ('demo', 'ShopPulse', 'The Last Mile Problem', 'Introductory', 'Seed',
   'A quick-commerce startup facing a classic growth vs. margin dilemma. Built as a taster for first-time Praxis participants.')
on conflict (slug) do nothing;

-- ── ROW LEVEL SECURITY ───────────────────────────────────────
alter table cases      enable row level security;
alter table sessions   enable row level security;
alter table teams      enable row level security;
alter table decisions  enable row level security;
alter table outcomes   enable row level security;
alter table curveballs enable row level security;

-- Cases: anyone can read
create policy "cases_read" on cases for select using (true);

-- Sessions: read by code match, write open for session creation
create policy "sessions_read"   on sessions for select using (true);
create policy "sessions_insert" on sessions for insert with check (true);
create policy "sessions_update" on sessions for update using (true);

-- Teams: read/write scoped to valid session
create policy "teams_read"   on teams for select using (true);
create policy "teams_insert" on teams for insert with check (true);
create policy "teams_update" on teams for update using (true);

-- Decisions: read/write scoped to session
create policy "decisions_read"   on decisions for select using (true);
create policy "decisions_insert" on decisions for insert with check (true);
create policy "decisions_upsert" on decisions for update using (true);

-- Outcomes: read/write
create policy "outcomes_read"   on outcomes for select using (true);
create policy "outcomes_insert" on outcomes for insert with check (true);
create policy "outcomes_update" on outcomes for update using (true);

-- Curveballs: read/write
create policy "curveballs_read"   on curveballs for select using (true);
create policy "curveballs_insert" on curveballs for insert with check (true);

