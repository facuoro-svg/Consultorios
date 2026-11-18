-- Cambios: el mes se cuenta como 4 semanas (un módulo de 4 h por semana = 16 h al mes)

create or replace function public._precio_semanal(p_horas numeric) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  cfg jsonb; hh int := round(p_horas * 2); media numeric; best numeric[] := array[0::numeric]; h int; b numeric; m jsonb; mh int;
begin
  select data into cfg from docs where col = 'config' and id = 'main';
  media := coalesce((cfg->'tarifario'->>'hora')::numeric, 0) * 0.5 * 4;
  for h in 1 .. hh loop
    b := best[h] + media;
    for m in select * from jsonb_array_elements(coalesce(cfg->'tarifario'->'modulos', '[]'::jsonb)) loop
      if coalesce((m->>'horas')::numeric, 0) > 0 and coalesce((m->>'precio')::numeric, 0) > 0 then
        mh := round((m->>'horas')::numeric * 2);
        b := least(b, best[greatest(0, h - mh) + 1] + (m->>'precio')::numeric);
      end if;
    end loop;
    best := best || b;
  end loop;
  return round(best[hh + 1] / 100) * 100;
end $$;

revoke all on function public._precio_semanal(numeric) from public, anon, authenticated;
notify pgrst, 'reload schema';
