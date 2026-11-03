-- Individualised Match Day recording ticks (dashboard checklist).
-- Expands the old 7 compound rec_* keys into grouped item keys.
-- Keeps legacy keys valid so existing ticks still load / expand in the UI.

CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_tick_keys(p_fixture boolean)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN p_fixture
    THEN ARRAY[
      -- New individual ticks
      'rec_started',
      'rec_room_10min', 'rec_room_injuries', 'rec_room_subs', 'rec_room_intervals', 'rec_room_form',
      'rec_cfg_stadium', 'rec_cfg_kits', 'rec_cfg_weather',
      'rec_pers_manager', 'rec_pers_subtactic', 'rec_pers_squad',
      'rec_tac_instructions', 'rec_tac_subtactic', 'rec_tac_fluid',
      'rec_pause_pa3', 'rec_pause_adv',
      'rec_pitch_scoreboard', 'rec_pitch_hud',
      'rec_post_ratings', 'rec_post_potm', 'rec_post_stop',
      -- Legacy compound keys (still readable / untickable)
      'rec_room_settings', 'rec_prematch_config', 'rec_squad_tactics',
      'rec_pause_pa', 'rec_hud_on', 'rec_post_match'
    ]
    ELSE ARRAY['read_matchday_checklist', 'can_record', 'know_match_settings',
               'know_squad_tactics', 'know_kits_stadium']
  END;
$$;
