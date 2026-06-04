-- Gate seat price: ₿20 per seat (was 250 in early Phase 5 installs).
-- Run once in Supabase SQL Editor after competition_phase5_finances.sql.

CREATE OR REPLACE FUNCTION public.competition_compute_gate_total(
  p_capacity int,
  p_table_position int,
  p_history_avg_position numeric
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_capacity int := greatest(coalesce(p_capacity, 0), 0);
  v_pos int := least(greatest(coalesce(p_table_position, 10), 1), 20);
  v_hist numeric := coalesce(p_history_avg_position, 10);
  v_base_fill numeric := 0.55;
  v_position_boost numeric;
  v_history_boost numeric;
  v_fill numeric;
  v_price_per_seat numeric := 20;
  v_total numeric;
BEGIN
  v_position_boost := 0.35 * ((21 - v_pos)::numeric / 20.0);
  v_history_boost := 0.05 * ((21 - least(greatest(v_hist, 1), 20)) / 20.0);
  v_fill := least(v_base_fill + v_position_boost + v_history_boost, 0.95);
  v_total := round(v_capacity * v_fill * v_price_per_seat);

  RETURN jsonb_build_object(
    'capacity', v_capacity,
    'table_position', v_pos,
    'history_avg_position', round(v_hist, 2),
    'attendance_rate', round(v_fill, 4),
    'price_per_seat', v_price_per_seat,
    'total_gate', v_total
  );
END;
$function$;
