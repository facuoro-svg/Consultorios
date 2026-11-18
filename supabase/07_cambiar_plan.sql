-- Cambios: el profesional puede cambiar su plan (más o menos horas, otro módulo).
-- El contrato actual termina el día anterior al 1° del mes elegido y empieza uno nuevo, todo junto.

create or replace function public.pv_cambiar(p_id text, p_franjas jsonb, p_inicio date, p_plazo int, p_modulo text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid text := mi_prof(); c jsonb; ultimo date; r jsonb;
  hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if pid is null then raise exception 'No tenés acceso como profesional'; end if;
  select data into c from docs where col = 'contratos' and id = p_id and prof_id = pid;
  if c is null or c->>'estado' <> 'activo' or (c->>'fin')::date < hoy then raise exception 'No encontré ese contrato vigente'; end if;
  if p_inicio <= hoy or extract(day from p_inicio) <> 1 then raise exception 'El cambio de plan empieza el 1° de un mes que todavía no empezó'; end if;
  if p_inicio > (c->>'fin')::date + 1 then raise exception 'Tu contrato termina antes: renovalo o armá uno nuevo'; end if;
  if _vencido(pid) > 0 then raise exception 'Tenés deuda vencida: pedile al dueño el cambio de plan'; end if;
  ultimo := p_inicio - 1;
  update docs set data = data || jsonb_build_object('fin', to_char(ultimo, 'YYYY-MM-DD'), 'terminado', to_char(hoy, 'YYYY-MM-DD'),
      'estado', case when ultimo < (c->>'inicio')::date then 'cancelado' else 'activo' end), updated_at = now()
   where col = 'contratos' and id = p_id;
  update docs set data = data || jsonb_build_object('fin', to_char(ultimo, 'YYYY-MM-DD')), updated_at = now()
   where col = 'series' and data->>'contratoId' = p_id;
  r := pv_contratar(p_franjas, p_inicio, p_plazo, p_modulo);
  update docs set data = data || jsonb_build_object('reemplaza', p_id), updated_at = now()
   where col = 'contratos' and id = r->>'id';
  return r;
end $$;

grant execute on function public.pv_cambiar(text, jsonb, date, int, text) to authenticated;
notify pgrst, 'reload schema';
