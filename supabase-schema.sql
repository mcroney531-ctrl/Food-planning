-- Sunday Setup — food_* schema (Reading Center, fdbkdsracxomwyytfgob)
--
-- Tables and columns only. Safe to re-run: every statement is guarded, and
-- nothing here creates a policy or changes a grant.
--
-- ACCESS CONTROL IS NOT IN THIS FILE. It lives in db/food-owner-lockdown.sql
-- (applied to production 2026-11-22 as migration food_owner_lockdown): owner-
-- only RLS on every food_* table via a private allowlist, no anon access, no
-- deletes. See db/README.md.
--
-- Earlier versions of this file created open select/insert/update policies
-- for anon + authenticated. Those were removed on purpose: re-running them
-- against the secured database would have added permissive policies next to
-- the owner-only ones, and permissive policies are OR'ed — it would have
-- silently reopened every table. Don't add `to anon` policies back.
--
-- On a fresh database this file alone leaves every table with RLS on and no
-- policies, so it fails closed (nobody can read or write through the API)
-- until db/food-owner-lockdown.sql runs.
--
-- No delete anywhere: "removing" something flips an archived flag instead,
-- so the worst case stays a reversible edit.

-- ---------------------------------------------------------------------------
-- 0. Tables that predate this file. Recorded here from their production
--    migrations (create_food_taste_notes, food_taste_notes_add_archived,
--    create_food_log_items) so a fresh setup from this repo is complete.
-- ---------------------------------------------------------------------------
create table if not exists public.food_taste_notes (
  id         bigint generated always as identity primary key,
  note       text not null,
  source     text default 'manual',
  created_at timestamptz not null default now()
);
alter table public.food_taste_notes add column if not exists archived boolean not null default false;
alter table public.food_taste_notes enable row level security;

-- Food Log's saved items; Food-planning reads them as context and saves
-- recipes into them. Shared by both apps.
create table if not exists public.food_log_items (
  id         text primary key,
  title      text not null,
  category   text not null,
  image      text,
  recipe     text,
  calories   text,
  source_url text,
  created_at timestamptz not null default now(),
  archived   boolean not null default false
);
alter table public.food_log_items enable row level security;

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

-- Added later; safe to run on a table that already exists.
-- Favorite recipes — user-asserted, like avoid/prefer_not, but a positive
-- signal instead of a negative one: dishes already loved, plus why. This is
-- meant to weigh heavily on brainstorming (Discover, Your Dietitian) where a
-- favorite's flavors/format/texture are real material for new ideas — not on
-- weekly protein/combo scheduling, where a favorite dish often isn't a fit
-- for whatever protein is actually on hand that week.
alter table public.food_taste_profile
  add column if not exists favorites jsonb not null default '[]'::jsonb;  -- [{title, note}, ...]

-- ---------------------------------------------------------------------------
-- 5. food_dietitian_chat — SUPERSEDED, kept only because it holds real
--    history (10 messages) that was migrated forward, not dropped. Your
--    Dietitian moved from one singleton conversation to a real multi-
--    conversation sidebar (see food_dietitian_conversations, #7 below) —
--    nothing in the app reads or writes this table anymore.
-- ---------------------------------------------------------------------------
create table if not exists public.food_dietitian_chat (
  id         int primary key default 1 check (id = 1),
  messages   jsonb not null default '[]'::jsonb,  -- [{role:'user'|'assistant', text, ideas?}, ...]
  updated_at timestamptz not null default now()
);

alter table public.food_dietitian_chat enable row level security;




-- ---------------------------------------------------------------------------
-- 6. food_discover_feedback — thumbs up/down on Discover ideas.
--    Append-only signal log, not a piece of content anyone edits — no update
--    access, unlike every other food_ table. A thumbs-down also triggers an
--    immediate one-idea replacement client-side; this table is what lets that
--    preference actually carry forward into later batches instead of being
--    forgotten the moment the card is replaced.
-- ---------------------------------------------------------------------------
create table if not exists public.food_discover_feedback (
  id         bigint generated always as identity primary key,
  title      text not null,
  category   text not null,
  blurb      text,
  liked      boolean not null,
  created_at timestamptz not null default now()
);

alter table public.food_discover_feedback enable row level security;



-- ---------------------------------------------------------------------------
-- 7. food_dietitian_conversations — Your Dietitian, for real this time: a
--    sidebar of named, switchable conversations instead of one endless
--    thread. Replaces the food_dietitian_chat singleton (#5, superseded not
--    dropped — its 10 messages were migrated into a 'migrated_1' row here so
--    the actual history wasn't lost in the switch).
-- ---------------------------------------------------------------------------
create table if not exists public.food_dietitian_conversations (
  id         text primary key,                          -- client uid(), same format as food_log_items
  title      text not null default 'New conversation',  -- auto-set from the first message, user-renamable
  messages   jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived   boolean not null default false
);

alter table public.food_dietitian_conversations enable row level security;




-- ---------------------------------------------------------------------------
-- 8. food_log_items.source — distinguishes how a saved recipe got here.
--    'manual' (default) covers everything that predates this column: added
--    in Food Log, or saved from a Discover/Dietitian idea. 'social_video'
--    marks a recipe built by transcribing an uploaded TikTok/Reels/Shorts
--    mp4 — Saved Recipes groups those into their own "Social media recipes"
--    section instead of mixing them into the general list.
-- ---------------------------------------------------------------------------
alter table public.food_log_items add column if not exists source text not null default 'manual';

-- ---------------------------------------------------------------------------
-- 9. food_dietitian_conversations.grocery_list — the running ingredient list
--    a "let's go grocery shopping" conversation builds up alongside the chat
--    itself. A flat array of strings. Per-conversation by design, same as
--    messages — a fresh planning thread starts blank, an old one keeps
--    whatever it built.
-- ---------------------------------------------------------------------------
alter table public.food_dietitian_conversations
  add column if not exists grocery_list jsonb not null default '[]'::jsonb;

-- ---------------------------------------------------------------------------
-- 10. food_week_plans.meals / .meals_reset_at — "This week's meals," the
--     categorized meal list (Breakfast/Meals/Snacks/any custom category)
--     that Your Dietitian builds via chat. Unlike grocery_list this is NOT
--     per-conversation — it's one list for the whole week, shared across
--     every conversation, living on the same weekly row the rest of the
--     planner already uses. That's what gives it a free weekly archive:
--     each week gets its own row, so last week's picks just sit there
--     forever, readable the same way Past Weeks already reads day_plan.
--     meals_reset_at is a second, shorter clock on top of that — once 5
--     days pass since the list started getting built, it clears itself back
--     to blank (client-checked on load, this app has no server-side cron),
--     so stale mid-week brainstorming doesn't linger for the full 7 days.
--     Same struck-means-covered convention as everything else here.
-- ---------------------------------------------------------------------------
alter table public.food_week_plans
  add column if not exists meals jsonb not null default '[]'::jsonb,
  add column if not exists meals_reset_at timestamptz;
