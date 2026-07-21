-- =====================================================================
-- Paso 2/2 del lockdown de reservations/folios/folio_charges. Cierra el
-- riesgo documentado en 20260716030000_rate_overrides.sql:11-21.
--
-- Reemplazo de las políticas "dev_all" (using(true)) de reservations/
-- folios/folio_charges por SELECT restringido a root/reception/accountant.
-- NO se agrega política de insert/update/delete: las únicas vías de
-- escritura quedan siendo las funciones SECURITY DEFINER convertidas en
-- 20260718000000_lock_down_reservations_folios.sql (check_out_room,
-- add_folio_charge, add_folio_product_charge, create_reservation,
-- check_in_reservation), que corren como owner y evitan RLS.
--
-- No hay writes directos desde el cliente sobre estas tres tablas (todo
-- pasa por RPC), así que negar insert/update/delete no rompe la app.
-- =====================================================================

drop policy if exists "dev_all_resv" on public.reservations;
create policy "reservations_select" on public.reservations
  for select using (public.current_user_role() in ('root', 'reception', 'accountant'));

drop policy if exists "dev_all_folios" on public.folios;
create policy "folios_select" on public.folios
  for select using (public.current_user_role() in ('root', 'reception', 'accountant'));

drop policy if exists "dev_all_folio_charges" on public.folio_charges;
create policy "folio_charges_select" on public.folio_charges
  for select using (public.current_user_role() in ('root', 'reception', 'accountant'));
