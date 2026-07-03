-- =====================================================================
-- FASE 3.2b — Corrección de piso y patio de las habitaciones.
-- Fuente: aclaración del usuario (la distribución real difiere del MD).
-- Solo cambia floor/zone; los tipos y opciones NO se tocan.
-- Migración correctiva: 0004 ya está aplicada y es inmutable.
-- =====================================================================

-- ---------- Piso 1 ----------
update public.rooms set floor = 1, zone = 'Primer Patio'
  where room_number in ('1','2','3','4','5','6');
update public.rooms set floor = 1, zone = 'Segundo Patio'
  where room_number in ('7','8','9');
update public.rooms set floor = 1, zone = 'Tercer Patio'
  where room_number in ('10','11','12','14');

-- ---------- Piso 2 ----------
update public.rooms set floor = 2, zone = 'Primer Patio'
  where room_number in ('15','16','17','18','19','20','21');
update public.rooms set floor = 2, zone = 'Segundo Patio'
  where room_number in ('22','23','24','30');
update public.rooms set floor = 2, zone = 'Tercer Patio'
  where room_number in ('25','26','27','28','29');

-- ---------- Piso 3 ----------
update public.rooms set floor = 3, zone = 'Tercer Patio'
  where room_number in ('31','32','33','34','35','36','37');
