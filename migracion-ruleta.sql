-- Ejecuta esto en Supabase > SQL Editor (una sola vez). TripAdvisor + Ruleta de premios.

alter table settings
  add column if not exists tripadvisor_review_url text    not null default '',
  add column if not exists roulette_enabled       boolean not null default false,
  add column if not exists roulette_start_hour    int     not null default 10,  -- hora (Colombia) en que empieza a repartir
  add column if not exists roulette_end_hour      int     not null default 21,  -- hora en que termina
  add column if not exists roulette_valid_days    int     not null default 30;  -- vigencia del cupón

-- Premios del día: 1 de cada % (2, 5, 10) por día, cada uno con una hora de liberación al azar
create table if not exists prizes (
  id          uuid primary key default gen_random_uuid(),
  day         date not null,
  pct         int  not null check (pct in (2,5,10)),
  release_at  timestamptz not null,
  won_at      timestamptz,
  response_id uuid,
  code        text unique,
  valid_until date,
  redeemed_at timestamptz,
  unique (day, pct)
);

-- Un giro por encuesta y un giro por dispositivo al día
create table if not exists spins (
  response_id uuid primary key,
  device      text,
  day         date not null default ((now() at time zone 'America/Bogota')::date),
  prize_id    uuid references prizes(id),
  created_at  timestamptz not null default now()
);
create unique index if not exists spins_device_day on spins (device, day) where device is not null;

alter table prizes enable row level security;
alter table spins  enable row level security;
drop policy if exists "open prizes" on prizes;
drop policy if exists "open spins"  on spins;
create policy "open prizes" on prizes for all to anon using (true) with check (true);
create policy "open spins"  on spins  for all to anon using (true) with check (true);
grant select, insert, update, delete on prizes, spins to anon;

-- Gira la ruleta (decide el servidor, no el celular)
create or replace function spin_roulette(p_response uuid, p_device text)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  v_day date := (now() at time zone 'America/Bogota')::date;
  v_open timestamptz; v_len numeric; v_pcts int[] := array[2,5,10]; v_tmp int; v_i int; v_j int;
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

  -- crea los 3 premios del día (una sola vez): cada uno en un tramo distinto del horario
  perform pg_advisory_xact_lock(hashtext('prizes' || v_day::text));
  if not exists (select 1 from prizes where day = v_day) then
    v_open := (v_day::timestamp + make_interval(hours => s.roulette_start_hour)) at time zone 'America/Bogota';
    v_len  := greatest(s.roulette_end_hour - s.roulette_start_hour, 3)::numeric / 3;
    for v_i in reverse 3..2 loop  -- baraja el orden de los %
      v_j := 1 + floor(random() * v_i)::int;
      v_tmp := v_pcts[v_i]; v_pcts[v_i] := v_pcts[v_j]; v_pcts[v_j] := v_tmp;
    end loop;
    for v_i in 1..3 loop
      insert into prizes (day, pct, release_at)
      values (v_day, v_pcts[v_i], v_open + make_interval(secs => ((v_i - 1) + random()) * v_len * 3600));
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
    return json_build_object('won', true, 'pct', pz.pct, 'code', pz.code, 'valid_until', pz.valid_until);
  end if;

  insert into spins (response_id, device, prize_id) values (p_response, p_device, null);
  return json_build_object('won', false);
end $$;
grant execute on function spin_roulette(uuid, text) to anon;

notify pgrst, 'reload schema';

-- Enlace de reseña de TripAdvisor de Aquamare Hotel
update settings set tripadvisor_review_url = 'https://www.tripadvisor.es/UserReviewEdit-g297482-d23720352-Aquamare_Hotel-San_Andres_Island_San_Andres_and_Providencia_Department.html' where id = 1;
