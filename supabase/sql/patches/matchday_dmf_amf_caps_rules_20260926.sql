-- =============================================================================
-- Match Day: DMF/AMF ≤ 2 on pitch + fine label updates
--
-- · Server pitch save rejects >2 DMF or >2 AMF role labels
-- · Fine labels: individual instructions blocked; Red/Blue 80'/90' windows
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Pitch layout validation (mirroring + CF/SS + DMF + AMF)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_pitch_layout_mirroring(p_layout jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_has_lb boolean := false;
  v_has_rb boolean := false;
  v_has_lmf boolean := false;
  v_has_rmf boolean := false;
  v_has_lwf boolean := false;
  v_has_rwf boolean := false;
  v_cf_ss_count int := 0;
  v_dmf_count int := 0;
  v_amf_count int := 0;
  v_key text;
  v_label text;
  v_val jsonb;
BEGIN
  IF p_layout IS NULL OR jsonb_typeof(p_layout) IS DISTINCT FROM 'object' THEN
    RETURN NULL;
  END IF;

  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_layout)
  LOOP
    IF v_key = 'formation_id' THEN
      CONTINUE;
    END IF;
    IF jsonb_typeof(v_val) IS DISTINCT FROM 'object' THEN
      CONTINUE;
    END IF;

    v_label := upper(btrim(v_val->>'label'));
    IF v_label IS NULL OR v_label = '' THEN
      CONTINUE;
    END IF;

    IF v_label = 'LB' THEN v_has_lb := true;
    ELSIF v_label = 'RB' THEN v_has_rb := true;
    ELSIF v_label = 'LMF' THEN v_has_lmf := true;
    ELSIF v_label = 'RMF' THEN v_has_rmf := true;
    ELSIF v_label = 'LWF' THEN v_has_lwf := true;
    ELSIF v_label = 'RWF' THEN v_has_rwf := true;
    ELSIF v_label IN ('CF', 'SS') THEN v_cf_ss_count := v_cf_ss_count + 1;
    ELSIF v_label = 'DMF' THEN v_dmf_count := v_dmf_count + 1;
    ELSIF v_label = 'AMF' THEN v_amf_count := v_amf_count + 1;
    END IF;
  END LOOP;

  IF v_has_lb AND NOT v_has_rb THEN
    RETURN 'Mirroring: LB requires RB';
  END IF;
  IF v_has_rb AND NOT v_has_lb THEN
    RETURN 'Mirroring: RB requires LB';
  END IF;
  IF v_has_lmf AND NOT v_has_rmf THEN
    RETURN 'Mirroring: LMF requires RMF';
  END IF;
  IF v_has_rmf AND NOT v_has_lmf THEN
    RETURN 'Mirroring: RMF requires LMF';
  END IF;
  IF v_has_lwf AND NOT v_has_rwf THEN
    RETURN 'Mirroring: LWF requires RWF';
  END IF;
  IF v_has_rwf AND NOT v_has_lwf THEN
    RETURN 'Mirroring: RWF requires LWF';
  END IF;
  IF v_cf_ss_count > 2 THEN
    RETURN format(
      'Mirroring: only 2 CF/SS roles allowed combined (found %s)',
      v_cf_ss_count
    );
  END IF;
  IF v_dmf_count > 2 THEN
    RETURN format(
      'No more than 2 DMFs on the pitch (found %s)',
      v_dmf_count
    );
  END IF;
  IF v_amf_count > 2 THEN
    RETURN format(
      'No more than 2 AMFs on the pitch (found %s)',
      v_amf_count
    );
  END IF;

  RETURN NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.validate_pitch_layout_mirroring(jsonb) TO authenticated;

-- Formation catalogue validate_slots is replaced below (adds DMF/AMF ≤ 2).

CREATE OR REPLACE FUNCTION public.gpsl_formation_validate_slots(p_slots jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_item jsonb;
  v_key text;
  v_pos text;
  v_n int := 0;
  v_gk int := 0;
  v_cf_ss int := 0;
  v_dmf int := 0;
  v_amf int := 0;
  v_positions text[] := ARRAY[]::text[];
  v_allowed text[];
  v_catalogue text[] := ARRAY[
    'GK','CB','LB','RB','LWB','RWB','DMF','CMF','AMF','LMF','RMF','LWF','RWF','SS','CF'
  ];
  v_x text;
  v_allow boolean;
BEGIN
  IF p_slots IS NULL OR jsonb_typeof(p_slots) IS DISTINCT FROM 'array' THEN
    RETURN 'slots must be a JSON array';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_n := v_n + 1;
    v_key := nullif(btrim(coalesce(v_item->>'slot_key', v_item->>'id', '')), '');
    IF v_key IS NULL THEN
      RETURN 'slot missing slot_key';
    END IF;

    v_pos := upper(nullif(btrim(coalesce(
      v_item->>'default_position',
      v_item->>'label',
      ''
    )), ''));
    IF v_pos IS NULL THEN
      RETURN format('slot %s missing default_position', v_key);
    END IF;
    IF NOT (v_pos = ANY (v_catalogue)) THEN
      RETURN format('invalid default_position %s on %s', v_pos, v_key);
    END IF;

    v_positions := array_append(v_positions, v_pos);
    IF v_pos = 'GK' THEN v_gk := v_gk + 1; END IF;
    IF v_pos IN ('CF', 'SS') THEN v_cf_ss := v_cf_ss + 1; END IF;
    IF v_pos = 'DMF' THEN v_dmf := v_dmf + 1; END IF;
    IF v_pos = 'AMF' THEN v_amf := v_amf + 1; END IF;

    v_allow := coalesce((v_item->>'allow_relabel')::boolean, false);
    IF v_allow THEN
      BEGIN
        SELECT array_agg(upper(btrim(x)))
        INTO v_allowed
        FROM jsonb_array_elements_text(
          coalesce(v_item->'allowed_positions', '[]'::jsonb)
        ) AS t(x)
        WHERE nullif(btrim(x), '') IS NOT NULL;
      EXCEPTION WHEN OTHERS THEN
        v_allowed := NULL;
      END;

      IF v_allowed IS NULL OR cardinality(v_allowed) = 0 THEN
        v_allowed := ARRAY[v_pos]::text[];
      END IF;
      IF NOT (v_pos = ANY (v_allowed)) THEN
        v_allowed := array_prepend(v_pos, v_allowed);
      END IF;

      FOREACH v_x IN ARRAY v_allowed
      LOOP
        IF NOT (v_x = ANY (v_catalogue)) THEN
          RETURN format('allowed_positions contains invalid role %s on %s', v_x, v_key);
        END IF;
      END LOOP;
    END IF;
  END LOOP;

  IF v_n <> 11 THEN
    RETURN format('Formation must have exactly 11 slots (has %s)', v_n);
  END IF;
  IF v_gk <> 1 THEN
    RETURN format('Formation must have exactly 1 GK (has %s)', v_gk);
  END IF;

  IF v_cf_ss > 2 THEN
    RETURN format(
      'CF + SS combined must be ≤ 2 (has %s) — CF/CF/SS is not allowed',
      v_cf_ss
    );
  END IF;
  IF v_dmf > 2 THEN
    RETURN format('No more than 2 DMFs in a formation (has %s)', v_dmf);
  END IF;
  IF v_amf > 2 THEN
    RETURN format('No more than 2 AMFs in a formation (has %s)', v_amf);
  END IF;

  RETURN NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fine tariff labels (keep codes stable for existing reports)
-- ---------------------------------------------------------------------------
UPDATE public.competition_fine_tariff
SET
  label = 'Individual Player Instructions used',
  updated_at = now()
WHERE code = 'non_display_player_instructions';

UPDATE public.competition_fine_tariff
SET
  label = 'Red/Blue before 80th Minute',
  updated_at = now()
WHERE code = 'red_blue_before_80';

UPDATE public.competition_fine_tariff
SET
  label = 'Double Red/Blue before 90th Minute',
  updated_at = now()
WHERE code = 'double_red_blue';

UPDATE public.competition_fine_tariff
SET
  label = 'Red/Blue in 1st half of extra time',
  updated_at = now()
WHERE code = 'red_blue_et_first_half';

NOTIFY pgrst, 'reload schema';
