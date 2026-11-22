-- Pre-lockdown test for db/food-owner-lockdown.sql (Reading Center).
--
-- Runs ENTIRELY inside one transaction that ends in ROLLBACK: nothing persists.
-- 1. snapshot today's food_* policies/grants
-- 2. create the Daily Brief reader role, then apply the full owner-only lockdown
-- 3. replay both apps' real queries and writes as owner, non-owner and anon
--    (each probe in its own sub-transaction, undone immediately)
-- 4. check effective privileges, the function/allowlist contract, and tampering
-- 5. apply the rollback scripts and verify the state matches the snapshot exactly
-- Takes brief locks on the food_* tables while it runs (a second or two).
-- Claims are simulated with request.jwt.claims; the real-JWT checks happen
-- with live sessions after cutover.
begin;

create temp table _res (ord serial, label text, expect text, outcome text, pass boolean);
grant all on _res to public;
grant all on sequence _res_ord_seq to public;
create function pg_temp.food_state() returns setof text language sql as $s$
  select 'policy '||c.relname||' '||p.polname||' '||p.polcmd::text||' '||(select string_agg(rolname, ',' order by rolname) from pg_roles where oid = any(p.polroles))||' q='||coalesce(pg_get_expr(p.polqual, p.polrelid),'-')||' c='||coalesce(pg_get_expr(p.polwithcheck, p.polrelid),'-')
    from pg_policy p join pg_class c on c.oid = p.polrelid where c.relnamespace = 'public'::regnamespace and c.relname like 'food\_%'
  union all
  select 'acl '||c.relname||' '||coalesce(array_to_string(array(select x from unnest(c.relacl) x order by x::text), ' '), '-')
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname like 'food\_%'
  union all
  select 'colacl '||c.relname||' '||a.attname||' '||array_to_string(a.attacl, ' ')
    from pg_attribute a join pg_class c on c.oid = a.attrelid where c.relnamespace = 'public'::regnamespace and c.relname like 'food\_%' and a.attacl is not null
  union all
  select 'schema private exists=' || exists(select 1 from pg_namespace where nspname = 'private')
  union all
  select 'role daily_brief_menu_reader exists=' || exists(select 1 from pg_roles where rolname = 'daily_brief_menu_reader')
$s$;
create function pg_temp.probe(p_label text, p_role text, p_sub text, p_sql text, p_expect text) returns void language plpgsql as $f$
declare n bigint := null; st text := null; outcome text; ok boolean;
begin
  -- Real existing keys, looked up as postgres before switching role, so the
  -- non-owner probes aim at rows the owner actually has.
  p_sql := replace(p_sql, '{week}', (select max(week_start)::text from public.food_week_plans));
  p_sql := replace(p_sql, '{log_id}', (select id from public.food_log_items order by created_at desc limit 1));
  p_sql := replace(p_sql, '{conv_id}', (select id from public.food_dietitian_conversations order by updated_at desc limit 1));
  begin
    execute format('set local role %I', p_role);
    if p_sub is not null and p_sub <> 'none' then
      perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_role)::text, true);
      perform set_config('request.jwt.claim.sub', p_sub, true);
    else
      perform set_config('request.jwt.claims', json_build_object('role', p_role)::text, true);
      perform set_config('request.jwt.claim.sub', '', true);
    end if;
    execute p_sql;
    get diagnostics n = row_count;
    raise exception using errcode = 'P0001', message = 'undo';   -- roll back this probe's effects
  exception
    when sqlstate 'P0001' then null;                              -- success path (n set)
    when others then st := sqlstate; n := null;
  end;
  outcome := coalesce(st, 'ok:' || n);
  ok := case
    when p_expect = 'ok'  then st is null
    when p_expect = 'ok+' then st is null and n > 0
    when p_expect = 'ok0' then st is null and n = 0
    else st = p_expect end;
  insert into pg_temp._res (label, expect, outcome, pass) values (p_label, p_expect, outcome, ok);
end $f$;
create temp table _before as select * from pg_temp.food_state();

-- ===== Daily Brief reader (daily-brief repo, db/daily-brief-menu-reader.sql) =====
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'daily_brief_menu_reader') then
    create role daily_brief_menu_reader
      login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls
      connection limit 2;
  end if;
end $$;

-- Supabase's postgres role isn't a superuser, so ALTER ROLE may only touch
-- attributes it is allowed to change; the rest are asserted below instead.
alter role daily_brief_menu_reader login noinherit connection limit 2;
do $$
declare r pg_roles%rowtype;
begin
  select * into r from pg_roles where rolname = 'daily_brief_menu_reader';
  if r.rolsuper or r.rolreplication or r.rolbypassrls or r.rolcreatedb or r.rolcreaterole or r.rolinherit then
    raise exception 'daily_brief_menu_reader has unexpected attributes; refusing to continue';
  end if;
  if exists (select 1 from pg_auth_members where member = r.oid) then
    raise exception 'daily_brief_menu_reader is a member of another role; refusing to continue';
  end if;
end $$;
alter role daily_brief_menu_reader set default_transaction_read_only = on;
alter role daily_brief_menu_reader set statement_timeout = '5s';
alter role daily_brief_menu_reader set idle_in_transaction_session_timeout = '10s';

grant usage on schema public to daily_brief_menu_reader;
grant select (week_start, meals, meals_reset_at) on public.food_week_plans to daily_brief_menu_reader;

drop policy if exists food_week_plans_daily_brief_menu_select on public.food_week_plans;
create policy food_week_plans_daily_brief_menu_select on public.food_week_plans
  for select to daily_brief_menu_reader using (true);


-- Test harness only (rolled back): on PG16+ the role that creates another role
-- gets ADMIN on it but not SET, so postgres couldn't SET ROLE to it for the
-- probes. Production doesn't need this: Daily Brief logs in as the role itself.
grant daily_brief_menu_reader to postgres with set true, inherit false;

-- ===== Lockdown (db/food-owner-lockdown.sql) =====
-- Owner-only access for the food_* tables (Reading Center, fdbkdsracxomwyytfgob).
--
-- PROPOSED — NOT APPLIED. Requires separate approval. Apply only after:
--   * the Daily Brief restricted reader (daily-brief repo, db/daily-brief-menu-reader.sql)
--     exists and its connection check passes, and
--   * db/food-owner-lockdown-test.sql passes in full.
-- Rollback: db/food-owner-lockdown-rollback.sql (restores today's exact state).
-- Idempotent: safe to re-run.
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

-- ===== Probes =====
-- Cases: one row per query; expectations for owner / non-owner / anon (null = not run).
create temp table _cases (id serial, label text, sql text, owner_e text, other_e text, anon_e text);
insert into _cases (label, sql, owner_e, other_e, anon_e) values
  ('FP load taste notes', 'select id, note from public.food_taste_notes where archived = false order by created_at', 'ok', 'ok0', '42501'),
  ('FP load Food Log context', 'select title, category, recipe from public.food_log_items where archived = false order by created_at desc limit 40', 'ok+', 'ok0', '42501'),
  ('FP load discover feedback', 'select title, category, liked from public.food_discover_feedback order by created_at desc limit 30', 'ok', 'ok0', '42501'),
  ('FP insert discover feedback', 'insert into public.food_discover_feedback (title, category, blurb, liked) values (''probe'', ''Meals'', ''probe'', true)', 'ok', '42501', '42501'),
  ('FP add taste note (insert returning)', 'insert into public.food_taste_notes (note) values (''probe'') returning id, note', 'ok+', '42501', '42501'),
  ('FP archive taste note', 'update public.food_taste_notes set archived = archived where id = (select max(id) from public.food_taste_notes)', 'ok', 'ok0', '42501'),
  ('FP rename conversation', 'update public.food_dietitian_conversations set title = title where id = (select id from public.food_dietitian_conversations order by updated_at desc limit 1)', 'ok+', 'ok0', '42501'),
  ('FP save recipe to Food Log', 'insert into public.food_log_items (id, title, category, source) values (''probe_fp'', ''Probe'', ''Meals'', ''probe'')', 'ok', '42501', '42501'),
  ('FP upsert conversation (existing id)', 'insert into public.food_dietitian_conversations (id, title, messages, grocery_list, updated_at) select id, title, messages, grocery_list, updated_at from public.food_dietitian_conversations order by updated_at desc limit 1 on conflict (id) do update set updated_at = excluded.updated_at', 'ok+', 'ok0', '42501'),
  ('FP upsert conversation (new id)', 'insert into public.food_dietitian_conversations (id, title, messages, grocery_list, updated_at) values (''probe_conv'', ''Probe'', ''[]'', ''[]'', now()) on conflict (id) do update set updated_at = excluded.updated_at', 'ok', '42501', '42501'),
  ('FP load conversations', 'select id, title, messages, grocery_list, updated_at from public.food_dietitian_conversations where archived = false order by updated_at desc', 'ok+', 'ok0', '42501'),
  ('FP load taste profile', 'select * from public.food_taste_profile where id = 1', 'ok', 'ok0', '42501'),
  ('FP upsert taste profile', 'insert into public.food_taste_profile (id, updated_at) values (1, now()) on conflict (id) do update set updated_at = excluded.updated_at', 'ok', '42501', '42501'),
  ('FP load custom items', 'select kind, name, freezer from public.food_custom_items where archived = false', 'ok', 'ok0', '42501'),
  ('FP upsert custom item', 'insert into public.food_custom_items (kind, name, freezer, archived) values (''protein'', ''probe'', false, false) on conflict (kind, name) do update set archived = excluded.archived', 'ok', '42501', '42501'),
  ('FP archive custom item', 'update public.food_custom_items set archived = archived where (kind, name) in (select kind, name from public.food_custom_items limit 1)', 'ok', 'ok0', '42501'),
  ('FP load history', 'select week_start, proteins, combos, day_plan from public.food_week_plans where week_start < current_date order by week_start desc', 'ok+', 'ok0', '42501'),
  ('FP rate a day', 'update public.food_week_plans set ratings = ratings where week_start = (select max(week_start) from public.food_week_plans)', 'ok+', 'ok0', '42501'),
  ('FP load this week', 'select * from public.food_week_plans where week_start = (select max(week_start) from public.food_week_plans)', 'ok+', 'ok0', '42501'),
  ('FP upsert week (existing)', 'insert into public.food_week_plans (week_start, updated_at) values (date ''{week}'', now()) on conflict (week_start) do update set updated_at = excluded.updated_at', 'ok+', '42501', '42501'),
  ('FP upsert week (new)', 'insert into public.food_week_plans (week_start, updated_at) values (date ''2099-01-04'', now()) on conflict (week_start) do update set updated_at = excluded.updated_at', 'ok', '42501', '42501'),
  ('FP upsert custom combo', 'insert into public.food_custom_combos (protein_id, combo) values (''probe'', ''probe'') on conflict (protein_id, combo) do nothing', 'ok', '42501', '42501'),
  ('FP load custom combos', 'select protein_id, combo from public.food_custom_combos where archived = false', 'ok', 'ok0', '42501'),
  ('FL load items', 'select id, title, category, image, recipe, calories, source_url, created_at from public.food_log_items where archived = false order by created_at', 'ok+', 'ok0', '42501'),
  ('FL upsert item (existing id)', 'insert into public.food_log_items (id, title, category) select id, title, category from public.food_log_items order by created_at desc limit 1 on conflict (id) do update set title = excluded.title', 'ok+', 'ok0', '42501'),
  ('FL upsert item (new id)', 'insert into public.food_log_items (id, title, category) values (''probe_fl'', ''Probe'', ''Meals'') on conflict (id) do update set title = excluded.title', 'ok', '42501', '42501'),
  ('FL archive item', 'update public.food_log_items set archived = archived where id = (select id from public.food_log_items order by created_at desc limit 1)', 'ok+', 'ok0', '42501'),
  ('delete from food_custom_combos', 'delete from public.food_custom_combos where false', '42501', null, null),
  ('truncate food_custom_combos', 'truncate public.food_custom_combos', '42501', null, null),
  ('select food_custom_combos', 'select 1 from public.food_custom_combos limit 1', null, null, '42501'),
  ('select food_custom_combos', 'select 1 from public.food_custom_combos', null, 'ok0', null),
  ('delete from food_custom_items', 'delete from public.food_custom_items where false', '42501', null, null),
  ('truncate food_custom_items', 'truncate public.food_custom_items', '42501', null, null),
  ('select food_custom_items', 'select 1 from public.food_custom_items limit 1', null, null, '42501'),
  ('select food_custom_items', 'select 1 from public.food_custom_items', null, 'ok0', null),
  ('delete from food_dietitian_chat', 'delete from public.food_dietitian_chat where false', '42501', null, null),
  ('truncate food_dietitian_chat', 'truncate public.food_dietitian_chat', '42501', null, null),
  ('select food_dietitian_chat', 'select 1 from public.food_dietitian_chat limit 1', null, null, '42501'),
  ('select food_dietitian_chat', 'select 1 from public.food_dietitian_chat', null, 'ok0', null),
  ('delete from food_dietitian_conversations', 'delete from public.food_dietitian_conversations where false', '42501', null, null),
  ('truncate food_dietitian_conversations', 'truncate public.food_dietitian_conversations', '42501', null, null),
  ('select food_dietitian_conversations', 'select 1 from public.food_dietitian_conversations limit 1', null, null, '42501'),
  ('select food_dietitian_conversations', 'select 1 from public.food_dietitian_conversations', null, 'ok0', null),
  ('delete from food_discover_feedback', 'delete from public.food_discover_feedback where false', '42501', null, null),
  ('truncate food_discover_feedback', 'truncate public.food_discover_feedback', '42501', null, null),
  ('select food_discover_feedback', 'select 1 from public.food_discover_feedback limit 1', null, null, '42501'),
  ('select food_discover_feedback', 'select 1 from public.food_discover_feedback', null, 'ok0', null),
  ('delete from food_log_items', 'delete from public.food_log_items where false', '42501', null, null),
  ('truncate food_log_items', 'truncate public.food_log_items', '42501', null, null),
  ('select food_log_items', 'select 1 from public.food_log_items limit 1', null, null, '42501'),
  ('select food_log_items', 'select 1 from public.food_log_items', null, 'ok0', null),
  ('delete from food_taste_notes', 'delete from public.food_taste_notes where false', '42501', null, null),
  ('truncate food_taste_notes', 'truncate public.food_taste_notes', '42501', null, null),
  ('select food_taste_notes', 'select 1 from public.food_taste_notes limit 1', null, null, '42501'),
  ('select food_taste_notes', 'select 1 from public.food_taste_notes', null, 'ok0', null),
  ('delete from food_taste_profile', 'delete from public.food_taste_profile where false', '42501', null, null),
  ('truncate food_taste_profile', 'truncate public.food_taste_profile', '42501', null, null),
  ('select food_taste_profile', 'select 1 from public.food_taste_profile limit 1', null, null, '42501'),
  ('select food_taste_profile', 'select 1 from public.food_taste_profile', null, 'ok0', null),
  ('delete from food_week_plans', 'delete from public.food_week_plans where false', '42501', null, null),
  ('truncate food_week_plans', 'truncate public.food_week_plans', '42501', null, null),
  ('select food_week_plans', 'select 1 from public.food_week_plans limit 1', null, null, '42501'),
  ('select food_week_plans', 'select 1 from public.food_week_plans', null, 'ok0', null),
  ('dietitian_chat upsert (unused by apps, op kept; table is single-row id=1)', 'insert into public.food_dietitian_chat (id, messages) values (1, ''[]'') on conflict (id) do update set updated_at = public.food_dietitian_chat.updated_at', 'ok', '42501', '42501'),
  ('is_food_owner() is true', 'select 1 where private.is_food_owner()', 'ok+', null, null),
  ('is_food_owner() is false', 'select 1 where private.is_food_owner()', null, 'ok0', null),
  ('cannot call is_food_owner()', 'select private.is_food_owner()', null, null, '42501'),
  ('cannot read allowlist', 'select * from private.food_owners', '42501', '42501', '42501'),
  ('cannot add to allowlist', 'insert into private.food_owners (user_id) values (''24c39f7f-4ed0-41fb-a751-6df86b2d37cd'')', '42501', '42501', null),
  ('cannot remove from allowlist', 'delete from private.food_owners', '42501', '42501', null),
  ('cannot replace is_food_owner()', 'create or replace function private.is_food_owner() returns boolean language sql as $x$ select true $x$', '42501', '42501', null),
  ('cannot take ownership of is_food_owner()', 'alter function private.is_food_owner() owner to authenticated', '42501', '42501', null),
  ('cannot create objects in private', 'create table private.probe (i int)', '42501', '42501', null),
  ('cannot create objects in public', 'create table public.probe_x (i int)', '42501', '42501', null),
  ('upsert onto existing conversation id', 'insert into public.food_dietitian_conversations (id, title, messages, grocery_list, updated_at) values (''{conv_id}'', ''x'', ''[]'', ''[]'', now()) on conflict (id) do update set updated_at = excluded.updated_at', 'ok+', '42501', '42501'),
  ('upsert onto existing Food Log item id', 'insert into public.food_log_items (id, title, category) values (''{log_id}'', ''x'', ''Meals'') on conflict (id) do update set title = public.food_log_items.title', 'ok+', '42501', '42501'),
  ('update existing Food Log item by id', 'update public.food_log_items set title = title where id = ''{log_id}''', 'ok+', 'ok0', '42501'),
  ('update existing week by key', 'update public.food_week_plans set ratings = ratings where week_start = date ''{week}''', 'ok+', 'ok0', '42501'),
  ('read existing Food Log item by id', 'select id from public.food_log_items where id = ''{log_id}''', 'ok+', 'ok0', '42501');
select pg_temp.probe(w.who || ': ' || c.label, w.role, w.sub, c.sql, w.e)
from _cases c
cross join lateral (values
  (1, 'owner', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', c.owner_e),
  (2, 'non-owner', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', c.other_e),
  (3, 'anon', 'anon', null, c.anon_e)) w(n, who, role, sub, e)
where w.e is not null
order by c.id, w.n;

-- Single-identity probes (signed-in without a sub claim, Daily Brief reader, ...)
create temp table _single (id serial, label text, role text, sub text, sql text, e text);
insert into _single (label, role, sub, sql, e) values
  ('signed-in, no sub claim: select food_custom_combos', 'authenticated', 'none', 'select 1 from public.food_custom_combos', 'ok0'),
  ('signed-in, no sub claim: select food_custom_items', 'authenticated', 'none', 'select 1 from public.food_custom_items', 'ok0'),
  ('signed-in, no sub claim: select food_dietitian_chat', 'authenticated', 'none', 'select 1 from public.food_dietitian_chat', 'ok0'),
  ('signed-in, no sub claim: select food_dietitian_conversations', 'authenticated', 'none', 'select 1 from public.food_dietitian_conversations', 'ok0'),
  ('signed-in, no sub claim: select food_discover_feedback', 'authenticated', 'none', 'select 1 from public.food_discover_feedback', 'ok0'),
  ('signed-in, no sub claim: select food_log_items', 'authenticated', 'none', 'select 1 from public.food_log_items', 'ok0'),
  ('signed-in, no sub claim: select food_taste_notes', 'authenticated', 'none', 'select 1 from public.food_taste_notes', 'ok0'),
  ('signed-in, no sub claim: select food_taste_profile', 'authenticated', 'none', 'select 1 from public.food_taste_profile', 'ok0'),
  ('signed-in, no sub claim: select food_week_plans', 'authenticated', 'none', 'select 1 from public.food_week_plans', 'ok0'),
  ('daily brief: production menu query (latest week)', 'daily_brief_menu_reader', null, 'select meals, meals_reset_at from public.food_week_plans where week_start = date ''{week}''', 'ok+'),
  ('daily brief: week lookup via allowed column', 'daily_brief_menu_reader', null, 'select meals from public.food_week_plans where week_start = (select max(week_start) from public.food_week_plans)', 'ok+'),
  ('daily brief: menu query by literal week', 'daily_brief_menu_reader', null, 'select meals, meals_reset_at from public.food_week_plans where week_start = date ''2026-11-22''', 'ok'),
  ('daily brief: select * refused', 'daily_brief_menu_reader', null, 'select * from public.food_week_plans limit 1', '42501'),
  ('daily brief: other column refused', 'daily_brief_menu_reader', null, 'select proteins from public.food_week_plans limit 1', '42501'),
  ('daily brief: write refused', 'daily_brief_menu_reader', null, 'update public.food_week_plans set meals = meals where false', '42501'),
  ('daily brief: other food table refused', 'daily_brief_menu_reader', null, 'select 1 from public.food_log_items limit 1', '42501'),
  ('daily brief: allowlist refused', 'daily_brief_menu_reader', null, 'select 1 from private.food_owners', '42501');
select pg_temp.probe(label, role, sub, sql, e) from _single order by id;


-- Effective privileges, not just policy text
insert into pg_temp._res (label, expect, outcome, pass)
select 'effective: '||r||' on '||t, e,
  coalesce(nullif(array_to_string(array_remove(array[
    case when has_table_privilege(r, 'public.'||t, 'SELECT') then 'SELECT' when has_any_column_privilege(r, 'public.'||t, 'SELECT') then 'SELECT(cols)' end,
    case when has_table_privilege(r, 'public.'||t, 'INSERT') then 'INSERT' end,
    case when has_table_privilege(r, 'public.'||t, 'UPDATE') then 'UPDATE' end,
    case when has_table_privilege(r, 'public.'||t, 'DELETE') then 'DELETE' end,
    case when has_table_privilege(r, 'public.'||t, 'TRUNCATE') then 'TRUNCATE' end,
    case when has_table_privilege(r, 'public.'||t, 'REFERENCES') then 'REFERENCES' end,
    case when has_table_privilege(r, 'public.'||t, 'TRIGGER') then 'TRIGGER' end,
    case when current_setting('server_version_num')::int >= 170000 and has_table_privilege(r, 'public.'||t, 'MAINTAIN') then 'MAINTAIN' end], null), ','), ''), 'none') as got,
  null
from (values ('food_custom_combos'), ('food_custom_items'), ('food_dietitian_chat'), ('food_dietitian_conversations'), ('food_discover_feedback'), ('food_log_items'), ('food_taste_notes'), ('food_taste_profile'), ('food_week_plans')) tt(t)
cross join (values ('anon'), ('authenticated'), ('daily_brief_menu_reader')) rr(r)
cross join lateral (select case
  when r = 'anon' then 'none'
  when r = 'daily_brief_menu_reader' then case when t = 'food_week_plans' then 'SELECT(cols)' else 'none' end
  when t = 'food_discover_feedback' then 'SELECT,INSERT'
  else 'SELECT,INSERT,UPDATE' end as e) ee;
update pg_temp._res set pass = (outcome = expect) where pass is null;

insert into pg_temp._res (label, expect, outcome, pass)
select 'effective: daily_brief_menu_reader readable columns', 'meals,meals_reset_at,week_start',
  string_agg(attname, ',' order by attname), null
from pg_attribute where attrelid = 'public.food_week_plans'::regclass and attnum > 0 and not attisdropped
  and has_column_privilege('daily_brief_menu_reader', attrelid, attnum, 'SELECT');
insert into pg_temp._res (label, expect, outcome, pass)
select 'effective: sequences, anon/authenticated', 'none',
  coalesce(string_agg(c.relname||':'||r, ','), 'none'), null
from pg_class c cross join (values ('anon'), ('authenticated')) rr(r)
where c.relkind = 'S' and c.relnamespace = 'public'::regnamespace and c.relname like 'food\_%'
  and (has_sequence_privilege(r, c.oid, 'USAGE') or has_sequence_privilege(r, c.oid, 'UPDATE') or has_sequence_privilege(r, c.oid, 'SELECT'));
insert into pg_temp._res (label, expect, outcome, pass)
select 'function contract: owner/definer/search_path/PUBLIC', 'postgres|definer|search_path=""|no PUBLIC|anon:f|authenticated:t',
  pg_get_userbyid(p.proowner)||'|'||case when p.prosecdef then 'definer' else 'invoker' end||'|'||array_to_string(p.proconfig, ',')||'|'
  ||case when exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then 'PUBLIC execute' else 'no PUBLIC' end
  ||'|anon:'||left(has_function_privilege('anon', p.oid, 'EXECUTE')::text, 1)||'|authenticated:'||left(has_function_privilege('authenticated', p.oid, 'EXECUTE')::text, 1), null
from pg_proc p where p.oid = 'private.is_food_owner()'::regprocedure;
insert into pg_temp._res (label, expect, outcome, pass)
select 'allowlist contract: owner/RLS/rows/client privileges', 'postgres|rls|1 row|anon:none|authenticated:none',
  pg_get_userbyid(c.relowner)||'|'||case when c.relrowsecurity then 'rls' else 'no rls' end||'|'||(select count(*) from private.food_owners)||' row'
  ||'|anon:'||case when has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE') then 'some' else 'none' end
  ||'|authenticated:'||case when has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE') then 'some' else 'none' end, null
from pg_class c where c.oid = 'private.food_owners'::regclass;
insert into pg_temp._res (label, expect, outcome, pass)
select 'schema private: create/usage', 'anon:create=f,usage=f|authenticated:create=f,usage=t',
  'anon:create='||left(has_schema_privilege('anon','private','CREATE')::text,1)||',usage='||left(has_schema_privilege('anon','private','USAGE')::text,1)
  ||'|authenticated:create='||left(has_schema_privilege('authenticated','private','CREATE')::text,1)||',usage='||left(has_schema_privilege('authenticated','private','USAGE')::text,1), null;
update pg_temp._res set pass = (outcome = expect) where pass is null;

-- ===== Rollback (db/food-owner-lockdown-rollback.sql + Daily Brief reader rollback) =====
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

grant all on public.food_custom_combos to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_custom_items to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_dietitian_chat to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_dietitian_conversations to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_discover_feedback to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_log_items to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_taste_notes to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_taste_profile to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant all on public.food_week_plans to anon, authenticated;   -- ALL = arwdDxtm on PG17 (includes MAINTAIN)
grant select, update, usage on sequence public.food_custom_combos_id_seq to anon, authenticated;
grant select, update, usage on sequence public.food_custom_items_id_seq to anon, authenticated;
grant select, update, usage on sequence public.food_discover_feedback_id_seq to anon, authenticated;
grant select, update, usage on sequence public.food_taste_notes_id_seq to anon, authenticated;

drop function if exists private.is_food_owner();
drop table if exists private.food_owners;
drop schema if exists private;   -- fails safely (not cascade) if anything else lives there

drop policy if exists food_week_plans_daily_brief_menu_select on public.food_week_plans;
revoke select (week_start, meals, meals_reset_at) on public.food_week_plans from daily_brief_menu_reader;
revoke usage on schema public from daily_brief_menu_reader;
drop role if exists daily_brief_menu_reader;

insert into _res (label, expect, outcome, pass)
select 'rollback restores exact pre-lockdown state', '0 differences',
  (select count(*) from ((select * from _before except select * from pg_temp.food_state())
                         union all (select * from pg_temp.food_state() except select * from _before)) d) || ' differences', null;
update _res set pass = (outcome = expect) where pass is null;

select (select count(*) filter (where pass) from _res) || ' passed, ' || (select count(*) filter (where not pass or pass is null) from _res) || ' failed' as summary,
       ord, label, expect, outcome, pass
from _res order by pass nulls first, ord;

rollback;
