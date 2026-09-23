-- ============================================================
-- ESTORA — Supabase schema with row-level security
-- Run this in the Supabase SQL editor: SQL Editor -> New query ->
-- paste all -> Run. It is safe to run again whenever you take an
-- update: it never deletes data.
--
-- Every permission the app shows is enforced here, on the server,
-- so a modified browser cannot read or write past it. That includes
-- the licence: plan, seats, projects and expiry live in columns the
-- browser cannot write, keys are checked here against a secret the
-- browser never sees, and the plan limits are counted here too.
--
-- All tables and functions start with es_, so ESTORA can share a
-- Supabase project with Control Room (cr_) without touching it.
-- ============================================================

create extension if not exists pgcrypto;

-- ====================================================================
-- VENDOR SETTINGS — yours, not your customers'.
-- Row-level security is on and there are no policies, so nothing in the
-- browser can read or change these. Change them here, in the SQL editor.
-- ====================================================================
create table if not exists es_vendor (
  key   text primary key,
  value text not null
);
alter table es_vendor enable row level security;

-- The secret your licence keys are signed with. It must be the SAME string
-- as LICENSE_SECRET in license-keygen.html. Change both before you sell,
-- to any private string of letters, digits and dashes:
--   update es_vendor set value = 'YOUR-OWN-SECRET' where key = 'license_secret';
insert into es_vendor (key, value) values ('license_secret', 'ARCON-ESTORA-2026-7d41') on conflict (key) do nothing;
-- 'on' enforces seats, projects, trial items and expiry. 'off' lifts every
-- limit (for your own testing). Authentication and roles apply either way.
insert into es_vendor (key, value) values ('enforce_limits', 'on') on conflict (key) do nothing;
insert into es_vendor (key, value) values ('trial_days', '7')      on conflict (key) do nothing;
insert into es_vendor (key, value) values ('trial_users', '2')     on conflict (key) do nothing;
insert into es_vendor (key, value) values ('trial_projects', '1')  on conflict (key) do nothing;
insert into es_vendor (key, value) values ('trial_items', '5')     on conflict (key) do nothing;

-- The people allowed to open the Owner panel (you). Add your own sign-in email:
--   insert into es_owners (email) values ('you@yourdomain.com') on conflict do nothing;
create table if not exists es_owners (
  email    text primary key,
  added_at timestamptz not null default now()
);
alter table es_owners enable row level security;

create or replace function es_setting(k text) returns text
  language sql stable security definer set search_path = public as $$
  select value from es_vendor where key = k $$;

-- ====================================================================
-- ORGANISATIONS — one row per customer company. Everything else carries
-- an org_id that points here, and every policy is written against it, so
-- two customers in the same database never see each other's work.
-- The licence columns are written only by the functions further down.
-- ====================================================================
create table if not exists es_orgs (
  id           text primary key,
  name         text not null,
  owner_uid    uuid references auth.users(id) on delete set null,
  plan         text not null default 'trial',   -- trial|starter|team|business|enterprise
  seats        int  not null default 2,
  max_projects int  not null default 1,
  expires_on   date not null default (current_date + 7),
  license_key  text,
  activated_at timestamptz,
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------- people ----------
create table if not exists es_users (
  id          text primary key,
  auth_uid    uuid unique references auth.users(id) on delete set null,
  org_id      text not null references es_orgs(id) on delete cascade,
  name        text not null,
  email       text,
  dept        text,
  role        text not null default 'Viewer',   -- Admin|Manager|Estimator|Viewer
  projects    jsonb not null default '"all"'::jsonb,
  tabs        jsonb not null default '["schedule","bom","rates","params","iron","commercial"]'::jsonb,
  active      boolean not null default true,
  invited_at  timestamptz,
  invite_code text,
  created_at  timestamptz not null default now()
);
create index if not exists es_users_org on es_users(org_id);
create unique index if not exists es_users_email_uq on es_users(org_id, lower(email)) where email is not null;

-- ---------- helpers: who is calling, and what may they do ----------
create or replace function es_org() returns text
  language sql stable security definer set search_path = public as $$
  select org_id from es_users where auth_uid = auth.uid() limit 1 $$;

-- a deactivated account keeps its record and history but ranks lowest
create or replace function es_rank() returns int
  language sql stable security definer set search_path = public as $$
  select case
    when not coalesce((select active from es_users where auth_uid = auth.uid() limit 1), false) then 0
    else case (select role from es_users where auth_uid = auth.uid() limit 1)
      when 'Admin' then 5 when 'Manager' then 4 when 'Estimator' then 3 when 'Viewer' then 1 else 0 end
  end $$;

create or replace function es_is_admin() returns boolean
  language sql stable as $$ select es_rank() >= 5 $$;

-- the licence of an organisation, with its limits, as one JSON document
create or replace function es_license_of(p_org text) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare o es_orgs; enforce boolean; trial boolean; left_days int;
begin
  select * into o from es_orgs where id = p_org;
  if not found then return null; end if;
  enforce := coalesce(es_setting('enforce_limits'), 'on') = 'on';
  trial := o.plan = 'trial';
  left_days := o.expires_on - current_date;
  return jsonb_build_object(
    'plan', o.plan, 'seats', o.seats, 'projects', o.max_projects,
    'expiresOn', o.expires_on, 'daysLeft', left_days, 'expired', left_days < 0,
    'trial', trial, 'enforce', enforce,
    'items', case when trial then coalesce(es_setting('trial_items'),'5')::int else null end,
    'key', o.license_key, 'activatedAt', o.activated_at,
    'usedSeats',    (select count(*) from es_users where org_id = p_org and active),
    'usedProjects', (select count(*) from es_projects where org_id = p_org),
    'usedItems',    (select count(*) from es_lines where org_id = p_org));
end $$;

-- writes to estimates are allowed while the licence is current (or limits are off)
create or replace function es_lic_ok() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(es_setting('enforce_limits'), 'on') <> 'on'
      or coalesce((select expires_on >= current_date from es_orgs where id = es_org()), false) $$;

-- ---------- stamping the organisation onto every row ----------
-- The browser never chooses org_id: it is taken from the caller's own account
-- on the way in. Trusted writes (this script's functions, the SQL editor) keep theirs.
create or replace function es_stamp_org() returns trigger
  language plpgsql security definer set search_path = public as $$
declare mine text;
begin
  if coalesce(current_setting('es.trusted', true), '') = 'on'
     or coalesce(nullif(current_setting('role', true), ''), 'none') not in ('authenticated','anon') then
    if new.org_id is null then new.org_id := es_org(); end if;
    return new;
  end if;
  mine := es_org();
  if mine is null then raise exception 'no organisation for this account'; end if;
  new.org_id := mine;
  return new;
end $$;

-- ---------- organisation settings: "org" (name, logo, payment links) and "library" (rate library) ----------
create table if not exists es_meta (
  org_id     text not null references es_orgs(id) on delete cascade,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (org_id, id)
);

-- ---------- projects: each carries its own copy of the rate library ----------
create table if not exists es_projects (
  id         text primary key,
  org_id     text not null references es_orgs(id) on delete cascade,
  name       text not null default 'New project',
  code       text, client text,
  location   text, access numeric not null default 1,
  currency   text not null default 'SAR',
  status     text not null default 'Estimating',   -- Estimating|Submitted|Awarded|Lost|On hold
  library    jsonb not null default '{}'::jsonb,   -- params, commercial, types, materials, cores, ironmongery, transport
  seq        int not null default 1,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists es_projects_org on es_projects(org_id);

-- ---------- schedule lines: one row per item, so several estimators can work at once ----------
create table if not exists es_lines (
  id         text primary key,
  org_id     text not null references es_orgs(id) on delete cascade,
  project_id text not null references es_projects(id) on delete cascade,
  pos        int not null default 0,
  data       jsonb not null default '{}'::jsonb,
  updated_by text,
  updated_at timestamptz not null default now()
);
create index if not exists es_lines_proj on es_lines(project_id);
create index if not exists es_lines_org  on es_lines(org_id);

-- may the caller open this project? It must be in their organisation and in their list.
create or replace function es_can_project(p text) returns boolean
  language sql stable security definer set search_path = public as $$
  select case
    when es_org() is null then false
    when not exists (select 1 from es_projects where id = p and org_id = es_org()) then false
    when (select projects from es_users where auth_uid = auth.uid() limit 1) = '"all"'::jsonb then true
    else coalesce((select projects from es_users where auth_uid = auth.uid() limit 1) ? p, false)
  end $$;

-- ---------- licence keys: one key belongs to one organisation ----------
create table if not exists es_license_keys (
  key          text primary key,
  org_id       text not null references es_orgs(id) on delete cascade,
  plan         text not null,
  seats        int not null,
  max_projects int not null,
  expires_on   date not null,
  activated_by text,
  activated_at timestamptz not null default now()
);

-- ---------- payments ----------
-- Written only by server-side code: the Owner panel's manual record, or a
-- payment provider's webhook running with the service key. provider_ref is
-- unique, so a replayed webhook is harmless.
create table if not exists es_payments (
  id           text primary key default ('pay-' || replace(gen_random_uuid()::text,'-','')),
  org_id       text not null references es_orgs(id) on delete cascade,
  provider     text not null default 'manual',
  provider_ref text,
  status       text not null default 'paid',      -- pending|paid|failed|refunded|cancelled
  amount       numeric, currency text default 'USD',
  plan         text, seats int, max_projects int,
  period_start date, period_end date,
  payer_email  text,
  note         text,
  raw          jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create unique index if not exists es_payments_ref on es_payments(provider, provider_ref) where provider_ref is not null;
create index if not exists es_payments_org on es_payments(org_id, created_at desc);

-- ====================================================================
-- GUARDS
-- ====================================================================

-- People: the browser may add a colleague (no login yet) and change their
-- role, projects and tabs — never attach a login to a record, and never
-- leave the organisation without an active administrator.
create or replace function es_guard_users() returns trigger
  language plpgsql security definer set search_path = public as $$
declare admins int; cap int; used int;
begin
  if coalesce(current_setting('es.trusted', true), '') = 'on'
     or coalesce(nullif(current_setting('role', true), ''), 'none') not in ('authenticated','anon') then
    return coalesce(new, old);
  end if;
  if tg_op = 'INSERT' then
    if new.auth_uid is not null then raise exception 'a login is attached by the invitation, not by hand' using errcode = '42501'; end if;
    if new.role not in ('Admin','Manager','Estimator','Viewer') then raise exception 'unknown role %', new.role using errcode = '22023'; end if;
    new.invited_at := coalesce(new.invited_at, now());
  elsif tg_op = 'UPDATE' then
    if new.auth_uid is distinct from old.auth_uid then raise exception 'a login is attached by the invitation, not by hand' using errcode = '42501'; end if;
    if new.role not in ('Admin','Manager','Estimator','Viewer') then raise exception 'unknown role %', new.role using errcode = '22023'; end if;
  end if;
  -- seats: counted on the server, when limits are on
  if tg_op in ('INSERT','UPDATE') and new.active and (tg_op = 'INSERT' or not old.active)
     and not (tg_op = 'INSERT' and exists (select 1 from es_users where id = new.id))
     and coalesce(es_setting('enforce_limits'),'on') = 'on' then
    select seats into cap from es_orgs where id = new.org_id;
    select count(*) into used from es_users where org_id = new.org_id and active and id <> new.id;
    if used >= cap then
      raise exception 'All % seats on your plan are in use. Upgrade under Licence & Billing to add more people.', cap using errcode = 'P0001';
    end if;
  end if;
  -- at least one active administrator must remain
  if (tg_op = 'DELETE' and old.role = 'Admin' and old.active)
     or (tg_op = 'UPDATE' and old.role = 'Admin' and old.active and (new.role <> 'Admin' or not new.active)) then
    select count(*) into admins from es_users
      where org_id = old.org_id and role = 'Admin' and active and id <> old.id;
    if admins = 0 then raise exception 'Your organisation needs at least one active administrator.' using errcode = 'P0001'; end if;
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists es_users_guard on es_users;
create trigger es_users_guard before insert or update or delete on es_users
  for each row execute function es_guard_users();

-- Projects: counted against the plan; a creator limited to a list of
-- projects gets the new one added to their list so they can open it.
create or replace function es_guard_projects() returns trigger
  language plpgsql security definer set search_path = public as $$
declare cap int; used int;
begin
  if tg_op = 'INSERT' and coalesce(es_setting('enforce_limits'),'on') = 'on'
     and coalesce(current_setting('es.trusted', true), '') <> 'on'
     and not exists (select 1 from es_projects where id = new.id) then
    select max_projects into cap from es_orgs where id = new.org_id;
    select count(*) into used from es_projects where org_id = new.org_id;
    if used >= cap then
      raise exception 'Your plan allows % project%. Upgrade under Licence & Billing to add more.', cap, case when cap = 1 then '' else 's' end using errcode = 'P0001';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists es_projects_guard on es_projects;
create trigger es_projects_guard before insert or update on es_projects
  for each row execute function es_guard_projects();

create or replace function es_projects_grant() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  update es_users set projects = projects || jsonb_build_array(new.id)
   where auth_uid = auth.uid() and org_id = new.org_id and jsonb_typeof(projects) = 'array'
     and not (projects ? new.id);
  return new;
end $$;
drop trigger if exists es_projects_grant on es_projects;
create trigger es_projects_grant after insert on es_projects
  for each row execute function es_projects_grant();

-- Lines: the free trial prices a limited number of items.
create or replace function es_guard_lines() returns trigger
  language plpgsql security definer set search_path = public as $$
declare pl text; cap int; used int;
begin
  if (select org_id from es_projects where id = new.project_id) is distinct from new.org_id then
    raise exception 'that project is not in your organisation' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' and coalesce(es_setting('enforce_limits'),'on') = 'on'
     and not exists (select 1 from es_lines where id = new.id) then
    select plan into pl from es_orgs where id = new.org_id;
    if pl = 'trial' then
      cap := coalesce(es_setting('trial_items'),'5')::int;
      select count(*) into used from es_lines where org_id = new.org_id;
      if used >= cap then
        raise exception 'The free trial prices up to % items. Choose a plan under Licence & Billing to add more.', cap using errcode = 'P0001';
      end if;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists es_lines_guard on es_lines;
create trigger es_lines_guard before insert or update on es_lines
  for each row execute function es_guard_lines();

-- the organisation stamp on every tenant table
do $do$
declare t text;
begin
  foreach t in array array['es_users','es_meta','es_projects','es_lines'] loop
    -- named so it sorts before the guards: the organisation is stamped first, then checked
    execute format('drop trigger if exists %I on %I', t||'_a_stamp', t);
    execute format('create trigger %I before insert or update of org_id on %I
                    for each row execute function es_stamp_org()', t||'_a_stamp', t);
  end loop;
end $do$;

-- ====================================================================
-- ROW-LEVEL SECURITY
-- ====================================================================
alter table es_orgs         enable row level security;
alter table es_users        enable row level security;
alter table es_meta         enable row level security;
alter table es_projects     enable row level security;
alter table es_lines        enable row level security;
alter table es_license_keys enable row level security;
alter table es_payments     enable row level security;

-- every es_ policy is dropped and re-stated, so this script can run again safely
do $do$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public' and left(tablename, 3) = 'es_' loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $do$;

-- organisations: your own, read-only. Renaming and licences go through functions.
create policy es_orgs_read on es_orgs for select using (id = es_org());

-- people: everyone sees the team; administrators change it
create policy es_users_read  on es_users for select using (org_id = es_org());
create policy es_users_ins   on es_users for insert with check (org_id = es_org() and es_is_admin());
create policy es_users_upd   on es_users for update using (org_id = es_org() and es_is_admin())
                                                  with check (org_id = es_org() and es_is_admin());
create policy es_users_del   on es_users for delete using (org_id = es_org() and es_is_admin());

-- settings: everyone reads; administrators write; managers may also write the rate library
create policy es_meta_read on es_meta for select using (org_id = es_org());
create policy es_meta_ins  on es_meta for insert
  with check (org_id = es_org() and (es_is_admin() or (id = 'library' and es_rank() >= 4)));
create policy es_meta_upd  on es_meta for update
  using      (org_id = es_org() and (es_is_admin() or (id = 'library' and es_rank() >= 4)))
  with check (org_id = es_org() and (es_is_admin() or (id = 'library' and es_rank() >= 4)));
create policy es_meta_del  on es_meta for delete using (org_id = es_org() and es_is_admin());

-- projects: visible when granted; managers create; estimators edit; removal goes through es_delete_project
create policy es_projects_read on es_projects for select
  using (org_id = es_org() and es_can_project(id));
create policy es_projects_ins on es_projects for insert
  with check (org_id = es_org() and es_rank() >= 4 and es_lic_ok());
create policy es_projects_upd on es_projects for update
  using      (org_id = es_org() and es_can_project(id) and es_rank() >= 3 and es_lic_ok())
  with check (org_id = es_org() and es_can_project(id) and es_rank() >= 3 and es_lic_ok());

-- lines: read with the project; estimators and above write while the licence is current
create policy es_lines_read on es_lines for select
  using (org_id = es_org() and es_can_project(project_id));
create policy es_lines_write on es_lines for all
  using      (org_id = es_org() and es_can_project(project_id) and es_rank() >= 3 and es_lic_ok())
  with check (org_id = es_org() and es_can_project(project_id) and es_rank() >= 3 and es_lic_ok());

-- licence history and payments: the administrator reads; nobody writes from the browser
create policy es_keys_read on es_license_keys for select using (org_id = es_org() and es_is_admin());
create policy es_payments_read on es_payments for select using (org_id = es_org() and es_is_admin());

-- ====================================================================
-- LICENCE KEYS — the same format as Control Room's, prefix ES2-.
-- Checked here, against es_vendor.license_secret, which the browser
-- never sees. license-keygen.html makes keys with the same secret.
-- ====================================================================
create or replace function es_h32(s text) returns bigint
  language plpgsql immutable as $$
declare h bigint := 2166136261; i int;
begin
  for i in 1..length(s) loop
    h := h # ascii(substr(s, i, 1));
    h := (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + ((h << 24) & 4294967295)) & 4294967295;
  end loop;
  return h;
end $$;

create or replace function es_b36(n bigint, len int) returns text
  language plpgsql immutable as $$
declare d text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'; r text := ''; v bigint := greatest(n, 0);
begin
  if v = 0 then r := '0'; end if;
  while v > 0 loop r := substr(d, (v % 36)::int + 1, 1) || r; v := v / 36; end loop;
  if length(r) < len then r := lpad(r, len, '0'); end if;
  return right(r, len);
end $$;

create or replace function es_from36(t text) returns bigint
  language plpgsql immutable as $$
declare d text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'; v bigint := 0; i int;
begin
  for i in 1..length(t) loop v := v * 36 + strpos(d, substr(t, i, 1)) - 1; end loop;
  return v;
end $$;

-- read a key: returns null when it is mistyped or was not signed with your secret
create or replace function es_read_key(p_key text) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare raw text; body text; sig text; tier text; secret text;
begin
  raw := regexp_replace(upper(coalesce(p_key, '')), '[^A-Z0-9]', '', 'g');
  if left(raw, 3) = 'ES2' then raw := substr(raw, 4); end if;
  if length(raw) <> 15 then return null; end if;
  body := left(raw, 9); sig := right(raw, 6);
  secret := es_setting('license_secret');
  if es_b36(es_h32(body || secret), 6) <> sig then return null; end if;
  tier := case left(body, 1) when 'T' then 'trial' when 'S' then 'starter' when 'M' then 'team'
                             when 'B' then 'business' when 'E' then 'enterprise' end;
  if tier is null then return null; end if;
  return jsonb_build_object('plan', tier,
    'expiresOn', (date '2024-01-01' + es_from36(substr(body, 2, 4))::int),
    'seats', es_from36(substr(body, 6, 2)), 'projects', es_from36(substr(body, 8, 2)),
    'key', 'ES2-' || substr(raw,1,4) || '-' || substr(raw,5,4) || '-' || substr(raw,9,4) || '-' || substr(raw,13,3));
end $$;

-- the administrator pastes a key; the server checks it and applies the plan
create or replace function es_activate_key(p_key text) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare k jsonb; org text := es_org(); holder text; who text;
begin
  if auth.uid() is null or org is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if not es_is_admin() then raise exception 'only an administrator can activate a licence' using errcode = '42501'; end if;
  k := es_read_key(p_key);
  if k is null then raise exception 'That key is not valid — check it was copied completely.' using errcode = '22023'; end if;
  if (k->>'expiresOn')::date < current_date then raise exception 'That key expired on %.', k->>'expiresOn' using errcode = '22023'; end if;
  select org_id into holder from es_license_keys where key = k->>'key';
  if holder is not null and holder <> org then
    raise exception 'That key is already in use by another organisation.' using errcode = '42501';
  end if;
  select name into who from es_users where auth_uid = auth.uid() limit 1;
  perform set_config('es.trusted', 'on', true);
  insert into es_license_keys (key, org_id, plan, seats, max_projects, expires_on, activated_by)
    values (k->>'key', org, k->>'plan', (k->>'seats')::int, (k->>'projects')::int, (k->>'expiresOn')::date, who)
    on conflict (key) do nothing;
  update es_orgs set plan = k->>'plan', seats = (k->>'seats')::int, max_projects = (k->>'projects')::int,
                     expires_on = (k->>'expiresOn')::date, license_key = k->>'key',
                     activated_at = now(), updated_at = now()
   where id = org;
  return es_license_of(org);
end $$;

-- ====================================================================
-- ONBOARDING — the only way across the gap between "signed in" and
-- "in an organisation". Each function checks auth.uid() for itself.
-- ====================================================================
create or replace function es_register_org(p_org_name text, p_person_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid; em text; new_org text; existing text; days int;
begin
  uid := auth.uid();
  if uid is null then raise exception 'not signed in'; end if;
  perform set_config('es.trusted', 'on', true);
  select org_id into existing from es_users where auth_uid = uid limit 1;
  if existing is not null then return jsonb_build_object('orgId', existing, 'created', false); end if;
  if coalesce(trim(p_org_name), '') = '' then raise exception 'an organisation name is required'; end if;
  select email into em from auth.users where id = uid;
  days := coalesce(es_setting('trial_days'), '7')::int;
  new_org := 'org-' || replace(gen_random_uuid()::text, '-', '');
  insert into es_orgs (id, name, owner_uid, plan, seats, max_projects, expires_on)
    values (new_org, trim(p_org_name), uid, 'trial',
            coalesce(es_setting('trial_users'),'2')::int, coalesce(es_setting('trial_projects'),'1')::int,
            current_date + days);
  insert into es_users (id, auth_uid, org_id, name, email, role, dept, projects, active)
    values ('u-' || replace(gen_random_uuid()::text, '-', ''), uid, new_org,
            coalesce(nullif(trim(p_person_name), ''), split_part(coalesce(em, 'Administrator'), '@', 1)),
            em, 'Admin', 'Management', '"all"'::jsonb, true);
  insert into es_meta (org_id, id, data) values (new_org, 'org', jsonb_build_object('name', trim(p_org_name)))
    on conflict (org_id, id) do nothing;
  return jsonb_build_object('orgId', new_org, 'created', true);
end $$;

-- an invited colleague signing in for the first time: matched on their own
-- account email AND the invitation code, so nobody can take somebody else's place
create or replace function es_claim_invite(p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid; em text; got text;
begin
  uid := auth.uid();
  if uid is null then raise exception 'not signed in'; end if;
  perform set_config('es.trusted', 'on', true);
  select org_id into got from es_users where auth_uid = uid limit 1;
  if got is not null then return jsonb_build_object('orgId', got, 'claimed', false); end if;
  select email into em from auth.users where id = uid;
  if em is null then raise exception 'no email on this account'; end if;
  update es_users set auth_uid = uid, invite_code = null
   where auth_uid is null and lower(email) = lower(em)
     and (invite_code is null or upper(invite_code) = upper(trim(coalesce(p_code, ''))))
   returning org_id into got;
  if got is null then
    if exists (select 1 from es_users where auth_uid is null and lower(email) = lower(em)) then
      raise exception 'that invitation code is not right' using errcode = '28000';
    end if;
    raise exception 'no invitation is waiting for this email';
  end if;
  return jsonb_build_object('orgId', got, 'claimed', true);
end $$;

create or replace function es_is_owner() returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from es_owners o join auth.users u on lower(u.email) = lower(o.email)
                 where u.id = auth.uid()) $$;

-- who is calling, and what may they do — the app asks once at start-up
create or replace function es_whoami()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid; r es_users; on_name text;
begin
  uid := auth.uid();
  if uid is null then return jsonb_build_object('orgId', null); end if;
  select * into r from es_users where auth_uid = uid limit 1;
  if not found then return jsonb_build_object('orgId', null, 'isOwner', es_is_owner()); end if;
  select name into on_name from es_orgs where id = r.org_id;
  return jsonb_build_object('orgId', r.org_id, 'orgName', on_name,
    'userId', r.id, 'name', r.name, 'email', r.email, 'role', r.role, 'dept', r.dept,
    'projects', r.projects, 'tabs', r.tabs, 'active', r.active,
    'license', es_license_of(r.org_id), 'isOwner', es_is_owner());
end $$;

create or replace function es_rename_org(p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare mine text := es_org();
begin
  if mine is null then raise exception 'no organisation for this account'; end if;
  if not es_is_admin() then raise exception 'only an administrator may rename the organisation'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'a name is required'; end if;
  perform set_config('es.trusted', 'on', true);
  update es_orgs set name = trim(p_name), updated_at = now() where id = mine;
  insert into es_meta (org_id, id, data) values (mine, 'org', jsonb_build_object('name', trim(p_name)))
    on conflict (org_id, id) do update set data = jsonb_set(es_meta.data, '{name}', to_jsonb(trim(p_name))), updated_at = now();
  return jsonb_build_object('orgId', mine, 'name', trim(p_name));
end $$;

-- removing a project with every line in it: managers and administrators
create or replace function es_delete_project(p_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare org text := es_org();
begin
  if auth.uid() is null or org is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if es_rank() < 4 then raise exception 'only a manager or an administrator can remove a project' using errcode = '42501'; end if;
  if not exists (select 1 from es_projects where id = p_id and org_id = org) then
    raise exception 'that project no longer exists' using errcode = 'P0002';
  end if;
  perform set_config('es.trusted', 'on', true);
  delete from es_projects where id = p_id and org_id = org;
  update es_users set projects = coalesce((select jsonb_agg(x) from jsonb_array_elements(projects) x
                                           where x #>> '{}' <> p_id), '[]'::jsonb)
   where org_id = org and jsonb_typeof(projects) = 'array' and projects ? p_id;
  return jsonb_build_object('removed', p_id);
end $$;

-- ====================================================================
-- OWNER PANEL — you, across every customer. Only accounts whose email
-- is in es_owners get past the first line of each function.
-- ====================================================================
create or replace function es_owner_orgs()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not es_is_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id, 'name', o.name, 'plan', o.plan, 'seats', o.seats, 'projects', o.max_projects,
      'expiresOn', o.expires_on, 'daysLeft', o.expires_on - current_date, 'key', o.license_key,
      'note', o.note, 'createdAt', o.created_at,
      'admin', (select email from es_users u where u.org_id = o.id and u.role = 'Admin' order by created_at limit 1),
      'usedSeats', (select count(*) from es_users u where u.org_id = o.id and u.active),
      'usedProjects', (select count(*) from es_projects p where p.org_id = o.id),
      'usedItems', (select count(*) from es_lines l where l.org_id = o.id),
      'paid', (select coalesce(sum(amount),0) from es_payments p where p.org_id = o.id and p.status = 'paid'))
    order by o.created_at desc) from es_orgs o), '[]'::jsonb);
end $$;

-- set a customer's plan by hand after they pay you; optionally record the payment
create or replace function es_owner_set_plan(p_org text, p_plan text, p_expires date, p_seats int, p_projects int,
                                             p_amount numeric default null, p_currency text default 'USD',
                                             p_ref text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not es_is_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  if p_plan not in ('trial','starter','team','business','enterprise') then raise exception 'unknown plan %', p_plan; end if;
  if not exists (select 1 from es_orgs where id = p_org) then raise exception 'no such organisation'; end if;
  perform set_config('es.trusted', 'on', true);
  update es_orgs set plan = p_plan, expires_on = p_expires, seats = greatest(1, p_seats),
                     max_projects = greatest(1, p_projects), note = coalesce(p_note, note),
                     activated_at = now(), updated_at = now()
   where id = p_org;
  if p_amount is not null and p_amount > 0 then
    insert into es_payments (org_id, provider, provider_ref, status, amount, currency, plan, seats, max_projects,
                             period_start, period_end, note)
      values (p_org, 'manual', nullif(trim(coalesce(p_ref,'')), ''), 'paid', p_amount, coalesce(p_currency,'USD'),
              p_plan, p_seats, p_projects, current_date, p_expires, p_note);
  end if;
  return es_license_of(p_org);
end $$;

-- ====================================================================
-- PAYMENT GATEWAY HOOK (for later). A provider webhook, running on the
-- server with the service key, calls this once a payment is confirmed.
-- Not callable from the browser.
-- ====================================================================
create or replace function es_record_payment(p_org text, p_provider text, p_ref text, p_amount numeric,
                                             p_currency text, p_plan text, p_seats int, p_projects int,
                                             p_period_end date, p_email text, p_raw jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform set_config('es.trusted', 'on', true);
  insert into es_payments (org_id, provider, provider_ref, status, amount, currency, plan, seats, max_projects,
                           period_start, period_end, payer_email, raw)
    values (p_org, p_provider, p_ref, 'paid', p_amount, p_currency, p_plan, p_seats, p_projects,
            current_date, p_period_end, p_email, coalesce(p_raw, '{}'::jsonb))
    on conflict do nothing;
  update es_orgs set plan = p_plan, seats = p_seats, max_projects = p_projects, expires_on = p_period_end,
                     activated_at = now(), updated_at = now() where id = p_org;
  return es_license_of(p_org);
end $$;

-- ---------- who may call what ----------
revoke all on function es_register_org(text,text) from public;
revoke all on function es_claim_invite(text) from public;
revoke all on function es_whoami() from public;
revoke all on function es_rename_org(text) from public;
revoke all on function es_delete_project(text) from public;
revoke all on function es_activate_key(text) from public;
revoke all on function es_owner_orgs() from public;
revoke all on function es_owner_set_plan(text,text,date,int,int,numeric,text,text,text) from public;
revoke all on function es_record_payment(text,text,text,numeric,text,text,int,int,date,text,jsonb) from public;
revoke all on function es_read_key(text) from public;
revoke all on function es_license_of(text) from public;
revoke all on function es_setting(text) from public;
grant execute on function es_register_org(text,text) to authenticated;
grant execute on function es_claim_invite(text) to authenticated;
grant execute on function es_whoami() to authenticated;
grant execute on function es_rename_org(text) to authenticated;
grant execute on function es_delete_project(text) to authenticated;
grant execute on function es_activate_key(text) to authenticated;
grant execute on function es_owner_orgs() to authenticated;
grant execute on function es_owner_set_plan(text,text,date,int,int,numeric,text,text,text) to authenticated;
-- Supabase grants every new function to anon and authenticated by default,
-- so the internal ones are taken back explicitly. es_setting in particular
-- reads the licence secret and must never be callable from a browser.
do $do$
declare f text; r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      foreach f in array array['es_setting(text)','es_read_key(text)','es_license_of(text)',
          'es_record_payment(text,text,text,numeric,text,text,int,int,date,text,jsonb)',
          'es_h32(text)','es_b36(bigint,int)','es_from36(text)'] loop
        execute format('revoke execute on function %s from %I', f, r);
      end loop;
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    foreach f in array array['es_register_org(text,text)','es_claim_invite(text)','es_rename_org(text)',
        'es_delete_project(text)','es_activate_key(text)','es_owner_orgs()',
        'es_owner_set_plan(text,text,date,int,int,numeric,text,text,text)'] loop
      execute format('revoke execute on function %s from anon', f);
    end loop;
  end if;
end $do$;
do $do$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function es_record_payment(text,text,text,numeric,text,text,int,int,date,text,jsonb) to service_role;
  end if;
end $do$;

-- ============================================================
-- AFTER RUNNING: make yourself the owner (use your sign-in email)
--   insert into es_owners (email) values ('you@yourdomain.com') on conflict do nothing;
-- and set your own licence secret (same string in license-keygen.html)
--   update es_vendor set value = 'YOUR-OWN-SECRET' where key = 'license_secret';
-- ============================================================
