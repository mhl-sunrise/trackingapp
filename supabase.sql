-- ============================================================================
-- Beacon — Supabase schema & migrations
-- Run in the Supabase dashboard: SQL Editor → New query → paste → Run.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. FRESH SETUP — new project, no `locations` table yet.
--    If you already have a `locations` table, skip to section B.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.locations (
  name        text        not null,
  channel     text        not null default 'legacy',
  latitude    double precision,
  longitude   double precision,
  accuracy    double precision,
  recorded_at timestamptz not null default now(),
  primary key (name, channel)
);

alter table public.locations enable row level security;

-- The app authenticates with the public anon key, so anyone can read/write.
-- Channels organise pins; they are NOT a security boundary (see the note below).
drop policy if exists "beacon read"   on public.locations;
drop policy if exists "beacon insert" on public.locations;
drop policy if exists "beacon update" on public.locations;
drop policy if exists "beacon delete" on public.locations;
create policy "beacon read"   on public.locations for select using (true);
create policy "beacon insert" on public.locations for insert with check (true);
create policy "beacon update" on public.locations for update using (true) with check (true);
create policy "beacon delete" on public.locations for delete using (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- B. MIGRATE AN EXISTING TABLE — add channels to a table you already have.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Add the channel column. Existing pins fall into the 'legacy' channel.
alter table public.locations
  add column if not exists channel text not null default 'legacy';

-- 2. Make (name, channel) the row identity instead of name alone, so the same
--    name can be used in different channels. This finds and drops whatever
--    single-column primary/unique key currently sits on `name`, then adds the
--    composite unique key the app upserts against.
do $$
declare cname text;
begin
  for cname in
    select con.conname
    from   pg_constraint con
    join   pg_class      rel on rel.oid = con.conrelid
    join   pg_namespace  ns  on ns.oid  = rel.relnamespace
    join   pg_attribute  a   on a.attrelid = con.conrelid
                            and a.attnum   = any(con.conkey)
    where  ns.nspname  = 'public'
      and  rel.relname = 'locations'
      and  con.contype in ('p','u')
    group by con.conname
    having array_agg(a.attname order by a.attnum) = array['name']::name[]
  loop
    execute format('alter table public.locations drop constraint %I', cname);
  end loop;
end $$;

alter table public.locations
  add constraint locations_name_channel_key unique (name, channel);

-- 3. Let people remove their own pin. The app only ever deletes its own
--    name+channel row, but RLS needs a delete policy to allow it at all.
drop policy if exists "beacon delete" on public.locations;
create policy "beacon delete" on public.locations for delete using (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- Security note
-- ─────────────────────────────────────────────────────────────────────────────
-- Channels keep groups from seeing each other's pins in normal use, but they are
-- NOT access control: the app ships a public anon key, so anyone who knows a
-- channel name (or reads the page source) can read, edit, or DELETE pins in that
-- channel. "Remove my pin" is restricted to your own row only in the client, not
-- by the database. Don't put sensitive locations in a public Beacon. For real
-- isolation, run separate Supabase projects, or add authentication with
-- per-user RLS policies.
