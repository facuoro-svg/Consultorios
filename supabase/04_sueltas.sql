-- Cambios: horas sueltas, cada fecha dentro de la anticipación

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
  if p_fecha > ahora::date + coalesce((cfg->'tarifario'->>'anticipacionSuelta')::int, 14) then raise exception 'Las horas sueltas se reservan hasta % días antes. Para todas las semanas, armá tu horario fijo.', coalesce((cfg->'tarifario'->>'anticipacionSuelta')::int, 14); end if;

  precio := coalesce(nullif((pr->>'precioHora')::numeric, 0), nullif((cons->>'precioHora')::numeric, 0), (cfg->'tarifario'->>'hora')::numeric, 0);
  importe := round(round(precio * (1 + coalesce((cfg->'tarifario'->>'recargoSuelta')::numeric, 20) / 100)) * (p_hasta - p_desde) / 60.0);
  pend := _vencido(pid) > 0;

  for i in 0 .. p_semanas - 1 loop
    f := p_fecha + 7 * i;
    w := extract(isodow from f)::int - 1;
    motivo := null;
    if f > ahora::date + coalesce((cfg->'tarifario'->>'anticipacionSuelta')::int, 14) then motivo := 'lejos';
    elsif not coalesce((cfg->'diasAbiertos'->>w)::boolean, w < 6) then motivo := 'cerrado';
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

grant execute on function public.pv_reservar(text, date, int, int, int) to authenticated;
notify pgrst, 'reload schema';
