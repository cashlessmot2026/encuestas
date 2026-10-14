-- Ejecuta esto en Supabase > SQL Editor (una sola vez). Porcentajes de la ruleta editables.
-- Despues de correr migracion-ruleta.sql.

alter table settings
  add column if not exists roulette_pct_1 int not null default 10,
  add column if not exists roulette_pct_2 int not null default 5,
  add column if not exists roulette_pct_3 int not null default 2;

-- Los premios ya no estan limitados a 2/5/10 y pueden repetirse
alter table prizes drop constraint if exists prizes_pct_check;
alter table prizes drop constraint if exists prizes_day_pct_key;
alter table prizes add constraint prizes_pct_check check (pct between 1 and 100);

create or replace function spin_roulette(p_response uuid, p_device text)
returns json language plpgsql security definer set search_path = public as $$
declare
  s settings%rowtype;
  v_day date := (now() at time zone 'America/Bogota')::date;
  v_open timestamptz; v_len numeric; v_pcts int[]; v_tmp int; v_i int; v_j int;
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

  perform pg_advisory_xact_lock(hashtext('prizes' || v_day::text));
  if not exists (select 1 from prizes where day = v_day) then
    v_open := (v_day::timestamp + make_interval(hours => s.roulette_start_hour)) at time zone 'America/Bogota';
    v_len  := greatest(s.roulette_end_hour - s.roulette_start_hour, 3)::numeric / 3;
    for v_i in reverse 3..2 loop
      v_j := 1 + floor(random() * v_i)::int;
      v_tmp := v_pcts[v_i]; v_pcts[v_i] := v_pcts[v_j]; v_pcts[v_j] := v_tmp;
    end loop;
    for v_i in 1..3 loop
      insert into prizes (day, pct, release_at)
      values (v_day, v_pcts[v_i], v_open + make_interval(secs => ((v_i - 1) + random()) * v_len * 3600));
    end loop;
  end if;

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
