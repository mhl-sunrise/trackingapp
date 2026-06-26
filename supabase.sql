-- ============================================================================
-- Tracker — Supabase schema & migrations  (RPC-by-code, hardened model)
-- Run in the Supabase dashboard: SQL Editor → New query → paste → Run.
--
-- Security model: the browser ships only the public anon key, so the table is
-- NOT exposed directly. All access goes through SECURITY DEFINER functions that
-- require the map code. This stops anyone from dumping every map's locations or
-- touching the table at will. Knowing a code still grants full read/write to
-- THAT map (it's a shared code, like a room link) — for per-user protection,
-- add Supabase Auth with per-user RLS. Don't put sensitive locations here.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. TABLE  (idempotent — safe on a fresh project or an existing one)
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

-- If migrating an older single-column table, make (name, channel) the identity.
alter table public.locations
  add column if not exists channel text not null default 'legacy';
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

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'locations_name_channel_key'
  ) and not exists (
    -- a composite PK already created above on a fresh table also satisfies us
    select 1 from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    where rel.relname = 'locations' and con.contype = 'p'
  ) then
    alter table public.locations
      add constraint locations_name_channel_key unique (name, channel);
  end if;
end $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- B. LOCK DOWN DIRECT ACCESS
--    RLS on + no policies = deny-all for the API roles, and we also revoke the
--    table grants so PostgREST won't expose the table for direct REST queries.
--    Everything goes through the functions in section C.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.locations enable row level security;

drop policy if exists "beacon read"   on public.locations;
drop policy if exists "beacon insert" on public.locations;
drop policy if exists "beacon update" on public.locations;
drop policy if exists "beacon delete" on public.locations;

revoke all on table public.locations from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- C. ACCESS FUNCTIONS  (SECURITY DEFINER — run as owner, bypass RLS)
--    Each requires the map code and validates its inputs server-side, so a
--    tampered client can't inject garbage or read other maps.
-- ─────────────────────────────────────────────────────────────────────────────

-- Read every pin on one map.
create or replace function public.list_pins(p_channel text)
returns setof public.locations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_channel is null or p_channel !~ '^[A-Za-z0-9]{4,32}$' then
    raise exception 'invalid channel';
  end if;
  return query
    select * from public.locations
    where channel = p_channel
    order by recorded_at desc
    limit 1000;
end;
$$;

-- Create or move your own pin on a map.
create or replace function public.upsert_pin(
  p_name    text,
  p_channel text,
  p_lat     double precision,
  p_lon     double precision,
  p_acc     double precision default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name text := btrim(p_name);
begin
  if v_name = '' or char_length(v_name) > 40 then
    raise exception 'invalid name';
  end if;
  if p_channel is null or p_channel !~ '^[A-Za-z0-9]{4,32}$' then
    raise exception 'invalid channel';
  end if;
  if p_lat is null or p_lat <  -90 or p_lat >  90
  or p_lon is null or p_lon < -180 or p_lon > 180 then
    raise exception 'invalid coordinates';
  end if;
  if p_acc is not null and (p_acc < 0 or p_acc > 1000000) then
    p_acc := null;
  end if;

  insert into public.locations (name, channel, latitude, longitude, accuracy, recorded_at)
  values (v_name, p_channel, p_lat, p_lon, p_acc, now())
  on conflict (name, channel) do update
    set latitude    = excluded.latitude,
        longitude   = excluded.longitude,
        accuracy    = excluded.accuracy,
        recorded_at = excluded.recorded_at;
end;
$$;

-- Remove a pin (by name) from a map.
create or replace function public.delete_pin(p_name text, p_channel text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_channel is null or p_channel !~ '^[A-Za-z0-9]{4,32}$' then
    raise exception 'invalid channel';
  end if;
  delete from public.locations
  where name = btrim(p_name) and channel = p_channel;
end;
$$;

-- Only these functions are callable by the browser; nothing else touches the table.
revoke all on function public.list_pins(text)                                                   from public;
revoke all on function public.upsert_pin(text, text, double precision, double precision, double precision) from public;
revoke all on function public.delete_pin(text, text)                                            from public;
grant execute on function public.list_pins(text)                                                   to anon, authenticated;
grant execute on function public.upsert_pin(text, text, double precision, double precision, double precision) to anon, authenticated;
grant execute on function public.delete_pin(text, text)                                            to anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- D. AUTO-EXPIRE PINS — delete rows older than 24h on a schedule (pg_cron).
--    Runs entirely inside Postgres. Safe to re-run (updates the existing job).
-- ─────────────────────────────────────────────────────────────────────────────
create extension if not exists pg_cron;

create index if not exists locations_recorded_at_idx
  on public.locations (recorded_at);

select cron.schedule(
  'beacon-purge-stale-pins',
  '*/15 * * * *',
  $$ delete from public.locations where recorded_at < now() - interval '24 hours' $$
);

-- Handy checks:
--   list functions exposed:   select proname from pg_proc where proname like '%_pin%' or proname = 'list_pins';
--   confirm cron registered:  select * from cron.job;
--   stop auto-expiry:         select cron.unschedule('beacon-purge-stale-pins');


-- ─────────────────────────────────────────────────────────────────────────────
-- Security note
-- ─────────────────────────────────────────────────────────────────────────────
-- The table is no longer directly readable/writable with the anon key — all
-- access requires calling the functions above with a valid map code, which stops
-- table-wide dumps and arbitrary writes. A map code is still a SHARED secret:
-- anyone who has it can read, move, or delete any pin on that map (there are no
-- per-user accounts). For real per-user isolation, add Supabase Auth and rewrite
-- these functions to check auth.uid(). Live updates use Realtime Broadcast on a
-- topic named after the map code — no table read access is involved.
