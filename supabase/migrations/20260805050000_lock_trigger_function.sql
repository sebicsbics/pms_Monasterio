-- =====================================================================
-- sync_single_stay_segment: sacarla de la superficie REST.
-- (change: stay-segments, follow-up)
--
-- El linter de Supabase la marcó como "SECURITY DEFINER ejecutable por
-- anon/authenticated vía /rest/v1/rpc/". A diferencia de extend_stay o
-- change_room, esta función NO tiene guard de rol: es una función de
-- trigger y da por sentado que la llama el trigger.
--
-- En la práctica Postgres rechaza invocarla directo ("trigger functions
-- can only be called as triggers"), así que no es explotable. Pero
-- depender de esa defensa es depender de un detalle del motor para una
-- función que escribe tramos de estadía. Se revoca el execute: el trigger
-- corre como dueño de la tabla y no necesita el grant.
-- =====================================================================

revoke execute on function public.sync_single_stay_segment()
  from public, anon, authenticated;
