-- =====================================================================
-- MANTENIMIENTO — Fase 4: vistas de métricas para gerencia.
--
-- Tiempos de respuesta/resolución (desde los sellos), gasto en repuestos por
-- mes y categoría, y carga de tickets activos por prioridad. Cálculo en vivo en
-- SQL; el dashboard solo pinta.
-- =====================================================================

-- ---------- KPIs globales (una fila) ----------
create or replace view public.v_mt_kpis as
select
  count(*)                                                  as total_tickets,
  count(*) filter (where status in ('open','assigned','in_progress')) as activos,
  count(*) filter (where kind = 'preventive')              as preventivos,
  -- horas promedio: reportado -> primera atención (started_at)
  round(avg(extract(epoch from (started_at - reported_at)) / 3600.0)
        filter (where started_at is not null)::numeric, 1) as horas_respuesta_prom,
  -- horas promedio: reportado -> resuelto
  round(avg(extract(epoch from (resolved_at - reported_at)) / 3600.0)
        filter (where resolved_at is not null)::numeric, 1) as horas_resolucion_prom
from public.maintenance_tickets;

-- ---------- Tiempos por mes (de tickets con resolución) ----------
create or replace view public.v_mt_response_by_month as
select
  to_char(reported_at, 'YYYY-MM')                          as month,
  count(*) filter (where resolved_at is not null)          as resueltos,
  round(avg(extract(epoch from (started_at - reported_at)) / 3600.0)
        filter (where started_at is not null)::numeric, 1) as horas_respuesta,
  round(avg(extract(epoch from (resolved_at - reported_at)) / 3600.0)
        filter (where resolved_at is not null)::numeric, 1) as horas_resolucion
from public.maintenance_tickets
group by 1
order by 1;

-- ---------- Gasto en repuestos por mes ----------
create or replace view public.v_mt_spend_by_month as
select
  to_char(t.reported_at, 'YYYY-MM')  as month,
  round(sum(p.line_total_bs))        as gasto_bs
from public.maintenance_ticket_parts p
join public.maintenance_tickets t on t.id = p.ticket_id
group by 1
order by 1;

-- ---------- Tickets y gasto por categoría ----------
create or replace view public.v_mt_by_category as
select
  c.label                                     as categoria,
  count(distinct t.id)                        as tickets,
  coalesce(round(sum(p.line_total_bs)), 0)    as gasto_bs
from public.maintenance_tickets t
join public.maintenance_categories c on c.code = t.category
left join public.maintenance_ticket_parts p on p.ticket_id = t.id
group by 1
order by tickets desc;

-- ---------- Tickets activos por prioridad ----------
create or replace view public.v_mt_active_by_priority as
select
  priority,
  count(*) as tickets
from public.maintenance_tickets
where status in ('open', 'assigned', 'in_progress')
group by 1;

-- ---------- Grants (PostgREST expone las vistas) ----------
do $$
declare v text;
begin
  foreach v in array array[
    'v_mt_kpis','v_mt_response_by_month','v_mt_spend_by_month',
    'v_mt_by_category','v_mt_active_by_priority'
  ] loop
    execute format('grant select on public.%I to anon, authenticated', v);
  end loop;
end $$;
