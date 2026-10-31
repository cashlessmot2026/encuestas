-- Ejecuta esto en Supabase > SQL Editor (una sola vez), DESPUÉS de migracion-premios-personal-admin.sql.
-- Ruleta por probabilidad + inventario de premios, intentos por celular y reseñas de Varka y Coral Bar.

-- 1) Dinámica de la ruleta y enlaces de reseña
alter table settings
  add column if not exists roulette_win_pct int  not null default 5,   -- probabilidad de ganar por giro (%)
  add column if not exists roulette_tries   int  not null default 1,   -- intentos por celular (en total)
  add column if not exists review_varka_url text not null default 'https://www.tripadvisor.co/UserReviewEdit-g297482-d27474761-Restaurante_Varka_Aquamare_Hotel-San_Andres_Island_San_Andres_and_Providencia_Department.html',
  add column if not exists review_coral_url text not null default 'https://www.tripadvisor.co/UserReviewEdit-g297482-d27094042-Coral_Bar-San_Andres_Island_San_Andres_and_Providencia_Department.html';

-- 2) Premios de la ruleta con su inventario (lo edita el admin en la pestaña Premios)
create table if not exists roulette_prizes (
  id         uuid primary key default gen_random_uuid(),
  label      text not null,
  stock      int  not null default 0 check (stock >= 0),  -- unidades que quedan por entregar
  position   int  not null default 0,
  created_at timestamptz not null default now()
);
alter table roulette_prizes enable row level security;
drop policy if exists "open roulette_prizes" on roulette_prizes;
create policy "open roulette_prizes" on roulette_prizes for all to anon using (true) with check (true);
grant select, insert, update, delete on roulette_prizes to anon;

-- copia los 3 premios que había en Ajustes, con cantidad 0 (pon las cantidades en la pestaña Premios)
insert into roulette_prizes (label, stock, position)
select l, 0, n from settings,
  lateral (values (1, nullif(trim(roulette_prize_1), '')), (2, nullif(trim(roulette_prize_2), '')), (3, nullif(trim(roulette_prize_3), ''))) as v(n, l)
where id = 1 and l is not null and not exists (select 1 from roulette_prizes);

-- 3) Cupones: la tabla prizes ahora solo guarda premios ganados
alter table prizes alter column pct drop not null;
alter table prizes alter column release_at drop not null;
alter table prizes add column if not exists prize_ref uuid;  -- premio de roulette_prizes que se ganó

-- 4) Giros: varios por encuesta si hay más de 1 intento, contados por celular
alter table spins drop constraint if exists spins_pkey;
alter table spins add column if not exists id uuid not null default gen_random_uuid();
alter table spins add primary key (id);
drop index if exists spins_device_day;
create index if not exists spins_device on spins (device);
create index if not exists spins_response on spins (response_id);

-- 5) Gira la ruleta (decide el servidor, no el celular)
create or replace function spin_roulette(p_response uuid, p_device text)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  v_day date := (now() at time zone 'America/Bogota')::date;
  v_tries int; v_used int; v_won boolean;
  rp roulette_prizes%rowtype; v_code text; v_until date;
begin
  select * into s from settings where id = 1;
  if not coalesce(s.roulette_enabled, false) then return json_build_object('error', 'off'); end if;
  if not exists (select 1 from responses where id = p_response and created_at > now() - interval '3 hours') then
    return json_build_object('error', 'invalid');
  end if;

  -- intentos usados por este celular (o por esta encuesta si el celular no tiene id)
  perform pg_advisory_xact_lock(hashtext('spin' || coalesce(p_device, p_response::text)));
  v_tries := greatest(coalesce(s.roulette_tries, 1), 1);
  select count(*), coalesce(bool_or(prize_id is not null), false) into v_used, v_won
    from spins where response_id = p_response or (p_device is not null and device = p_device);
  if v_won or v_used >= v_tries then return json_build_object('error', 'used'); end if;

  if random() * 100 < least(greatest(coalesce(s.roulette_win_pct, 5), 0), 100) then
    select * into rp from roulette_prizes where stock > 0 order by random() limit 1 for update skip locked;
    if found then
      update roulette_prizes set stock = stock - 1 where id = rp.id;
      v_code  := 'AQ' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
      v_until := v_day + coalesce(s.roulette_valid_days, 30);
      insert into prizes (day, label, prize_ref, won_at, response_id, code, valid_until)
      values (v_day, rp.label, rp.id, now(), p_response, v_code, v_until);
      insert into spins (response_id, device, prize_id)
      values (p_response, p_device, (select id from prizes where code = v_code));
      return json_build_object('won', true, 'prize_id', rp.id, 'label', rp.label, 'code', v_code, 'valid_until', v_until, 'left', 0);
    end if;
  end if;

  insert into spins (response_id, device, prize_id) values (p_response, p_device, null);
  return json_build_object('won', false, 'left', v_tries - v_used - 1);
end $$;
grant execute on function spin_roulette(uuid, text) to anon;

notify pgrst, 'reload schema';
