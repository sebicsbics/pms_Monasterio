-- =====================================================================
-- Vistas analíticas sobre historical_stays. Replican etl/analytics.py en SQL
-- para que el dashboard calcule en vivo (permiten filtros/drill-down a futuro).
--
-- Honestidad de datos (igual que el ETL):
--   - Revenue: solo filas con total_bs.
--   - Ocupación/rendimiento: solo noches + habitación válida (sin room_invalid).
-- Hotel: 36 habitaciones (DETALLE_DE_HABITACIONES).
-- =====================================================================

-- ---------- Ingreso y ADR por año ----------
create or replace view public.v_revenue_by_year as
select
  extract(year from check_in)::int             as year,
  count(*)                                      as estadias,
  round(sum(total_bs))                          as ingreso_bs,
  sum(nights)                                   as noches,
  sum(pax)                                      as pax,
  case when sum(nights) > 0
       then round(sum(total_bs) / sum(nights)) end as adr_bs
from public.historical_stays
where total_bs is not null and check_in is not null
group by 1
order by 1;

-- ---------- Ocupación por año (sobre 36 habitaciones) ----------
create or replace view public.v_occupancy_by_year as
with base as (
  select extract(year from check_in)::int as year, sum(nights) as noches_vendidas
  from public.historical_stays
  where nights is not null and room is not null
    and quality_flags not like '%room_invalid%' and check_in is not null
  group by 1
)
select
  year,
  noches_vendidas,
  36 * (case when (year % 4 = 0 and (year % 100 <> 0 or year % 400 = 0))
             then 366 else 365 end)              as capacidad,
  round(100.0 * noches_vendidas /
    (36 * (case when (year % 4 = 0 and (year % 100 <> 0 or year % 400 = 0))
                then 366 else 365 end)), 1)       as ocupacion_pct
from base
order by year;

-- ---------- Estacionalidad (por mes, todos los años) ----------
create or replace view public.v_seasonality as
select
  extract(month from check_in)::int as month,
  count(*)                          as estadias,
  sum(nights)                       as noches,
  round(sum(total_bs))              as ingreso_bs
from public.historical_stays
where check_in is not null
group by 1
order by 1;

-- ---------- Mix de canal (empresa cruda -> taxonomía vía channel_aliases) ----------
create or replace view public.v_channel_mix as
select
  coalesce(ca.channel_code, 'DESCONOCIDO')       as channel_code,
  count(*)                                        as estadias,
  round(sum(hs.total_bs))                         as ingreso_bs,
  case when count(*) > 0
       then round(sum(hs.total_bs) / count(*)) end as ticket_medio_bs
from public.historical_stays hs
left join public.channel_aliases ca
  on upper(hs.channel_raw) = ca.raw_name
where hs.channel_raw is not null
group by 1
order by estadias desc;

-- ---------- Origen del huésped ----------
create or replace view public.v_country_mix as
select
  upper(country)  as country,
  count(*)        as estadias
from public.historical_stays
where country is not null
group by 1
order by estadias desc;

-- ---------- Mix de forma de pago ----------
create or replace view public.v_payment_mix as
select
  payment             as payment,
  count(*)            as estadias,
  round(sum(total_bs)) as ingreso_bs
from public.historical_stays
where payment is not null
group by 1
order by estadias desc;

-- ---------- Rendimiento por habitación ----------
create or replace view public.v_room_performance as
select
  room,
  count(*)                                        as estadias,
  sum(nights)                                     as noches,
  round(sum(total_bs))                            as ingreso_bs,
  case when sum(nights) > 0
       then round(sum(total_bs) / sum(nights)) end as adr_bs
from public.historical_stays
where room is not null and quality_flags not like '%room_invalid%'
group by 1
order by ingreso_bs desc nulls last;

-- ---------- Grants: PostgREST expone las vistas; anon/authenticated deben leerlas ----------
do $$
declare v text;
begin
  foreach v in array array[
    'v_revenue_by_year','v_occupancy_by_year','v_seasonality','v_channel_mix',
    'v_country_mix','v_payment_mix','v_room_performance'
  ] loop
    execute format('grant select on public.%I to anon, authenticated', v);
  end loop;
end $$;
