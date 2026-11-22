-- ROLLBACK for db/food-owner-lockdown.sql: restores the exact pre-lockdown
-- policies and grants on the food_* tables, captured from the catalog on
-- 2026-11-22, and removes the private allowlist and function.
-- This reopens anonymous read/write access. Emergency use only.

drop policy if exists food_custom_combos_owner_select on public.food_custom_combos;
drop policy if exists food_custom_combos_owner_insert on public.food_custom_combos;
drop policy if exists food_custom_combos_owner_update on public.food_custom_combos;
drop policy if exists food_custom_items_owner_select on public.food_custom_items;
drop policy if exists food_custom_items_owner_insert on public.food_custom_items;
drop policy if exists food_custom_items_owner_update on public.food_custom_items;
drop policy if exists food_dietitian_chat_owner_select on public.food_dietitian_chat;
drop policy if exists food_dietitian_chat_owner_insert on public.food_dietitian_chat;
drop policy if exists food_dietitian_chat_owner_update on public.food_dietitian_chat;
drop policy if exists food_dietitian_conversations_owner_select on public.food_dietitian_conversations;
drop policy if exists food_dietitian_conversations_owner_insert on public.food_dietitian_conversations;
drop policy if exists food_dietitian_conversations_owner_update on public.food_dietitian_conversations;
drop policy if exists food_discover_feedback_owner_select on public.food_discover_feedback;
drop policy if exists food_discover_feedback_owner_insert on public.food_discover_feedback;
drop policy if exists food_log_items_owner_select on public.food_log_items;
drop policy if exists food_log_items_owner_insert on public.food_log_items;
drop policy if exists food_log_items_owner_update on public.food_log_items;
drop policy if exists food_taste_notes_owner_select on public.food_taste_notes;
drop policy if exists food_taste_notes_owner_insert on public.food_taste_notes;
drop policy if exists food_taste_notes_owner_update on public.food_taste_notes;
drop policy if exists food_taste_profile_owner_select on public.food_taste_profile;
drop policy if exists food_taste_profile_owner_insert on public.food_taste_profile;
drop policy if exists food_taste_profile_owner_update on public.food_taste_profile;
drop policy if exists food_week_plans_owner_select on public.food_week_plans;
drop policy if exists food_week_plans_owner_insert on public.food_week_plans;
drop policy if exists food_week_plans_owner_update on public.food_week_plans;

create policy food_custom_combos_insert on public.food_custom_combos as permissive for insert to anon, authenticated with check (true);
create policy food_custom_combos_select on public.food_custom_combos as permissive for select to anon, authenticated using (true);
create policy food_custom_combos_update on public.food_custom_combos as permissive for update to anon, authenticated using (true) with check (true);
create policy food_custom_items_insert on public.food_custom_items as permissive for insert to anon, authenticated with check (true);
create policy food_custom_items_select on public.food_custom_items as permissive for select to anon, authenticated using (true);
create policy food_custom_items_update on public.food_custom_items as permissive for update to anon, authenticated using (true) with check (true);
create policy food_dietitian_chat_insert on public.food_dietitian_chat as permissive for insert to anon, authenticated with check (true);
create policy food_dietitian_chat_select on public.food_dietitian_chat as permissive for select to anon, authenticated using (true);
create policy food_dietitian_chat_update on public.food_dietitian_chat as permissive for update to anon, authenticated using (true) with check (true);
create policy food_dietitian_conversations_insert on public.food_dietitian_conversations as permissive for insert to anon, authenticated with check (true);
create policy food_dietitian_conversations_select on public.food_dietitian_conversations as permissive for select to anon, authenticated using (true);
create policy food_dietitian_conversations_update on public.food_dietitian_conversations as permissive for update to anon, authenticated using (true) with check (true);
create policy food_discover_feedback_insert on public.food_discover_feedback as permissive for insert to anon, authenticated with check (true);
create policy food_discover_feedback_select on public.food_discover_feedback as permissive for select to anon, authenticated using (true);
create policy food_log_items_insert on public.food_log_items as permissive for insert to anon, authenticated with check (true);
create policy food_log_items_select on public.food_log_items as permissive for select to anon, authenticated using (true);
create policy food_log_items_update on public.food_log_items as permissive for update to anon, authenticated using (true) with check (true);
create policy food_taste_notes_insert on public.food_taste_notes as permissive for insert to anon, authenticated with check (true);
create policy food_taste_notes_select on public.food_taste_notes as permissive for select to anon, authenticated using (true);
create policy food_taste_notes_update on public.food_taste_notes as permissive for update to anon, authenticated using (true);
create policy food_taste_profile_insert on public.food_taste_profile as permissive for insert to anon, authenticated with check (true);
create policy food_taste_profile_select on public.food_taste_profile as permissive for select to anon, authenticated using (true);
create policy food_taste_profile_update on public.food_taste_profile as permissive for update to anon, authenticated using (true) with check (true);
create policy food_week_plans_insert on public.food_week_plans as permissive for insert to anon, authenticated with check (true);
create policy food_week_plans_select on public.food_week_plans as permissive for select to anon, authenticated using (true);
create policy food_week_plans_update on public.food_week_plans as permissive for update to anon, authenticated using (true) with check (true);

grant delete, insert, references, select, trigger, truncate, update on public.food_custom_combos to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_custom_items to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_dietitian_chat to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_dietitian_conversations to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_discover_feedback to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_log_items to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_taste_notes to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_taste_profile to anon, authenticated;
grant delete, insert, references, select, trigger, truncate, update on public.food_week_plans to anon, authenticated;
grant select, update, usage on sequence public.food_custom_combos_id_seq to anon, authenticated;
grant select, update, usage on sequence public.food_custom_items_id_seq to anon, authenticated;
grant select, update, usage on sequence public.food_discover_feedback_id_seq to anon, authenticated;
grant select, update, usage on sequence public.food_taste_notes_id_seq to anon, authenticated;

drop function if exists private.is_food_owner();
drop table if exists private.food_owners;
drop schema if exists private;   -- fails safely (not cascade) if anything else lives there
