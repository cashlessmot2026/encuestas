-- Ejecuta esto en Supabase > SQL Editor (una sola vez), DESPUÉS de migracion-ruleta.sql.
-- Premios escritos a mano, cargos del personal (bartender, etc.) y acceso de administrador.

-- 1) Premios con texto libre (comida, platos, bebidas, % de descuento…)
alter table settings
  add column if not exists roulette_pct_1   int  not null default 10,
  add column if not exists roulette_pct_2   int  not null default 5,
  add column if not exists roulette_pct_3   int  not null default 2,
  add column if not exists roulette_prize_1 text not null default '',
  add column if not exists roulette_prize_2 text not null default '',
  add column if not exists roulette_prize_3 text not null default '';
alter table prizes drop constraint if exists prizes_pct_check;
alter table prizes drop constraint if exists prizes_day_pct_key;
alter table prizes add constraint prizes_pct_check check (pct between 1 and 100);
alter table prizes
  add column if not exists slot  int,   -- casilla de la ruleta (1, 2 o 3)
  add column if not exists label text;  -- texto del premio, p. ej. «Postre gratis»

-- 2) Cargo del personal
alter table waiters add column if not exists role text not null default 'Mesero';

-- 3) Acceso de administrador (usuario: admin / contraseña: 1234, se cambia desde Ajustes)
create extension if not exists pgcrypto with schema extensions;
create table if not exists admin_auth (
  id        int primary key default 1 check (id = 1),
  username  text not null,
  pass_hash text not null
);
alter table admin_auth enable row level security;  -- sin políticas: nadie la lee desde la app
revoke all on admin_auth from anon, authenticated;
insert into admin_auth (id, username, pass_hash)
values (1, 'admin', extensions.crypt('1234', extensions.gen_salt('bf'))) on conflict do nothing;

create or replace function admin_login(p_user text, p_pass text)
returns boolean language sql security definer set search_path = public, extensions as $$
  select exists (select 1 from admin_auth
                  where id = 1 and lower(username) = lower(trim(p_user)) and pass_hash = crypt(p_pass, pass_hash));
$$;

-- Cambia usuario y/o contraseña (p_new_pass vacío = conservar la actual)
create or replace function admin_change(p_user text, p_pass text, p_new_user text, p_new_pass text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  if not admin_login(p_user, p_pass) then return false; end if;
  if coalesce(trim(p_new_user), '') = '' then raise exception 'El usuario no puede estar vacío'; end if;
  if coalesce(p_new_pass, '') <> '' and length(p_new_pass) < 4 then raise exception 'La contraseña debe tener al menos 4 caracteres'; end if;
  update admin_auth set username = trim(p_new_user),
         pass_hash = case when coalesce(p_new_pass, '') = '' then pass_hash else crypt(p_new_pass, gen_salt('bf')) end
   where id = 1;
  return true;
end $$;
grant execute on function admin_login(text, text), admin_change(text, text, text, text) to anon;

-- 4) La ruleta reparte los premios escritos en Ajustes
create or replace function spin_roulette(p_response uuid, p_device text)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  v_day date := (now() at time zone 'America/Bogota')::date;
  v_open timestamptz; v_len numeric; v_slots int[] := array[1,2,3]; v_pcts int[]; v_labels text[];
  v_tmp int; v_i int; v_j int; v_k int;
  pz prizes%rowtype; v_code text;
begin
  select * into s from settings where id = 1;
  if not coalesce(s.roulette_enabled, false) then return json_build_object('error', 'off'); end if;
  if not exists (select 1 from responses where id = p_response and created_at > now() - interval '60 minutes') then
    return json_build_object('error', 'invalid');
  end if;
  if exists (select 1 from spins where response_id = p_response) then return json_build_object('error', 'already'); end if;
  if p_device is not null and exists (select 1 from spins where device = p_device and day = v_day) then
    return json_build_object('error', 'device');
  end if;

  v_pcts := array[
    least(greatest(coalesce(s.roulette_pct_1, 10), 1), 100),
    least(greatest(coalesce(s.roulette_pct_2, 5), 1), 100),
    least(greatest(coalesce(s.roulette_pct_3, 2), 1), 100)];
  v_labels := array[
    coalesce(nullif(trim(s.roulette_prize_1), ''), v_pcts[1] || '% de descuento'),
    coalesce(nullif(trim(s.roulette_prize_2), ''), v_pcts[2] || '% de descuento'),
    coalesce(nullif(trim(s.roulette_prize_3), ''), v_pcts[3] || '% de descuento')];

  -- crea los 3 premios del día (una sola vez): cada uno en un tramo distinto del horario
  perform pg_advisory_xact_lock(hashtext('prizes' || v_day::text));
  if not exists (select 1 from prizes where day = v_day) then
    v_open := (v_day::timestamp + make_interval(hours => s.roulette_start_hour)) at time zone 'America/Bogota';
    v_len  := greatest(s.roulette_end_hour - s.roulette_start_hour, 3)::numeric / 3;
    for v_i in reverse 3..2 loop  -- baraja el orden de las casillas
      v_j := 1 + floor(random() * v_i)::int;
      v_tmp := v_slots[v_i]; v_slots[v_i] := v_slots[v_j]; v_slots[v_j] := v_tmp;
    end loop;
    for v_i in 1..3 loop
      v_k := v_slots[v_i];
      insert into prizes (day, pct, slot, label, release_at)
      values (v_day, v_pcts[v_k], v_k, v_labels[v_k], v_open + make_interval(secs => ((v_i - 1) + random()) * v_len * 3600));
    end loop;
  end if;

  -- entrega el premio ya liberado más antiguo que nadie haya ganado
  select * into pz from prizes
   where day = v_day and won_at is null and release_at <= now()
   order by release_at limit 1 for update skip locked;

  if found then
    v_code := 'AQ' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    update prizes set won_at = now(), response_id = p_response, code = v_code,
           valid_until = v_day + s.roulette_valid_days
     where id = pz.id returning * into pz;
    insert into spins (response_id, device, prize_id) values (p_response, p_device, pz.id);
    return json_build_object('won', true, 'pct', pz.pct, 'slot', pz.slot,
                             'label', coalesce(pz.label, pz.pct || '% de descuento'),
                             'code', pz.code, 'valid_until', pz.valid_until);
  end if;

  insert into spins (response_id, device, prize_id) values (p_response, p_device, null);
  return json_build_object('won', false);
end $$;
grant execute on function spin_roulette(uuid, text) to anon;

notify pgrst, 'reload schema';
