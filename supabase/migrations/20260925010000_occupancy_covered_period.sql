-- =====================================================================
-- Fix: v_occupancy_by_year dividía siempre por 36 * 365/366, aunque el
-- año solo tenga datos cubriendo una parte del período (2013 arranca en
-- setiembre en el archivo histórico; 2022-2023 tiene huecos en md). Eso
-- infla artificialmente el % de ocupación hacia abajo en años parciales.
--
-- Fix: la capacidad de cada año se calcula sobre el período realmente
-- cubierto por datos (desde la primera noche hasta la última noche
-- registrada ese año, acotado al propio año calendario), no sobre el año
-- completo. Se agregan `es_parcial`, `desde` y `hasta` para que el
-- dashboard pueda explicarlo. Columnas existentes (year, noches_vendidas,
-- capacidad, ocupacion_pct) se mantienen con el mismo nombre/tipo — solo
-- se agregan columnas al final (create or replace view no puede
-- reordenar/quitar columnas).
--
-- Alcance: solo se corrige el requisito mínimo (primera/última fecha
-- cubierta por año). No se descuentan huecos internos (p.ej. 2022-2023
-- casi vacíos en md): eso requeriría detectar tramos sin estadías dentro
-- del año, que es una mejora aparte y no la pide la decisión #466 como
-- mínimo. Se documenta acá para no perderlo de vista.
--
-- La fila con el typo de año en md (Lista de Llegadas 2017, room 1,
-- 2015-05-30 -> 2017-06-01, nights null) ya queda fuera del cálculo:
-- el filtro `nights is not null` de la vista la excluye, así que tampoco
-- puede distorsionar `desde`/`hasta`.
-- =====================================================================

create or replace view public.v_occupancy_by_year as
with base as (
  select
    extract(year from check_in)::int as year,
    check_in,
    nights,
    -- última noche cubierta por la estadía: check_out - 1 día si está
    -- presente y es coherente; si no, se deriva de nights (ya no-nulo
    -- por el filtro de abajo) para no perder la fila por un check_out
    -- corrupto o ausente.
    coalesce(
      case when check_out is not null and check_out > check_in
           then check_out - 1 end,
      check_in + (nights - 1)
    ) as last_night
  from public.historical_stays
  where nights is not null and room is not null
    and quality_flags not like '%room_invalid%' and check_in is not null
),
agg as (
  select
    year,
    sum(nights)      as noches_vendidas,
    min(check_in)     as min_check_in,
    max(last_night)   as max_last_night
  from base
  group by 1
),
covered as (
  select
    year,
    noches_vendidas,
    -- acotado al propio año calendario: una estadía que arranca antes de
    -- fin de año pero cuyo check_out cae en el año siguiente no debe
    -- inflar el período cubierto de ESTE año más allá del 31 de dic.
    greatest(min_check_in, make_date(year, 1, 1))   as desde,
    least(max_last_night, make_date(year, 12, 31))  as hasta
  from agg
)
select
  year,
  noches_vendidas,
  36 * (hasta - desde + 1)                                as capacidad,
  round(100.0 * noches_vendidas / (36 * (hasta - desde + 1)), 1) as ocupacion_pct,
  (desde <> make_date(year, 1, 1) or hasta <> make_date(year, 12, 31)) as es_parcial,
  desde,
  hasta
from covered
order by year;

-- Réplica de la protección aplicada en 20260812000000_close_public_reads.sql:
-- security_invoker respeta al que consulta (hereda la RLS de
-- historical_stays vía is_staff()); create or replace view no garantiza
-- conservar reloptions, así que se re-declara explícitamente.
alter view public.v_occupancy_by_year set (security_invoker = on);

-- El grant a anon fue revocado globalmente en 20260812000000 (`revoke all
-- on all tables in schema public from anon`); acá solo se re-declara el de
-- authenticated para que quede explícito y no dependa de que create or
-- replace view preserve el ACL previo.
grant select on public.v_occupancy_by_year to authenticated;
