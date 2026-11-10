-- Consultorios · esquema inicial
-- Pegar entero en Supabase › SQL Editor › New query › Run. Se puede correr más de una vez.

-- ------------------------------------------------------------------
-- Tablas
-- ------------------------------------------------------------------
create table if not exists public.docs (
  col        text not null,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  prof_id    text generated always as (data->>'profesionalId') stored,
  updated_at timestamptz not null default now(),
  primary key (col, id)
);
create index if not exists docs_prof_idx on public.docs (col, prof_id);
create index if not exists docs_fecha_idx on public.docs (col, (data->>'fecha'));

create table if not exists public.miembros (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email   text not null,
  rol     text not null check (rol in ('dueno', 'profesional')),
  prof_id text,
  creado  timestamptz not null default now()
);

create table if not exists public.invitaciones_dueno (
  email  text primary key,
  creado timestamptz not null default now()
);
alter table public.invitaciones_dueno enable row level security;

alter table public.docs replica identity full;

-- ------------------------------------------------------------------
-- Funciones de permisos
-- ------------------------------------------------------------------
create or replace function public.es_dueno() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from miembros where user_id = auth.uid() and rol = 'dueno');
$$;

create or replace function public.mi_prof() returns text
language sql stable security definer set search_path = public as $$
  select prof_id from miembros where user_id = auth.uid() and rol = 'profesional';
$$;

-- ------------------------------------------------------------------
-- Seguridad por fila
-- ------------------------------------------------------------------
alter table public.docs enable row level security;
alter table public.miembros enable row level security;

drop policy if exists docs_dueno on public.docs;
create policy docs_dueno on public.docs for all to authenticated
  using (es_dueno()) with check (es_dueno());

drop policy if exists docs_prof_lee on public.docs;
create policy docs_prof_lee on public.docs for select to authenticated using (
  mi_prof() is not null and (
    col in ('consultorios', 'config')
    or (col = 'profesionales' and id = mi_prof())
    or (col in ('series', 'ocupaciones', 'movimientos', 'avisos') and prof_id = mi_prof())
  )
);

drop policy if exists docs_prof_aviso on public.docs;
create policy docs_prof_aviso on public.docs for insert to authenticated with check (
  col = 'avisos' and prof_id = mi_prof() and data->>'estado' = 'pendiente'
);

drop policy if exists miembros_lee on public.miembros;
create policy miembros_lee on public.miembros for select to authenticated
  using (user_id = auth.uid() or es_dueno());

drop policy if exists miembros_dueno on public.miembros;
create policy miembros_dueno on public.miembros for delete to authenticated using (es_dueno());

-- ------------------------------------------------------------------
-- Al entrar: quién soy
--   · el primer usuario que entra queda como dueño
--   · después, si el mail coincide con el de un profesional activo, entra como profesional
-- ------------------------------------------------------------------
create or replace function public.vincular() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u uuid := auth.uid();
  mail text := lower(coalesce(auth.jwt()->>'email', ''));
  m miembros;
  pid text;
begin
  if u is null then return jsonb_build_object('rol', null); end if;
  select * into m from miembros where user_id = u;
  if found then
    if m.rol = 'profesional' and not exists (
      select 1 from docs where col = 'profesionales' and id = m.prof_id and coalesce((data->>'activo')::boolean, true)
    ) then
      delete from miembros where user_id = u;
      return jsonb_build_object('rol', null, 'email', mail);
    end if;
    return jsonb_build_object('rol', m.rol, 'prof_id', m.prof_id, 'email', mail);
  end if;
  if not exists (select 1 from miembros where rol = 'dueno') then
    insert into miembros (user_id, email, rol) values (u, mail, 'dueno');
    return jsonb_build_object('rol', 'dueno', 'email', mail);
  end if;
  if exists (select 1 from invitaciones_dueno where email = mail) then
    insert into miembros (user_id, email, rol) values (u, mail, 'dueno');
    delete from invitaciones_dueno where email = mail;
    return jsonb_build_object('rol', 'dueno', 'email', mail);
  end if;
  select id into pid from docs
   where col = 'profesionales' and lower(trim(data->>'email')) = mail
     and coalesce((data->>'activo')::boolean, true)
   limit 1;
  if pid is not null then
    insert into miembros (user_id, email, rol, prof_id) values (u, mail, 'profesional', pid);
    return jsonb_build_object('rol', 'profesional', 'prof_id', pid, 'email', mail);
  end if;
  return jsonb_build_object('rol', null, 'email', mail);
end $$;

-- Un dueño suma a otro dueño (socio) por mail. Si todavía no entró, queda invitado.
create or replace function public.hacer_dueno(mail text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not es_dueno() then raise exception 'solo dueños'; end if;
  update miembros set rol = 'dueno', prof_id = null where lower(email) = lower(trim(mail));
  if found then return true; end if;
  insert into invitaciones_dueno (email) values (lower(trim(mail))) on conflict do nothing;
  return false;
end $$;

-- ------------------------------------------------------------------
-- Agenda anónima: lo que está ocupado, sin nombres ni importes
-- ------------------------------------------------------------------
create or replace function public.agenda_ocupada() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'series', coalesce((select jsonb_agg(jsonb_build_object(
        'id', 'x' || md5(id), 'consultorioId', data->'consultorioId', 'dia', data->'dia', 'desde', data->'desde', 'hasta', data->'hasta',
        'inicio', data->'inicio', 'fin', data->'fin', 'excepciones', coalesce(data->'excepciones', '{}'::jsonb), 'tipo', 'otro', 'profesionalId', 'otro'))
      from docs where col = 'series' and prof_id is distinct from mi_prof()), '[]'::jsonb),
    'ocupaciones', coalesce((select jsonb_agg(jsonb_build_object(
        'id', 'x' || md5(id), 'consultorioId', data->'consultorioId', 'fecha', data->'fecha', 'desde', data->'desde', 'hasta', data->'hasta',
        'estado', data->'estado', 'tipo', 'otro', 'profesionalId', 'otro'))
      from docs where col = 'ocupaciones' and prof_id is distinct from mi_prof()
        and data->>'estado' <> 'cancelada' and data->>'fecha' >= to_char((now() at time zone 'America/Argentina/Buenos_Aires')::date - 1, 'YYYY-MM-DD')), '[]'::jsonb)
  ) where mi_prof() is not null or es_dueno();
$$;

-- ------------------------------------------------------------------
-- Helpers de agenda (minutos desde 00:00)
-- ------------------------------------------------------------------
create or replace function public._hm(t text) returns int language sql immutable as $$
  select split_part(t, ':', 1)::int * 60 + split_part(t, ':', 2)::int;
$$;

create or replace function public._choca(p_cons text, p_fecha date, p_desde int, p_hasta int, p_prof text) returns boolean
language sql stable security definer set search_path = public as $$
  with f as (select to_char(p_fecha, 'YYYY-MM-DD') as d, (extract(isodow from p_fecha)::int - 1) as w)
  select exists (
    select 1 from docs, f where col = 'ocupaciones' and data->>'fecha' = f.d and data->>'estado' <> 'cancelada'
      and ((data->>'consultorioId') = p_cons or (p_prof is not null and prof_id = p_prof))
      and (data->>'desde')::int < p_hasta and p_desde < (data->>'hasta')::int
  ) or exists (
    select 1 from docs, f where col = 'series' and (data->>'dia')::int = f.w
      and data->>'inicio' <= f.d and (data->>'fin' is null or data->>'fin' = '' or f.d <= data->>'fin')
      and not coalesce(data->'excepciones', '{}'::jsonb) ? f.d
      and ((data->>'consultorioId') = p_cons or (p_prof is not null and prof_id = p_prof))
      and (data->>'desde')::int < p_hasta and p_desde < (data->>'hasta')::int
  );
$$;

-- Deuda vencida (pagos aplicados a los cargos más viejos primero)
create or replace function public._vencido(p_prof text) returns numeric
language sql stable security definer set search_path = public as $$
  with cfg as (select coalesce((data->>'diasGracia')::int, 5) g from docs where col = 'config' and id = 'main'),
  hoy as (select (now() at time zone 'America/Argentina/Buenos_Aires')::date d),
  pagos as (select coalesce(sum((data->>'importe')::numeric), 0) t from docs where col = 'movimientos' and prof_id = p_prof and data->>'tipo' in ('pago', 'credito')),
  cargos as (
    select (data->>'importe')::numeric imp,
           coalesce(nullif(data->>'vence', '')::date, (data->>'fecha')::date + coalesce((select g from cfg), 5)) vence,
           sum((data->>'importe')::numeric) over (order by data->>'fecha', id) acum
      from docs where col = 'movimientos' and prof_id = p_prof and data->>'tipo' = 'cargo'
        and (data->>'fecha')::date <= (select d from hoy)
  )
  select coalesce(sum(greatest(0, least(imp, acum - (select t from pagos)))), 0)
    from cargos where vence < (select d from hoy);
$$;

-- ------------------------------------------------------------------
-- El profesional reserva
-- ------------------------------------------------------------------
drop function if exists public.pv_reservar(text, date, int, int);
create or replace function public.pv_reservar(p_cons text, p_fecha date, p_desde int, p_hasta int, p_semanas int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid text := mi_prof();
  cfg jsonb; cons jsonb; pr jsonb;
  ahora timestamp := now() at time zone 'America/Argentina/Buenos_Aires';
  precio numeric; importe numeric; pend boolean; oid text;
  f date; w int; i int; creadas jsonb := '[]'::jsonb; salteadas jsonb := '[]'::jsonb; motivo text;
begin
  if pid is null then raise exception 'No tenés acceso como profesional'; end if;
  if p_semanas is null or p_semanas < 1 or p_semanas > 26 then raise exception 'Se puede repetir hasta 26 semanas'; end if;
  select data into cfg from docs where col = 'config' and id = 'main';
  select data into cons from docs where col = 'consultorios' and id = p_cons;
  select data into pr from docs where col = 'profesionales' and id = pid;
  if cons is null or coalesce((cons->>'activo')::boolean, true) = false then raise exception 'Ese consultorio no está disponible'; end if;
  if p_hasta <= p_desde or (p_hasta - p_desde) > 720 then raise exception 'Horario inválido'; end if;
  if p_desde < _hm(coalesce(cfg->>'abre', '08:00')) or p_hasta > _hm(coalesce(cfg->>'cierra', '21:00')) then raise exception 'Fuera del horario de atención'; end if;
  if p_fecha + make_interval(mins => p_desde) < ahora then raise exception 'Ese horario ya pasó'; end if;
  if p_fecha > ahora::date + 60 then raise exception 'La primera fecha puede ser hasta 60 días adelante'; end if;

  precio := coalesce(nullif((pr->>'precioHora')::numeric, 0), nullif((cons->>'precioHora')::numeric, 0), (cfg->'tarifario'->>'hora')::numeric, 0);
  importe := round(precio * (p_hasta - p_desde) / 60.0);
  pend := _vencido(pid) > 0;

  for i in 0 .. p_semanas - 1 loop
    f := p_fecha + 7 * i;
    w := extract(isodow from f)::int - 1;
    motivo := null;
    if not coalesce((cfg->'diasAbiertos'->>w)::boolean, w < 6) then motivo := 'cerrado';
    elsif _choca(p_cons, f, p_desde, p_hasta, pid) then motivo := 'ocupado';
    end if;
    if motivo is not null then
      if p_semanas = 1 then raise exception '%', case motivo when 'cerrado' then 'Ese día está cerrado' else 'Ese horario ya está ocupado' end; end if;
      salteadas := salteadas || to_jsonb(to_char(f, 'YYYY-MM-DD'));
      continue;
    end if;
    oid := gen_random_uuid()::text;
    insert into docs (col, id, data) values ('ocupaciones', oid, jsonb_build_object(
      'consultorioId', p_cons, 'profesionalId', pid, 'tipo', 'reserva', 'fecha', to_char(f, 'YYYY-MM-DD'),
      'desde', p_desde, 'hasta', p_hasta, 'estado', case when pend then 'pendiente' else 'confirmada' end,
      'importe', importe, 'nota', '', 'origen', 'portal', 'creado', now()));
    if not pend and importe > 0 then
      insert into docs (col, id, data) values ('movimientos', 'res-' || oid, jsonb_build_object(
        'profesionalId', pid, 'tipo', 'cargo', 'importe', importe, 'fecha', to_char(f, 'YYYY-MM-DD'), 'ref', oid,
        'concepto', 'Reserva ' || coalesce(cons->>'nombre', '') || ' ' || to_char(f, 'DD/MM') || ' ' ||
          lpad((p_desde / 60)::text, 2, '0') || ':' || lpad((p_desde % 60)::text, 2, '0') || '–' ||
          lpad((p_hasta / 60)::text, 2, '0') || ':' || lpad((p_hasta % 60)::text, 2, '0')));
    end if;
    creadas := creadas || to_jsonb(oid);
  end loop;
  if jsonb_array_length(creadas) = 0 then raise exception 'Todas esas fechas están ocupadas o cerradas'; end if;
  return jsonb_build_object('id', creadas->>0, 'creadas', jsonb_array_length(creadas), 'salteadas', salteadas,
    'estado', case when pend then 'pendiente' else 'confirmada' end, 'importe', importe);
end $$;

-- ------------------------------------------------------------------
-- El profesional cancela (reserva suelta o un día de su horario fijo)
-- ------------------------------------------------------------------
create or replace function public.pv_cancelar(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid text := mi_prof();
  ahora timestamp := now() at time zone 'America/Argentina/Buenos_Aires';
  horas int; d jsonb; sid text; f text; inicio timestamp; tarde boolean;
begin
  if pid is null then raise exception 'No tenés acceso como profesional'; end if;
  select coalesce((data->>'horasCancelacion')::int, 24) into horas from docs where col = 'config' and id = 'main';
  horas := coalesce(horas, 24);
  if p_key like 'o:%' then
    select data into d from docs where col = 'ocupaciones' and id = substr(p_key, 3) and prof_id = pid;
    if d is null then raise exception 'No encontré esa reserva'; end if;
    inicio := (d->>'fecha')::date + make_interval(mins => (d->>'desde')::int);
    if inicio <= ahora then raise exception 'Ya empezó o pasó'; end if;
    tarde := inicio - ahora < make_interval(hours => horas) and d->>'estado' <> 'pendiente';
    update docs set data = data || jsonb_build_object('estado', 'cancelada', 'tarde', tarde, 'canceladaEn', now()), updated_at = now()
     where col = 'ocupaciones' and id = substr(p_key, 3);
    if not tarde then delete from docs where col = 'movimientos' and id = 'res-' || substr(p_key, 3); end if;
    return jsonb_build_object('tarde', tarde);
  elsif p_key like 's:%' then
    sid := split_part(p_key, ':', 2); f := split_part(p_key, ':', 3);
    select data into d from docs where col = 'series' and id = sid and prof_id = pid;
    if d is null then raise exception 'No encontré ese horario'; end if;
    inicio := f::date + make_interval(mins => (d->>'desde')::int);
    if inicio <= ahora then raise exception 'Ya empezó o pasó'; end if;
    tarde := inicio - ahora < make_interval(hours => horas);
    update docs set data = jsonb_set(data, '{excepciones}', coalesce(data->'excepciones', '{}'::jsonb) || jsonb_build_object(f, jsonb_build_object('tarde', tarde, 'en', now(), 'por', 'profesional'))), updated_at = now()
     where col = 'series' and id = sid;
    return jsonb_build_object('tarde', tarde);
  end if;
  raise exception 'Clave inválida';
end $$;

-- ------------------------------------------------------------------
-- Permisos de ejecución
-- ------------------------------------------------------------------
revoke all on function public._choca(text, date, int, int, text) from public, anon, authenticated;
revoke all on function public._vencido(text) from public, anon, authenticated;
grant execute on function public.vincular() to authenticated;
grant execute on function public.hacer_dueno(text) to authenticated;
grant execute on function public.agenda_ocupada() to authenticated;
grant execute on function public.pv_reservar(text, date, int, int, int) to authenticated;
grant execute on function public.pv_cancelar(text) to authenticated;

-- Tiempo real
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;
