-- =====================================================================
-- Seed: tipos de habitación del Hotel Monasterio (13 tipos).
-- Datos reales portados desde la base local. IDs originales preservados.
-- Idempotente: on conflict do nothing evita duplicados al re-ejecutar.
-- =====================================================================
insert into public.room_types (id, name, base_price_bs, max_occupancy, description) values
  ('1b8c4e3c-759e-40b5-b19f-8bd6ad6bf28f','Simple Estándar',350.00,1,'Habitación acogedora para un solo huésped.'),
  ('caac1c2d-ec02-4b60-adfd-842cda94281d','Doble Estándar',480.00,2,'Habitación cómoda con dos camas individuales o una cama doble.'),
  ('67b48343-325c-4b32-aa5b-e6a20b029ea2','Matrimonial',480.00,2,'Habitación ideal para parejas con una cama matrimonial.'),
  ('be6c7622-e4f7-4569-9696-c187d7150415','Triple Estándar',600.00,3,'Espacio amplio para tres huéspedes, ideal para grupos pequeños.'),
  ('3deac40b-ab0c-416a-9399-7395bb7d6126','Loft Cuádruple',780.00,4,'Moderno y espacioso loft con capacidad para cuatro personas.'),
  ('3f66af11-7a44-42e8-82a3-2a3a3c686368','Familiar',900.00,5,'Suite de gran tamaño pensada para la comodidad de toda la familia.'),
  ('3a3a4500-b645-46bb-9945-dfa61403675c','Simple Ejecutiva',450.00,1,'Diseñada para el viajero de negocios, con escritorio y servicios mejorados.'),
  ('31db1085-e3fe-4b11-8b25-7ab1a2462f07','Matrimonial Ejecutiva',550.00,2,'Confort y funcionalidad para parejas en viaje de negocios o placer.'),
  ('85affee8-9aac-4865-ad5f-be8744eb94a6','Simple Colonial Suite',500.00,1,'Suite con encanto colonial y detalles de época para un solo huésped.'),
  ('24f5db63-6736-47bf-a8c8-973b90f0ab4b','Matrimonial Colonial Suite',700.00,2,'Elegancia y estilo colonial en una suite espaciosa para dos.'),
  ('3c8915aa-3625-4a58-a15a-d03f4267a6eb','Suite Master Simple',650.00,1,'Lujo y exclusividad en nuestra suite principal para un huésped.'),
  ('7b6e2b77-c105-4a7e-82a9-87e2c5d9ec40','Suite Master Matrimonial',800.00,2,'La máxima expresión de lujo y confort para dos personas.'),
  ('16285e9e-9796-4471-978d-8199950e0b0a','Presidencial',2000.00,4,'Nuestra suite más exclusiva con múltiples ambientes y servicios de primera clase.')
on conflict (id) do nothing;
