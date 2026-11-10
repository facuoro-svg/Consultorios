-- Cambios: contratos por módulo, repartidos en bloques de 2 h o más

drop function if exists public.pv_contratar(jsonb, date, int);
create or replace function public.pv_contratar(p_franjas jsonb, p_inicio date, p_plazo int, p_modulo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid text := mi_prof(); cfg jsonb; cons jsonb; fr jsonb; fr2 jsonb; f date; fin date; horas numeric := 0;
  hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  cid text := gen_random_uuid()::text; sid text; sids jsonb := '[]'::jsonb; limpias jsonb := '[]'::jsonb;
  d int; a int; z int; pend boolean; n int; i int; j int; modulo jsonb; precio numeric;
begin
  if pid is null then raise exception 'No tenés acceso como profesional'; end if;
  if p_plazo not in (1, 3, 6, 12) then raise exception 'Plazo inválido'; end if;
  if p_inicio < hoy or p_inicio > hoy + 60 then raise exception 'El contrato tiene que empezar dentro de los próximos 60 días'; end if;
  n := jsonb_array_length(coalesce(p_franjas, '[]'::jsonb));
  if n < 1 or n > 14 then raise exception 'Elegí entre 1 y 14 horarios por semana'; end if;
  select data into cfg from docs where col = 'config' and id = 'main';
  fin := (p_inicio + make_interval(months => p_plazo))::date - 1;
  for i in 0 .. n - 1 loop
    fr := p_franjas->i; d := (fr->>'dia')::int; a := (fr->>'desde')::int; z := (fr->>'hasta')::int;
    select data into cons from docs where col = 'consultorios' and id = fr->>'consultorioId';
    if cons is null or coalesce((cons->>'activo')::boolean, true) = false then raise exception 'Consultorio no disponible'; end if;
    if d < 0 or d > 6 or z <= a or z - a > 720 then raise exception 'Horario inválido'; end if;
    if z - a < 120 then raise exception 'Cada bloque tiene que ser de al menos 2 horas'; end if;
    if not coalesce((cfg->'diasAbiertos'->>d)::boolean, d < 6) then raise exception 'Ese día está cerrado'; end if;
    if a < _hm(coalesce(cfg->>'abre', '08:00')) or z > _hm(coalesce(cfg->>'cierra', '21:00')) then raise exception 'Fuera del horario de atención'; end if;
    for j in 0 .. i - 1 loop
      fr2 := p_franjas->j;
      if (fr2->>'dia')::int = d and (fr2->>'desde')::int < z and a < (fr2->>'hasta')::int then raise exception 'Elegiste dos horarios que se superponen'; end if;
    end loop;
    f := p_inicio + ((d - (extract(isodow from p_inicio)::int - 1) + 7) % 7);
    while f <= fin loop
      if _choca(fr->>'consultorioId', f, a, z, pid) then raise exception 'El % ese horario ya está tomado. Elegí otro.', to_char(f, 'DD/MM'); end if;
      f := f + 7;
    end loop;
    horas := horas + (z - a) / 60.0;
    limpias := limpias || jsonb_build_object('consultorioId', fr->>'consultorioId', 'dia', d, 'desde', a, 'hasta', z);
  end loop;
  if p_modulo is not null then
    select m into modulo from jsonb_array_elements(coalesce(cfg->'tarifario'->'modulos', '[]'::jsonb)) m where m->>'id' = p_modulo;
    if modulo is null then raise exception 'Ese módulo ya no existe'; end if;
    if round(horas * 60) <> round((modulo->>'horas')::numeric * 60) then raise exception 'Tenés que completar las % horas del módulo', modulo->>'horas'; end if;
    precio := (modulo->>'precio')::numeric;
  else
    precio := _precio_semanal(horas);
  end if;
  pend := _vencido(pid) > 0;
  for i in 0 .. n - 1 loop
    fr := limpias->i; sid := gen_random_uuid()::text; sids := sids || to_jsonb(sid);
    insert into docs (col, id, data) values ('series', sid, jsonb_build_object(
      'consultorioId', fr->'consultorioId', 'profesionalId', pid, 'dia', fr->'dia', 'desde', fr->'desde', 'hasta', fr->'hasta',
      'inicio', to_char(p_inicio, 'YYYY-MM-DD'), 'fin', to_char(fin, 'YYYY-MM-DD'), 'tipo', 'contrato', 'contratoId', cid, 'nota', '')
      || case when pend then '{"estado":"pendiente"}'::jsonb else '{}'::jsonb end);
  end loop;
  insert into docs (col, id, data) values ('contratos', cid, jsonb_build_object(
    'profesionalId', pid, 'franjas', limpias, 'plazo', p_plazo, 'mesesTotal', p_plazo, 'inicio', to_char(p_inicio, 'YYYY-MM-DD'), 'fin', to_char(fin, 'YYYY-MM-DD'),
    'precio', precio, 'moduloId', p_modulo, 'ajustePct', coalesce((cfg->'tarifario'->>'ajustePct')::numeric, 10),
    'estado', case when pend then 'pendiente' else 'activo' end, 'seriesIds', sids, 'origen', 'portal', 'creado', now()));
  return jsonb_build_object('id', cid, 'estado', case when pend then 'pendiente' else 'activo' end);
end $$;

grant execute on function public.pv_contratar(jsonb, date, int, text) to authenticated;
notify pgrst, 'reload schema';
