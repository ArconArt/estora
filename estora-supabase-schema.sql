-- ============================================================
-- ESTORA — Supabase schema (single-user edition)
-- Run this in the Supabase SQL editor: SQL Editor -> New query ->
-- paste all -> Run. It is safe to run again whenever you take an
-- update: it never deletes data.
--
-- What lives here: each customer's ACCOUNT and LICENCE, and their
-- company settings (logo, rate library, profiles and standard sizes).
-- Projects do NOT live here — they are saved as .estora files on the
-- customer's own computer.
--
-- The licence is enforced here: plan and expiry live in columns the
-- browser cannot write, and licence keys are checked against a secret
-- the browser never sees.
--
-- Every table and function starts with es_, so ESTORA can share a
-- Supabase project with Control Room (cr_) without touching it.
-- ============================================================

create extension if not exists pgcrypto;

-- ====================================================================
-- VENDOR SETTINGS — yours, not your customers'. No policies, so nothing
-- in a browser can read or change them. Change them here.
-- ====================================================================
create table if not exists es_vendor (
  key   text primary key,
  value text not null
);
alter table es_vendor enable row level security;

-- The secret licence keys are signed with. It must be the SAME string as
-- LICENSE_SECRET in license-keygen.html. Change both before you sell:
--   update es_vendor set value = 'YOUR-OWN-SECRET' where key = 'license_secret';
insert into es_vendor (key, value) values ('license_secret', 'ARCON-ESTORA-2026-7d41') on conflict (key) do nothing;
-- 'on' enforces the trial and expiry. 'off' lifts every limit while you test.
insert into es_vendor (key, value) values ('enforce_limits', 'on') on conflict (key) do nothing;
insert into es_vendor (key, value) values ('trial_days', '7')      on conflict (key) do nothing;
-- items a trial may price in one project
insert into es_vendor (key, value) values ('trial_items', '5')     on conflict (key) do nothing;

-- The people allowed to open the Owner panel (you):
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
-- ACCOUNTS — one row per customer (one user per licence). The licence
-- columns are written only by the functions further down.
-- ====================================================================
create table if not exists es_orgs (
  id           text primary key,
  name         text not null,
  owner_uid    uuid references auth.users(id) on delete set null,
  plan         text not null default 'trial',   -- trial | monthly | yearly
  expires_on   date not null default (current_date + 7),
  license_key  text,
  activated_at timestamptz,
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists es_users (
  id          text primary key,
  auth_uid    uuid unique references auth.users(id) on delete set null,
  org_id      text not null references es_orgs(id) on delete cascade,
  name        text not null,
  email       text,
  role        text not null default 'Admin',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists es_users_org on es_users(org_id);

create or replace function es_org() returns text
  language sql stable security definer set search_path = public as $$
  select org_id from es_users where auth_uid = auth.uid() and active limit 1 $$;

create or replace function es_is_owner() returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from es_owners o join auth.users u on lower(u.email) = lower(o.email)
                 where u.id = auth.uid()) $$;

-- the licence of an account, as one JSON document
create or replace function es_license_of(p_org text) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare o es_orgs; left_days int;
begin
  select * into o from es_orgs where id = p_org;
  if not found then return null; end if;
  left_days := o.expires_on - current_date;
  return jsonb_build_object(
    'plan', o.plan, 'expiresOn', o.expires_on, 'daysLeft', left_days, 'expired', left_days < 0,
    'trial', o.plan = 'trial', 'enforce', coalesce(es_setting('enforce_limits'), 'on') = 'on',
    'items', case when o.plan = 'trial' then coalesce(es_setting('trial_items'), '5')::int else null end,
    'key', o.license_key, 'activatedAt', o.activated_at);
end $$;

-- the browser never chooses org_id: it is taken from the caller's own account
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
  if mine is null then raise exception 'no account for this sign-in'; end if;
  new.org_id := mine;
  return new;
end $$;

-- ---------- company settings: "org" (name, logo) and "library" (rates, profiles, sizes) ----------
create table if not exists es_meta (
  org_id     text not null references es_orgs(id) on delete cascade,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (org_id, id)
);

-- ---------- licence keys: one key belongs to one account ----------
create table if not exists es_license_keys (
  key          text primary key,
  org_id       text not null references es_orgs(id) on delete cascade,
  plan         text not null,
  expires_on   date not null,
  activated_at timestamptz not null default now()
);

-- upgrading from the earlier team edition: its extra columns become optional
do $do$
declare c text;
begin
  foreach c in array array['seats','max_projects','activated_by'] loop
    if exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='es_license_keys' and column_name=c) then
      execute format('alter table es_license_keys alter column %I drop not null', c);
    end if;
  end loop;
  -- the team edition's seat and project guards no longer apply
  drop trigger if exists es_users_guard on es_users;
end $do$;

-- ---------- payments: written only by the Owner panel or a server-side webhook ----------
create table if not exists es_payments (
  id           text primary key default ('pay-' || replace(gen_random_uuid()::text,'-','')),
  org_id       text not null references es_orgs(id) on delete cascade,
  provider     text not null default 'manual',
  provider_ref text,
  status       text not null default 'paid',
  amount       numeric, currency text default 'USD',
  plan         text,
  period_start date, period_end date,
  payer_email  text,
  note         text,
  raw          jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create unique index if not exists es_payments_ref on es_payments(provider, provider_ref) where provider_ref is not null;
create index if not exists es_payments_org on es_payments(org_id, created_at desc);

-- ---------- organisation stamp ----------
do $do$
declare t text;
begin
  foreach t in array array['es_meta'] loop
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
alter table es_license_keys enable row level security;
alter table es_payments     enable row level security;

do $do$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public' and left(tablename, 3) = 'es_' loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $do$;

create policy es_orgs_read  on es_orgs  for select using (id = es_org());
create policy es_users_read on es_users for select using (auth_uid = auth.uid());
create policy es_meta_read  on es_meta  for select using (org_id = es_org());
create policy es_meta_ins   on es_meta  for insert with check (org_id = es_org());
create policy es_meta_upd   on es_meta  for update using (org_id = es_org()) with check (org_id = es_org());
create policy es_keys_read  on es_license_keys for select using (org_id = es_org());
create policy es_payments_read on es_payments for select using (org_id = es_org());

-- ====================================================================
-- LICENCE KEYS — format ES2-XXXX-XXXX-XXXX-XXX, checked here.
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

create or replace function es_read_key(p_key text) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare raw text; body text; sig text; tier text;
begin
  raw := regexp_replace(upper(coalesce(p_key, '')), '[^A-Z0-9]', '', 'g');
  if left(raw, 3) = 'ES2' then raw := substr(raw, 4); end if;
  if length(raw) <> 15 then return null; end if;
  body := left(raw, 9); sig := right(raw, 6);
  if es_b36(es_h32(body || es_setting('license_secret')), 6) <> sig then return null; end if;
  tier := case left(body, 1) when 'T' then 'trial' when 'M' then 'monthly' when 'Y' then 'yearly' end;
  if tier is null then return null; end if;
  return jsonb_build_object('plan', tier,
    'expiresOn', (date '2024-01-01' + es_from36(substr(body, 2, 4))::int),
    'key', 'ES2-' || substr(raw,1,4) || '-' || substr(raw,5,4) || '-' || substr(raw,9,4) || '-' || substr(raw,13,3));
end $$;

create or replace function es_activate_key(p_key text) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare k jsonb; org text := es_org(); holder text;
begin
  if auth.uid() is null or org is null then raise exception 'sign in first' using errcode = '42501'; end if;
  k := es_read_key(p_key);
  if k is null then raise exception 'That key is not valid — check it was copied completely.' using errcode = '22023'; end if;
  if (k->>'expiresOn')::date < current_date then raise exception 'That key expired on %.', k->>'expiresOn' using errcode = '22023'; end if;
  select org_id into holder from es_license_keys where key = k->>'key';
  if holder is not null and holder <> org then
    raise exception 'That key is already in use on another account.' using errcode = '42501';
  end if;
  perform set_config('es.trusted', 'on', true);
  insert into es_license_keys (key, org_id, plan, expires_on) values (k->>'key', org, k->>'plan', (k->>'expiresOn')::date)
    on conflict (key) do nothing;
  update es_orgs set plan = k->>'plan', expires_on = (k->>'expiresOn')::date, license_key = k->>'key',
                     activated_at = now(), updated_at = now() where id = org;
  return es_license_of(org);
end $$;

-- ====================================================================
-- SIGN-UP AND START-UP
-- ====================================================================
create or replace function es_register_org(p_org_name text, p_person_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid; em text; new_org text; existing text;
begin
  uid := auth.uid();
  if uid is null then raise exception 'not signed in'; end if;
  perform set_config('es.trusted', 'on', true);
  select org_id into existing from es_users where auth_uid = uid limit 1;
  if existing is not null then return jsonb_build_object('orgId', existing, 'created', false); end if;
  if coalesce(trim(p_org_name), '') = '' then raise exception 'a company name is required'; end if;
  select email into em from auth.users where id = uid;
  new_org := 'org-' || replace(gen_random_uuid()::text, '-', '');
  insert into es_orgs (id, name, owner_uid, plan, expires_on)
    values (new_org, trim(p_org_name), uid, 'trial', current_date + coalesce(es_setting('trial_days'),'7')::int);
  insert into es_users (id, auth_uid, org_id, name, email, role, active)
    values ('u-' || replace(gen_random_uuid()::text, '-', ''), uid, new_org,
            coalesce(nullif(trim(p_person_name), ''), split_part(coalesce(em, 'User'), '@', 1)), em, 'Admin', true);
  insert into es_meta (org_id, id, data) values (new_org, 'org', jsonb_build_object('name', trim(p_org_name)))
    on conflict (org_id, id) do nothing;
  return jsonb_build_object('orgId', new_org, 'created', true);
end $$;

create or replace function es_whoami()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid; r es_users; on_name text;
begin
  uid := auth.uid();
  if uid is null then return jsonb_build_object('orgId', null); end if;
  select * into r from es_users where auth_uid = uid limit 1;
  if not found then return jsonb_build_object('orgId', null, 'isOwner', es_is_owner()); end if;
  select name into on_name from es_orgs where id = r.org_id;
  return jsonb_build_object('orgId', r.org_id, 'orgName', on_name, 'userId', r.id, 'name', r.name,
    'email', r.email, 'active', r.active, 'license', es_license_of(r.org_id), 'isOwner', es_is_owner());
end $$;

create or replace function es_rename_org(p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare mine text := es_org();
begin
  if mine is null then raise exception 'no account for this sign-in'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'a name is required'; end if;
  perform set_config('es.trusted', 'on', true);
  update es_orgs set name = trim(p_name), updated_at = now() where id = mine;
  insert into es_meta (org_id, id, data) values (mine, 'org', jsonb_build_object('name', trim(p_name)))
    on conflict (org_id, id) do update set data = jsonb_set(es_meta.data, '{name}', to_jsonb(trim(p_name))), updated_at = now();
  return jsonb_build_object('orgId', mine, 'name', trim(p_name));
end $$;

-- ====================================================================
-- OWNER PANEL — you, across every customer
-- ====================================================================
create or replace function es_owner_orgs()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not es_is_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id, 'name', o.name, 'plan', o.plan, 'expiresOn', o.expires_on,
      'daysLeft', o.expires_on - current_date, 'key', o.license_key, 'note', o.note, 'createdAt', o.created_at,
      'user', (select email from es_users u where u.org_id = o.id order by created_at limit 1),
      'paid', (select coalesce(sum(amount),0) from es_payments p where p.org_id = o.id and p.status = 'paid'))
    order by o.created_at desc) from es_orgs o), '[]'::jsonb);
end $$;

drop function if exists es_owner_set_plan(text,text,date,int,int,numeric,text,text,text);
create or replace function es_owner_set_plan(p_org text, p_plan text, p_expires date,
                                             p_amount numeric default null, p_currency text default 'USD',
                                             p_ref text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not es_is_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  if p_plan not in ('trial','monthly','yearly') then raise exception 'unknown plan %', p_plan; end if;
  if not exists (select 1 from es_orgs where id = p_org) then raise exception 'no such account'; end if;
  perform set_config('es.trusted', 'on', true);
  update es_orgs set plan = p_plan, expires_on = p_expires, note = coalesce(p_note, note),
                     activated_at = now(), updated_at = now() where id = p_org;
  if p_amount is not null and p_amount > 0 then
    insert into es_payments (org_id, provider, provider_ref, status, amount, currency, plan, period_start, period_end, note)
      values (p_org, 'manual', nullif(trim(coalesce(p_ref,'')), ''), 'paid', p_amount, coalesce(p_currency,'USD'),
              p_plan, current_date, p_expires, p_note);
  end if;
  return es_license_of(p_org);
end $$;

-- A payment provider's webhook, running with the service key, calls this
-- once a payment is confirmed. Not callable from a browser.
drop function if exists es_record_payment(text,text,text,numeric,text,text,int,int,date,text,jsonb);
create or replace function es_record_payment(p_org text, p_provider text, p_ref text, p_amount numeric,
                                             p_currency text, p_plan text, p_period_end date, p_email text,
                                             p_raw jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform set_config('es.trusted', 'on', true);
  insert into es_payments (org_id, provider, provider_ref, status, amount, currency, plan, period_start, period_end, payer_email, raw)
    values (p_org, p_provider, p_ref, 'paid', p_amount, p_currency, p_plan, current_date, p_period_end, p_email, coalesce(p_raw,'{}'::jsonb))
    on conflict do nothing;
  update es_orgs set plan = p_plan, expires_on = p_period_end, activated_at = now(), updated_at = now() where id = p_org;
  return es_license_of(p_org);
end $$;

-- functions from the earlier team edition that no longer apply
drop function if exists es_claim_invite(text);
drop function if exists es_delete_project(text);

-- ---------- who may call what ----------
do $do$
declare f text; r text;
begin
  foreach f in array array['es_register_org(text,text)','es_whoami()','es_rename_org(text)','es_activate_key(text)',
      'es_owner_orgs()','es_owner_set_plan(text,text,date,numeric,text,text,text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', f);
    end if;
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke execute on function %s from anon', f);
    end if;
  end loop;
  -- internal functions: never callable from a browser (es_setting reads the licence secret)
  foreach r in array array['anon','authenticated','public'] loop
    if r = 'public' or exists (select 1 from pg_roles where rolname = r) then
      foreach f in array array['es_setting(text)','es_read_key(text)','es_license_of(text)',
          'es_record_payment(text,text,text,numeric,text,text,date,text,jsonb)',
          'es_h32(text)','es_b36(bigint,int)','es_from36(text)'] loop
        execute format('revoke execute on function %s from %s', f, case when r='public' then 'public' else quote_ident(r) end);
      end loop;
    end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function es_record_payment(text,text,text,numeric,text,text,date,text,jsonb) to service_role;
  end if;
end $do$;

-- ============================================================
-- AFTER RUNNING: make yourself the owner (the email you sign in with)
--   insert into es_owners (email) values ('you@yourdomain.com') on conflict do nothing;
-- and set your own licence secret (same string in license-keygen.html)
--   update es_vendor set value = 'YOUR-OWN-SECRET' where key = 'license_secret';
--
-- If you ran the earlier team edition, its es_projects and es_lines tables
-- are no longer used. When you are sure nothing in them is needed:
--   drop table if exists es_lines, es_projects cascade;
-- ============================================================
