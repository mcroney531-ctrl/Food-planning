-- Sunday Setup — schema additions
-- Run in the Supabase SQL editor for project "Reading Center" (fdbkdsracxomwyytfgob).
-- Safe to re-run: every statement is guarded.
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
