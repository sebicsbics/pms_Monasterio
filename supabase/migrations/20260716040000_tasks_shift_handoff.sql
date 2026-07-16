-- =====================================================================
-- TAREAS: rediseño como canal de comunicación entre turnos (shift-handoff).
-- Migración aditiva, NO destructiva. Cero migración de datos, cero drops.
--
-- Contexto: room_id y assigned_to ya son nullable en el esquema original
-- (20260703120000_housekeeping_tasks.sql) — no hace falta alterar su
-- nulabilidad. Lo único que cambia aquí es documentar la deprecación de
-- la asignación vía comentarios SQL, para que quede explícito en el
-- esquema que el flujo de asignación queda opcional/legacy sin romper
-- nada para quienes todavía lo usan.
-- =====================================================================

comment on function public.assignable_staff() is
  'DEPRECATED as of 2026-07: assignment is now optional in the tasks UI '
  '(shift-handoff model). RPC kept functional for teams that still want '
  'to assign a room-staff pair. Do not remove before confirming no '
  'callers depend on it — check src/services/tasks.ts fetchAssignableStaff().';

comment on column public.tasks.assigned_to is
  'DEPRECATED-OPTIONAL as of 2026-07: assignment no longer required. '
  'Kept for backward compat and teams that still assign. Future removal '
  'requires a product decision, not a technical one.';

comment on column public.tasks.room_id is
  'DEPRECATED-OPTIONAL as of 2026-07: room association no longer '
  'required — tasks module is now a shift-handoff communication log. '
  'Kept for backward compat with existing assigned tasks.';
