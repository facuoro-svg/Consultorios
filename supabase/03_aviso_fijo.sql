-- Cambios: aviso de 15 días para liberar días del horario fijo

create or replace function public.pv_cancelar(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pid text := mi_prof();
  ahora timestamp := now() at time zone 'America/Argentina/Buenos_Aires';
  horas int; aviso int; d jsonb; sid text; f text; inicio timestamp; tarde boolean;
begin
  if pid is null then raise exception 'No tenés acceso como profesional'; end if;
  select coalesce((data->>'horasCancelacion')::int, 24) into horas from docs where col = 'config' and id = 'main';
  horas := coalesce(horas, 24);
  select coalesce((data->>'diasAvisoFijo')::int, 15) into aviso from docs where col = 'config' and id = 'main';
  aviso := coalesce(aviso, 15);
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
    if f::date - ahora::date < aviso then raise exception 'Los días del horario fijo se liberan con al menos % días de aviso', aviso; end if;
    tarde := false;
    update docs set data = jsonb_set(data, '{excepciones}', coalesce(data->'excepciones', '{}'::jsonb) || jsonb_build_object(f, jsonb_build_object('tarde', tarde, 'en', now(), 'por', 'profesional'))), updated_at = now()
     where col = 'series' and id = sid;
    return jsonb_build_object('tarde', tarde);
  end if;
  raise exception 'Clave inválida';
end $$;

notify pgrst, 'reload schema';
