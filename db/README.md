# Food data access (Reading Center, `fdbkdsracxomwyytfgob`)

The nine `food_*` tables are **owner-only**. Food-planning and Food Log reach
them only as the signed-in owner; anonymous access is gone.

| | |
|---|---|
| Applied | 2026-11-22 03:28 UTC, migration `20261122032835_food_owner_lockdown` |
| Source of record | [`food-owner-lockdown.sql`](food-owner-lockdown.sql) (statements byte-identical to what ran) |
| Rollback | [`food-owner-lockdown-rollback.sql`](food-owner-lockdown-rollback.sql) (restores the old **open** state — emergency use only) |
| Test | [`food-owner-lockdown-test.sql`](food-owner-lockdown-test.sql) (one transaction, always rolled back) |
| Tables and columns | [`../supabase-schema.sql`](../supabase-schema.sql) (no policies or grants) |

## Access model

- **Owner allowlist.** `private.food_owners` holds the owner's Auth user id.
  RLS is on with no policies, and no client role has any privilege on it:
  only its owner (`postgres`) reads it.
- **Ownership check.** `private.is_food_owner()` is `SECURITY DEFINER`, owned
  by `postgres`, with an empty `search_path` and no arguments. It answers
  "is the signed-in user the owner?" using `auth.uid()` from the verified
  JWT, so callers can't ask about anyone else. `EXECUTE` is revoked from
  `PUBLIC` and `anon` and granted only to `authenticated`.
- **Policies.** Every food table has owner-only policies for exactly the
  operations the apps use, written as `(select private.is_food_owner())` so
  it runs once per query:
  - select, insert, update on all tables except `food_discover_feedback`
    (select, insert — it's an append-only log)
  - **no delete anywhere**; removal is an `archived` flag
- **Grants.**
  - `anon`: nothing on any food table or identity sequence.
  - `authenticated`: only select/insert/update (select/insert on
    `food_discover_feedback`) — no `DELETE`, `TRUNCATE`, `REFERENCES`,
    `TRIGGER` or `MAINTAIN`. No sequence privileges (identity columns are
    `GENERATED ALWAYS`).
- **Data API.** Only `public` and `graphql_public` are exposed; `private` is
  not (a request to it returns `PGRST106`).
- **Auth.** Email + password, public sign-ups **off** (a sign-up attempt
  returns `422 signup_disabled`). The owner account is shared with QuickSum.

## Setting up a fresh project

1. Run `supabase-schema.sql`. On its own this leaves every food table with
   RLS on and no policies, so it fails **closed**: nobody can read or write
   through the API.
2. Create the owner's Auth user, disable public sign-ups.
3. Put that user's id in the allowlist insert in `food-owner-lockdown.sql`
   and run it. The id references `auth.users`, so a wrong id fails loudly.
4. Run `food-owner-lockdown-test.sql` and expect `0 failed`.

Do **not** add `to anon` policies to `supabase-schema.sql` again: policies are
OR'ed, so one permissive policy next to the owner-only ones reopens the table.

## Verification (2026-11-22)

| Check | Result |
|---|---|
| Test file against production, pre-cutover (rolled back) | 203/203, rollback restored the snapshot with 0 differences |
| Live after cutover | anon REST read/insert/update/delete → `42501`; `private` RPC → `PGRST106`; sign-up → `422 signup_disabled` |
| Real sessions after cutover | owner loads and saves in both PWAs; non-owner test account sees nothing and can't save |
| Re-applying the lockdown to secured production (rolled back) | access-state hash identical before/after |
| Fresh database from this repo (Postgres 16 configured like Supabase) | schema matches production column-for-column (87/87); 0 policies before the lockdown, fails closed |
| Re-running `supabase-schema.sql` on a secured database | no policies added, access state unchanged |
| Test file on a secured database (regression mode) | 204/204; reports `post-cutover regression` mode |

## Accepted limitations and follow-ups

- **Daily Brief menu is unavailable** until its restricted reader
  (`daily_brief_menu_reader`, daily-brief repo `db/daily-brief-menu-reader.sql`)
  is created and wired up. Accepted because the scheduled full brief is
  dormant (the "This Week" override is on) and its failure path shows "Menu
  unavailable" without cancelling the email. The reader is a prerequisite
  before the full brief is switched back on.
- **Default privileges for new tables.** Supabase's defaults still grant
  `anon` and `authenticated` full privileges on any *new* table in `public`.
  A new food table needs its own revoke and owner policies when it's created.
  Changing the project-wide defaults is a separately scoped follow-up.
- **Shared owner account.** The apps sign out with `scope: 'local'`, but a
  password change or an admin "revoke all sessions" also signs out QuickSum's
  headless MCP until it signs in again.
- **Temporary non-owner test account** (`24c39f7f-…`) is kept until QuickSum
  finishes its pre- and post-lockdown denial tests, then deleted.
