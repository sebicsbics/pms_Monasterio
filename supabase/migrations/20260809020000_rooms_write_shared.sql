-- =====================================================================
-- Corrección de 20260809010000: `accountant` también opera el tablero.
-- (change: owner-read-only-role, follow-up)
--
-- Al cerrar `dev_all_rooms` asigné la escritura a root/reception/
-- reception_admin razonando desde "quién opera el tablero". Pero la
-- pestaña Tablero está abierta a SHARED, que incluye accountant: con la
-- política nueva, contaduría dejaba de poder marcar una habitación como
-- limpia o ponerla en mantenimiento (`setRoomStatus` escribe directo).
--
-- Detectado al probar la matriz de roles antes de tocar el frontend. La
-- lección es que el permiso tiene que derivarse de QUIÉN VE LA PANTALLA
-- (App.tsx: roles de cada tab), no de una intuición sobre el puesto.
--
-- `owner` sigue afuera: es de sólo lectura y no está en SHARED.
-- =====================================================================

drop policy if exists rooms_write on public.rooms;

create policy rooms_write on public.rooms
  for all
  using (public.current_user_role() in ('root', 'accountant', 'reception', 'reception_admin'))
  with check (public.current_user_role() in ('root', 'accountant', 'reception', 'reception_admin'));
