-- =====================================================================
-- FASE 3.2 — Seed de las 36 habitaciones reales del Hotel Monasterio.
-- Fuente: DETALLE_DE_HABITACIONES.md. No existe la habitación 13.
-- Habitaciones duales (Simple/Matrimonial) => tipo por defecto = Matrimonial,
-- y ambas opciones cargadas en room_type_options.
-- Idempotente (on conflict do nothing).
-- =====================================================================

-- ---------- 1) Habitaciones (con tipo POR DEFECTO) ----------
insert into public.rooms (room_number, floor, zone, room_type_id, operational_status)
select r.room_number, r.floor, r.zone, rt.id, 'available'
from (values
  -- Piso 1
  ('1',  1, 'Primer Patio',  'Matrimonial'),
  ('2',  1, 'Primer Patio',  'Doble Estándar'),
  ('3',  1, 'Primer Patio',  'Presidencial'),
  ('4',  1, 'Primer Patio',  'Matrimonial'),
  ('5',  1, 'Primer Patio',  'Matrimonial'),
  ('6',  1, 'Primer Patio',  'Doble Estándar'),
  ('7',  1, 'Segundo Patio', 'Matrimonial'),
  ('8',  1, 'Segundo Patio', 'Matrimonial'),
  ('9',  1, 'Segundo Patio', 'Doble Estándar'),
  ('10', 1, 'Segundo Patio', 'Doble Estándar'),
  ('11', 1, 'Segundo Patio', 'Doble Estándar'),
  ('12', 1, 'Segundo Patio', 'Doble Estándar'),
  ('14', 1, 'Segundo Patio', 'Matrimonial'),
  ('15', 1, 'Segundo Patio', 'Matrimonial'),
  ('16', 1, 'Segundo Patio', 'Matrimonial'),
  -- Piso 2
  ('17', 2, 'Tercer Patio',  'Familiar'),
  ('18', 2, 'Tercer Patio',  'Doble Estándar'),
  ('19', 2, 'Tercer Patio',  'Loft Cuádruple'),
  ('20', 2, 'Tercer Patio',  'Loft Cuádruple'),
  ('21', 2, 'Primer Patio',  'Matrimonial Ejecutiva'),
  ('22', 2, 'Primer Patio',  'Loft Cuádruple'),
  ('23', 2, 'Primer Patio',  'Loft Cuádruple'),
  ('24', 2, 'Primer Patio',  'Doble Estándar'),
  ('25', 2, 'Primer Patio',  'Matrimonial Ejecutiva'),
  ('26', 2, 'Primer Patio',  'Triple Estándar'),
  ('27', 2, 'Primer Patio',  'Doble Estándar'),
  ('28', 2, 'Segundo Patio', 'Suite Master Matrimonial'),
  ('29', 2, 'Segundo Patio', 'Matrimonial Colonial Suite'),
  ('30', 2, 'Segundo Patio', 'Matrimonial Colonial Suite'),
  ('31', 2, 'Segundo Patio', 'Triple Estándar'),
  -- Piso 3
  ('32', 3, 'Tercer Patio',  'Matrimonial'),
  ('33', 3, 'Tercer Patio',  'Triple Estándar'),
  ('34', 3, 'Tercer Patio',  'Doble Estándar'),
  ('35', 3, 'Tercer Patio',  'Suite Master Matrimonial'),
  ('36', 3, 'Tercer Patio',  'Matrimonial Colonial Suite'),
  ('37', 3, 'Tercer Patio',  'Matrimonial Colonial Suite')
) as r(room_number, floor, zone, default_type)
join public.room_types rt on rt.name = r.default_type
on conflict (room_number) do nothing;

-- ---------- 2) Tipos ofrecibles por habitación (duales incluidos) ----------
insert into public.room_type_options (room_id, room_type_id)
select rm.id, rt.id
from (values
  -- Duales base: Simple Estándar + Matrimonial
  ('1','Simple Estándar'),  ('1','Matrimonial'),
  ('4','Simple Estándar'),  ('4','Matrimonial'),
  ('5','Simple Estándar'),  ('5','Matrimonial'),
  ('7','Simple Estándar'),  ('7','Matrimonial'),
  ('8','Simple Estándar'),  ('8','Matrimonial'),
  ('14','Simple Estándar'), ('14','Matrimonial'),
  ('15','Simple Estándar'), ('15','Matrimonial'),
  ('16','Simple Estándar'), ('16','Matrimonial'),
  ('32','Simple Estándar'), ('32','Matrimonial'),
  -- Duales ejecutiva: Simple Ejecutiva + Matrimonial Ejecutiva
  ('21','Simple Ejecutiva'), ('21','Matrimonial Ejecutiva'),
  ('25','Simple Ejecutiva'), ('25','Matrimonial Ejecutiva'),
  -- Duales master: Suite Master Simple + Suite Master Matrimonial
  ('28','Suite Master Simple'), ('28','Suite Master Matrimonial'),
  ('35','Suite Master Simple'), ('35','Suite Master Matrimonial'),
  -- Duales colonial: Simple Colonial Suite + Matrimonial Colonial Suite
  ('29','Simple Colonial Suite'), ('29','Matrimonial Colonial Suite'),
  ('30','Simple Colonial Suite'), ('30','Matrimonial Colonial Suite'),
  ('36','Simple Colonial Suite'), ('36','Matrimonial Colonial Suite'),
  ('37','Simple Colonial Suite'), ('37','Matrimonial Colonial Suite'),
  -- Únicos: Doble Estándar
  ('2','Doble Estándar'),  ('6','Doble Estándar'),  ('9','Doble Estándar'),
  ('10','Doble Estándar'), ('11','Doble Estándar'), ('12','Doble Estándar'),
  ('18','Doble Estándar'), ('24','Doble Estándar'), ('27','Doble Estándar'),
  ('34','Doble Estándar'),
  -- Únicos: Triple Estándar
  ('26','Triple Estándar'), ('31','Triple Estándar'), ('33','Triple Estándar'),
  -- Únicos: Loft Cuádruple
  ('19','Loft Cuádruple'), ('20','Loft Cuádruple'),
  ('22','Loft Cuádruple'), ('23','Loft Cuádruple'),
  -- Únicos: Familiar y Presidencial
  ('17','Familiar'),
  ('3','Presidencial')
) as o(room_number, type_name)
join public.rooms      rm on rm.room_number = o.room_number
join public.room_types rt on rt.name = o.type_name
on conflict do nothing;
