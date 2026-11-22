-- Owner-only access for the food_* tables (Reading Center, fdbkdsracxomwyytfgob).
--
-- APPLIED to production 2026-11-22 03:28 UTC as migration
-- 20261122032835_food_owner_lockdown. The statements below are exactly what
-- ran; only this header has changed since. Idempotent: re-running it on the
-- secured database changes nothing (verified, see db/README.md).
--
-- Fresh project: run supabase-schema.sql first, create the owner's Auth user,
-- and put that user's id in the allowlist insert below (it references
-- auth.users, so a wrong or missing id fails loudly instead of locking
-- everyone out silently).
--
-- Rollback: db/food-owner-lockdown-rollback.sql (restores the pre-lockdown
-- open policies — emergency use only).
--
-- Model: one owner, kept in a private allowlist. Policies call
-- private.is_food_owner(), which reads the allowlist as its owner (postgres)
-- and takes identity only from the session's verified JWT (auth.uid()).
-- No owner columns; table shapes are unchanged.

-- 1. Private allowlist. Not in the Data API's exposed schemas (verify in
--    Settings > Data API > Exposed schemas: only public / graphql_public).
create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
grant usage on schema private to authenticated;          -- needed to call the function

create table if not exists private.food_owners (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table private.food_owners owner to postgres;
alter table private.food_owners enable row level security; -- no policies: only the owner (postgres) reads it
revoke all on private.food_owners from public, anon, authenticated;

insert into private.food_owners (user_id) values ('0ccc48c3-77e5-4b82-85b9-036e26cf4f53')
on conflict (user_id) do nothing;

-- 2. The ownership check. SECURITY DEFINER only so it can read the allowlist;
--    empty search_path, every name schema-qualified; no arguments, so callers
--    can't ask about anyone but themselves.
create or replace function private.is_food_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.food_owners
    where user_id = (select auth.uid())
  );
$$;
alter function private.is_food_owner() owner to postgres;
revoke all on function private.is_food_owner() from public, anon;   -- new functions default to PUBLIC execute
grant execute on function private.is_food_owner() to authenticated;

-- food_custom_combos: owner may select, insert, update; nobody may delete.
drop policy if exists food_custom_combos_select on public.food_custom_combos;
drop policy if exists food_custom_combos_insert on public.food_custom_combos;
drop policy if exists food_custom_combos_update on public.food_custom_combos;
drop policy if exists food_custom_combos_owner_select on public.food_custom_combos;
create policy food_custom_combos_owner_select on public.food_custom_combos for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_custom_combos_owner_insert on public.food_custom_combos;
create policy food_custom_combos_owner_insert on public.food_custom_combos for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_custom_combos_owner_update on public.food_custom_combos;
create policy food_custom_combos_owner_update on public.food_custom_combos for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_custom_combos from anon, authenticated;
grant select, insert, update on public.food_custom_combos to authenticated;

-- food_custom_items: owner may select, insert, update; nobody may delete.
drop policy if exists food_custom_items_select on public.food_custom_items;
drop policy if exists food_custom_items_insert on public.food_custom_items;
drop policy if exists food_custom_items_update on public.food_custom_items;
drop policy if exists food_custom_items_owner_select on public.food_custom_items;
create policy food_custom_items_owner_select on public.food_custom_items for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_custom_items_owner_insert on public.food_custom_items;
create policy food_custom_items_owner_insert on public.food_custom_items for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_custom_items_owner_update on public.food_custom_items;
create policy food_custom_items_owner_update on public.food_custom_items for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_custom_items from anon, authenticated;
grant select, insert, update on public.food_custom_items to authenticated;

-- food_dietitian_chat: owner may select, insert, update; nobody may delete.
drop policy if exists food_dietitian_chat_select on public.food_dietitian_chat;
drop policy if exists food_dietitian_chat_insert on public.food_dietitian_chat;
drop policy if exists food_dietitian_chat_update on public.food_dietitian_chat;
drop policy if exists food_dietitian_chat_owner_select on public.food_dietitian_chat;
create policy food_dietitian_chat_owner_select on public.food_dietitian_chat for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_dietitian_chat_owner_insert on public.food_dietitian_chat;
create policy food_dietitian_chat_owner_insert on public.food_dietitian_chat for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_dietitian_chat_owner_update on public.food_dietitian_chat;
create policy food_dietitian_chat_owner_update on public.food_dietitian_chat for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_dietitian_chat from anon, authenticated;
grant select, insert, update on public.food_dietitian_chat to authenticated;

-- food_dietitian_conversations: owner may select, insert, update; nobody may delete.
drop policy if exists food_dietitian_conversations_select on public.food_dietitian_conversations;
drop policy if exists food_dietitian_conversations_insert on public.food_dietitian_conversations;
drop policy if exists food_dietitian_conversations_update on public.food_dietitian_conversations;
drop policy if exists food_dietitian_conversations_owner_select on public.food_dietitian_conversations;
create policy food_dietitian_conversations_owner_select on public.food_dietitian_conversations for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_dietitian_conversations_owner_insert on public.food_dietitian_conversations;
create policy food_dietitian_conversations_owner_insert on public.food_dietitian_conversations for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_dietitian_conversations_owner_update on public.food_dietitian_conversations;
create policy food_dietitian_conversations_owner_update on public.food_dietitian_conversations for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_dietitian_conversations from anon, authenticated;
grant select, insert, update on public.food_dietitian_conversations to authenticated;

-- food_discover_feedback: owner may select, insert; nobody may delete.
drop policy if exists food_discover_feedback_select on public.food_discover_feedback;
drop policy if exists food_discover_feedback_insert on public.food_discover_feedback;
drop policy if exists food_discover_feedback_owner_select on public.food_discover_feedback;
create policy food_discover_feedback_owner_select on public.food_discover_feedback for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_discover_feedback_owner_insert on public.food_discover_feedback;
create policy food_discover_feedback_owner_insert on public.food_discover_feedback for insert to authenticated with check ((select private.is_food_owner()));
revoke all on public.food_discover_feedback from anon, authenticated;
grant select, insert on public.food_discover_feedback to authenticated;

-- food_log_items: owner may select, insert, update; nobody may delete.
drop policy if exists food_log_items_select on public.food_log_items;
drop policy if exists food_log_items_insert on public.food_log_items;
drop policy if exists food_log_items_update on public.food_log_items;
drop policy if exists food_log_items_owner_select on public.food_log_items;
create policy food_log_items_owner_select on public.food_log_items for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_log_items_owner_insert on public.food_log_items;
create policy food_log_items_owner_insert on public.food_log_items for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_log_items_owner_update on public.food_log_items;
create policy food_log_items_owner_update on public.food_log_items for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_log_items from anon, authenticated;
grant select, insert, update on public.food_log_items to authenticated;

-- food_taste_notes: owner may select, insert, update; nobody may delete.
drop policy if exists food_taste_notes_select on public.food_taste_notes;
drop policy if exists food_taste_notes_insert on public.food_taste_notes;
drop policy if exists food_taste_notes_update on public.food_taste_notes;
drop policy if exists food_taste_notes_owner_select on public.food_taste_notes;
create policy food_taste_notes_owner_select on public.food_taste_notes for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_taste_notes_owner_insert on public.food_taste_notes;
create policy food_taste_notes_owner_insert on public.food_taste_notes for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_taste_notes_owner_update on public.food_taste_notes;
create policy food_taste_notes_owner_update on public.food_taste_notes for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_taste_notes from anon, authenticated;
grant select, insert, update on public.food_taste_notes to authenticated;

-- food_taste_profile: owner may select, insert, update; nobody may delete.
drop policy if exists food_taste_profile_select on public.food_taste_profile;
drop policy if exists food_taste_profile_insert on public.food_taste_profile;
drop policy if exists food_taste_profile_update on public.food_taste_profile;
drop policy if exists food_taste_profile_owner_select on public.food_taste_profile;
create policy food_taste_profile_owner_select on public.food_taste_profile for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_taste_profile_owner_insert on public.food_taste_profile;
create policy food_taste_profile_owner_insert on public.food_taste_profile for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_taste_profile_owner_update on public.food_taste_profile;
create policy food_taste_profile_owner_update on public.food_taste_profile for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_taste_profile from anon, authenticated;
grant select, insert, update on public.food_taste_profile to authenticated;

-- food_week_plans: owner may select, insert, update; nobody may delete.
drop policy if exists food_week_plans_select on public.food_week_plans;
drop policy if exists food_week_plans_insert on public.food_week_plans;
drop policy if exists food_week_plans_update on public.food_week_plans;
drop policy if exists food_week_plans_owner_select on public.food_week_plans;
create policy food_week_plans_owner_select on public.food_week_plans for select to authenticated using ((select private.is_food_owner()));
drop policy if exists food_week_plans_owner_insert on public.food_week_plans;
create policy food_week_plans_owner_insert on public.food_week_plans for insert to authenticated with check ((select private.is_food_owner()));
drop policy if exists food_week_plans_owner_update on public.food_week_plans;
create policy food_week_plans_owner_update on public.food_week_plans for update to authenticated using ((select private.is_food_owner())) with check ((select private.is_food_owner()));
revoke all on public.food_week_plans from anon, authenticated;
grant select, insert, update on public.food_week_plans to authenticated;

-- Identity columns are GENERATED ALWAYS: inserts need no sequence privileges.
revoke all on sequence public.food_custom_combos_id_seq from anon, authenticated;
revoke all on sequence public.food_custom_items_id_seq from anon, authenticated;
revoke all on sequence public.food_discover_feedback_id_seq from anon, authenticated;
revoke all on sequence public.food_taste_notes_id_seq from anon, authenticated;
