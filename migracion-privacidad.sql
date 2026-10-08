-- Ejecuta esto en Supabase > SQL Editor (una sola vez). Habeas Data / Ley 1581 de 2012.

alter table settings
  add column if not exists privacy_company text not null default 'Aquamare Hotel',
  add column if not exists privacy_nit     text not null default '',
  add column if not exists privacy_address text not null default '',
  add column if not exists privacy_email   text not null default '',
  add column if not exists privacy_policy  text not null default '',
  add column if not exists privacy_version text not null default '1.0';

-- Prueba de aceptación por cada encuesta (fecha y hora las pone el servidor)
alter table responses
  add column if not exists consent_accepted boolean not null default false,
  add column if not exists consent_at       timestamptz not null default now(),
  add column if not exists policy_version   text;

-- Refresca la caché del API
notify pgrst, 'reload schema';
