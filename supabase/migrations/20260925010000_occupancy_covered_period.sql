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
--
-- BUG preexistente encontrado en verificación (heredado por esta misma
-- migración en su primera versión, corregido acá): `quality_flags not
-- like '%room_invalid%'` da NULL (falso) cuando `quality_flags` es NULL,
-- así que las filas MÁS limpias (sin ninguna flag) quedaban excluidas en
-- silencio — 1.932 filas de md y 1.031 del archivo. Afectaba
-- v_occupancy_by_year (20260703160000_analytics_views.sql:32) y
-- v_room_performance (:104). Fix: `coalesce(quality_flags, '') not like
-- '%room_invalid%'` en ambas vistas.
--
-- BUG CRÍTICO encontrado en review (heredado por la primera versión de
-- esta misma migración, corregido acá): sumar `nights` agrupado por
-- extract(year from check_in) mientras la capacidad se acota al mismo
-- año calendario podía superar el 100% de ocupación — una estadía que
-- cruza fin de año (p.ej. check_in 2023-12-20, 30 noches) ponía TODAS
-- sus noches en el año de check_in, aunque la mayoría cayeran en el año
-- siguiente. Fix: cada NOCHE se atribuye a su propio año calendario.
-- Por estadía se expande con generate_series entre el año de check_in y
-- el de last_night, y para cada año se acota el tramo
-- [check_in, last_night] a [1-ene, 31-dic] de ESE año antes de contar
-- noches — no se suma `nights` (el total de la estadía), se cuenta el
-- tramo ya acotado por año. `desde`/`hasta` de cada año salen del mismo
-- tramo acotado (no del check_in/checkout global de la estadía).
-- =====================================================================

create or replace view public.v_occupancy_by_year as
with base as (
  select
    check_in,
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
    and coalesce(quality_flags, '') not like '%room_invalid%' and check_in is not null
),
-- una fila por cada año calendario que la estadía toca, con el tramo de
-- esa estadía acotado a ese año (nunca al año completo de la estadía).
per_year as (
  select
    y::int                                            as year,
    greatest(b.check_in, make_date(y::int, 1, 1))     as desde_tramo,
    least(b.last_night, make_date(y::int, 12, 31))    as hasta_tramo
  from base b
  cross join lateral generate_series(
    extract(year from b.check_in)::int,
    extract(year from b.last_night)::int
  ) as y
),
agg as (
  select
    year,
    sum(hasta_tramo - desde_tramo + 1) as noches_vendidas,
    min(desde_tramo)                    as desde,
    max(hasta_tramo)                    as hasta
  from per_year
  group by 1
)
select
  year,
  noches_vendidas,
  36 * (hasta - desde + 1)                                as capacidad,
  round(100.0 * noches_vendidas / (36 * (hasta - desde + 1)), 1) as ocupacion_pct,
  (desde <> make_date(year, 1, 1) or hasta <> make_date(year, 12, 31)) as es_parcial,
  desde,
  hasta
from agg
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

-- ---------- v_room_performance: mismo bug de quality_flags NULL ----------
-- Mismas columnas/orden/tipos que 20260703160000_analytics_views.sql,
-- único cambio: coalesce(quality_flags, '') en el filtro.
--
-- NO tiene el bug de atribución por año calendario de v_occupancy_by_year:
-- agrupa por `room` (rendimiento histórico total de la habitación), sin
-- `extract(year from check_in)` ni capacidad acotada a un año. Sumar
-- `nights` acá es correcto tal cual — no hay un "100%" por año contra el
-- que comparar, así que una estadía que cruza fin de año no distorsiona
-- nada: sus noches sencillamente suman al total histórico de la sala.
create or replace view public.v_room_performance as
select
  room,
  count(*)                                        as estadias,
  sum(nights)                                     as noches,
  round(sum(total_bs))                            as ingreso_bs,
  case when sum(nights) > 0
       then round(sum(total_bs) / sum(nights)) end as adr_bs
from public.historical_stays
where room is not null
  and coalesce(quality_flags, '') not like '%room_invalid%'
group by 1
order by ingreso_bs desc nulls last;

alter view public.v_room_performance set (security_invoker = on);
grant select on public.v_room_performance to authenticated;
