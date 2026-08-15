-- Sunday Setup — schema additions
--
-- APPLIED. Live on project "Reading Center" (fdbkdsracxomwyytfgob) as migration
-- sunday_setup_week_plans_and_taste_profile. Kept here as the source of record;
-- safe to re-run, since every statement is guarded.
--
-- Follows the existing food_ conventions: open select/insert/update for
-- anon + authenticated, and no delete policy anywhere — "removing" something
-- flips a flag instead, so the worst case stays a reversible edit.

-- ---------------------------------------------------------------------------
-- 1. food_week_plans — one row per week, so a plan survives closing the app
--    and so past weeks accumulate into history worth reasoning about.
-- ---------------------------------------------------------------------------
create table if not exists public.food_week_plans (
  week_start  date primary key,              -- the Sunday that week belongs to
  proteins    jsonb       not null default '[]'::jsonb,
  combos      jsonb       not null default '{}'::jsonb,   -- { proteinId: [combo, ...] }
  breakfasts  jsonb       not null default '[]'::jsonb,
  stocked     jsonb       not null default '[]'::jsonb,
  day_plan    jsonb       not null default '{}'::jsonb,   -- { "MON": combo, ... } (used later)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Added later; safe to run on a table that already exists.
alter table public.food_week_plans
  add column if not exists grocery jsonb not null default '{}'::jsonb;

-- Added later; safe to run on a table that already exists.
-- Per-day outcome ratings — { "MON": "up"|"down", ... }. This is the ground
-- truth the taste profile was missing: a day showing up in day_plan only ever
-- meant "assigned," never "liked." Rated meals are the strongest signal
-- profileSignals() feeds into profile-building, ahead of notes or saves.
alter table public.food_week_plans
  add column if not exists ratings jsonb not null default '{}'::jsonb;

alter table public.food_week_plans enable row level security;

do $$ begin
  create policy food_week_plans_select on public.food_week_plans
    for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_week_plans_insert on public.food_week_plans
    for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_week_plans_update on public.food_week_plans
    for update to anon, authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 2. food_custom_combos — swap ideas accepted from a Claude chat.
--    These are durable across weeks, which is why they don't live in the
--    week row: an idea you liked in March should still be there in June.
-- ---------------------------------------------------------------------------
create table if not exists public.food_custom_combos (
  id          bigint generated always as identity primary key,
  protein_id  text        not null,
  combo       text        not null,
  source      text        not null default 'claude',
  created_at  timestamptz not null default now(),
  archived    boolean     not null default false,
  unique (protein_id, combo)
);

alter table public.food_custom_combos enable row level security;

do $$ begin
  create policy food_custom_combos_select on public.food_custom_combos
    for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_custom_combos_insert on public.food_custom_combos
    for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_custom_combos_update on public.food_custom_combos
    for update to anon, authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 3. food_custom_items — proteins, breakfasts, and pantry staples you add
--    yourself. These lists were hardcoded in the page, so changing them meant
--    editing HTML and redeploying.
-- ---------------------------------------------------------------------------
create table if not exists public.food_custom_items (
  id          bigint generated always as identity primary key,
  kind        text        not null check (kind in ('protein','breakfast','stock')),
  name        text        not null,
  freezer     boolean     not null default false,   -- proteins only
  created_at  timestamptz not null default now(),
  archived    boolean     not null default false,
  unique (kind, name)
);

alter table public.food_custom_items enable row level security;

do $$ begin
  create policy food_custom_items_select on public.food_custom_items
    for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_custom_items_insert on public.food_custom_items
    for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_custom_items_update on public.food_custom_items
    for update to anon, authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 4. food_taste_profile — the abstraction layer over taste notes.
--    Notes are instances ("liked that Cajun shrimp pasta"); this is the axes
--    underneath them (cuisine: Cajun, format: pasta, flavor: heat + butter).
--    "He likes X so maybe Y" needs the axes, not the instances.
--    Single row by design — one person, one profile.
-- ---------------------------------------------------------------------------
create table if not exists public.food_taste_profile (
  id           int primary key default 1 check (id = 1),
  axes         jsonb       not null default '{}'::jsonb,  -- {flavors:[],cuisines:[],formats:[],textures:[]}
  effort       jsonb       not null default '{}'::jsonb,  -- {weeknight_minutes:int, notes:text}
  sensibility  text,                                      -- the nuance tags can't hold
  source_stamp jsonb       not null default '{}'::jsonb,  -- what it was last built from
  updated_at   timestamptz not null default now()
);

alter table public.food_taste_profile enable row level security;

do $$ begin
  create policy food_taste_profile_select on public.food_taste_profile
    for select to anon, authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_taste_profile_insert on public.food_taste_profile
    for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy food_taste_profile_update on public.food_taste_profile
    for update to anon, authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;

-- Added later; safe to run on a table that already exists.
-- Explicit dislikes — user-asserted only, never model-inferred, so a weak
-- positive signal (e.g. a combo tapped once but never actually cooked) can't
-- get contradicted by a false "you like this" reaching the profile axes.
alter table public.food_taste_profile
  add column if not exists avoid jsonb not null default '[]'::jsonb;

-- Added later; safe to run on a table that already exists.
-- Soft dislikes — same user-asserted-only posture as avoid, but deprioritize
-- rather than hard-exclude. Client-side pool filtering (Surprise Me, etc.)
-- only ever applies to `avoid`; `prefer_not` is prompt-only signal.
--
-- Note: this migration predates a client-side reshape of `axes` — each tag
-- moved from a plain string to {tag, reason}, so the model's inference is
-- inspectable (tap a tag in the UI to see why it's there). That reshape
-- lives entirely inside the existing `axes` jsonb column, no migration
-- needed for it. Same story for `effort`, which gained `equipment` and
-- `avoid_methods` keys — already flexible jsonb, nothing to alter.
alter table public.food_taste_profile
  add column if not exists prefer_not jsonb not null default '[]'::jsonb;
