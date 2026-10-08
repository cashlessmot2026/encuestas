-- Ejecuta TODO esto en Supabase > SQL Editor > New query > Run

create table if not exists settings (
  id int primary key default 1 check (id = 1),
  business_name text not null default 'Mi Restaurante',
  main_question text not null default '¿Cómo calificas el servicio de tu mesero?',
  rating_scale text not null default 'stars' check (rating_scale in ('stars','ten')),
  google_place_id text not null default '',
  google_review_url text not null default '',
  site_url text not null default '',
  thanks_message text not null default '¡Gracias por tu opinión! Nos ayuda a mejorar cada día.'
);
insert into settings (id) values (1) on conflict do nothing;

create table if not exists waiters (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  full_name text not null,
  cedula text not null,
  nfc_serial text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists questions (
  id uuid primary key default gen_random_uuid(),
  text text not null,
  type text not null check (type in ('rating','yesno','choice','text')),
  options jsonb not null default '[]',
  required boolean not null default false,
  position int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists responses (
  id uuid primary key default gen_random_uuid(),
  waiter_id uuid not null references waiters(id) on delete cascade,
  rating int not null,
  scale int not null check (scale in (5,10)),
  answers jsonb not null default '{}',
  comment text,
  created_at timestamptz not null default now()   -- fecha y hora automáticas (servidor)
);
create index if not exists responses_waiter_idx on responses (waiter_id, created_at desc);
create index if not exists responses_created_idx on responses (created_at desc);

-- Acceso sin login (la app usa la anon key). Ver nota de seguridad en el README.
alter table settings  enable row level security;
alter table waiters   enable row level security;
alter table questions enable row level security;
alter table responses enable row level security;

drop policy if exists "open settings"  on settings;
drop policy if exists "open waiters"   on waiters;
drop policy if exists "open questions" on questions;
drop policy if exists "open responses" on responses;
create policy "open settings"  on settings  for all to anon using (true) with check (true);
create policy "open waiters"   on waiters   for all to anon using (true) with check (true);
create policy "open questions" on questions for all to anon using (true) with check (true);
create policy "open responses" on responses for all to anon using (true) with check (true);

grant usage on schema public to anon;
grant select, insert, update, delete on settings, waiters, questions, responses to anon;
