-- =============================================================================
-- GPSL formations catalogue (eFootball-style, admin-owned)
--
-- Direction of travel: leave GPSL mirroring; use named eFootball formations.
-- Admin edits formations + per-slot role swap rules. Match Day / International
-- will select from enabled rows once catalogue_live is turned on.
--
-- Global constraint: CF + SS combined ≤ 2 (CF/CF/SS not permitted).
--
-- Safe re-run. Seeds current Match Day presets (relabel allowed, but each slot
-- starts with only its default role — expand allowed roles in Admin).
-- =============================================================================

SET lock_timeout = '15s';

CREATE TABLE IF NOT EXISTS public.gpsl_formations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  group_label text NOT NULL DEFAULT 'General',
  is_enabled boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  source text NOT NULL DEFAULT 'admin',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gpsl_formations_code_chk CHECK (btrim(code) <> ''),
  CONSTRAINT gpsl_formations_name_chk CHECK (btrim(name) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_formations_code_uidx
  ON public.gpsl_formations (lower(btrim(code)));

CREATE TABLE IF NOT EXISTS public.gpsl_formation_slots (
  formation_id uuid NOT NULL
    REFERENCES public.gpsl_formations (id) ON DELETE CASCADE,
  slot_key text NOT NULL,
  default_position text NOT NULL,
  x numeric(5,2) NOT NULL,
  y numeric(5,2) NOT NULL,
  sort_order int NOT NULL DEFAULT 0,
  allow_relabel boolean NOT NULL DEFAULT false,
  allowed_positions text[] NOT NULL DEFAULT '{}'::text[],
  PRIMARY KEY (formation_id, slot_key),
  CONSTRAINT gpsl_formation_slots_key_chk CHECK (btrim(slot_key) <> ''),
  CONSTRAINT gpsl_formation_slots_pos_chk CHECK (btrim(default_position) <> ''),
  CONSTRAINT gpsl_formation_slots_xy_chk CHECK (
    x >= 0 AND x <= 100 AND y >= 0 AND y <= 100
  )
);

CREATE INDEX IF NOT EXISTS gpsl_formation_slots_formation_idx
  ON public.gpsl_formation_slots (formation_id, sort_order);

CREATE TABLE IF NOT EXISTS public.gpsl_formation_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  -- Legacy LB↔RB / LMF↔RMF / LWF↔RWF rule (off for eFootball catalogue)
  enforce_mirroring boolean NOT NULL DEFAULT false,
  max_cf_ss int NOT NULL DEFAULT 2 CHECK (max_cf_ss >= 0 AND max_cf_ss <= 3),
  -- When true, Match Day / International use this catalogue instead of JS presets
  catalogue_live boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_formation_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE public.gpsl_formations IS
  'Admin-owned eFootball-style formations for Match Day / International.';
COMMENT ON TABLE public.gpsl_formation_slots IS
  'Pitch slots. allow_relabel + allowed_positions control owner role changes.';
COMMENT ON COLUMN public.gpsl_formation_settings.catalogue_live IS
  'Flip on when Match Day / International should read this catalogue.';

CREATE OR REPLACE FUNCTION public.gpsl_formation_position_catalogue()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'GK','CB','LB','RB','LWB','RWB',
    'DMF','CMF','AMF','LMF','RMF',
    'LWF','RWF','SS','CF'
  ]::text[];
$$;

CREATE OR REPLACE FUNCTION public.gpsl_formation_count_cf_ss(p_positions text[])
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce((
    SELECT count(*)::int
    FROM unnest(coalesce(p_positions, '{}'::text[])) AS p(pos)
    WHERE upper(btrim(pos)) IN ('CF', 'SS')
  ), 0);
$$;

CREATE OR REPLACE FUNCTION public.gpsl_formation_validate_slots(p_slots jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_item jsonb;
  v_pos text;
  v_key text;
  v_positions text[] := '{}'::text[];
  v_keys text[] := '{}'::text[];
  v_allowed text[];
  v_x text;
  v_n int := 0;
  v_gk int := 0;
  v_cf_ss int := 0;
  v_catalogue text[] := public.gpsl_formation_position_catalogue();
BEGIN
  IF p_slots IS NULL OR jsonb_typeof(p_slots) IS DISTINCT FROM 'array' THEN
    RETURN 'slots must be a JSON array';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_n := v_n + 1;
    v_key := upper(btrim(coalesce(v_item->>'slot_key', '')));
    v_pos := upper(btrim(coalesce(v_item->>'default_position', '')));

    IF v_key = '' THEN
      RETURN 'Each slot needs a slot_key';
    END IF;
    IF v_key = ANY (v_keys) THEN
      RETURN format('Duplicate slot_key %s', v_key);
    END IF;
    v_keys := array_append(v_keys, v_key);

    IF v_pos = '' OR NOT (v_pos = ANY (v_catalogue)) THEN
      RETURN format('Invalid default_position %s on slot %s', coalesce(nullif(v_pos,''), '?'), v_key);
    END IF;
    v_positions := array_append(v_positions, v_pos);
    IF v_pos = 'GK' THEN
      v_gk := v_gk + 1;
    END IF;

    IF coalesce((v_item->>'allow_relabel')::boolean, false) THEN
      SELECT coalesce(
        array_agg(DISTINCT upper(btrim(x))) FILTER (WHERE btrim(x) <> ''),
        ARRAY[v_pos]::text[]
      )
      INTO v_allowed
      FROM unnest(
        coalesce(
          ARRAY(
            SELECT jsonb_array_elements_text(
              coalesce(v_item->'allowed_positions', '[]'::jsonb)
            )
          ),
          ARRAY[v_pos]::text[]
        )
      ) AS t(x);

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

  v_cf_ss := public.gpsl_formation_count_cf_ss(v_positions);
  IF v_cf_ss > 2 THEN
    RETURN format(
      'CF + SS combined must be ≤ 2 (has %s) — CF/CF/SS is not allowed',
      v_cf_ss
    );
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_formation_upsert(
  p_code text,
  p_name text,
  p_description text,
  p_group_label text,
  p_is_enabled boolean,
  p_sort_order int,
  p_slots jsonb,
  p_source text DEFAULT 'admin',
  p_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_err text;
  v_id uuid;
  v_item jsonb;
  v_sort int := 0;
  v_default text;
  v_allowed text[];
  v_allow boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_err := public.gpsl_formation_validate_slots(p_slots);
  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION '%', v_err;
  END IF;

  IF p_id IS NOT NULL THEN
    v_id := p_id;
    UPDATE public.gpsl_formations f
    SET
      code = btrim(p_code),
      name = btrim(p_name),
      description = coalesce(p_description, ''),
      group_label = coalesce(nullif(btrim(p_group_label), ''), 'General'),
      is_enabled = coalesce(p_is_enabled, true),
      sort_order = coalesce(p_sort_order, 0),
      source = coalesce(nullif(btrim(p_source), ''), f.source),
      updated_at = now()
    WHERE f.id = v_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Formation not found';
    END IF;

    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  ELSE
    INSERT INTO public.gpsl_formations (
      code, name, description, group_label, is_enabled, sort_order, source
    )
    VALUES (
      btrim(p_code),
      btrim(p_name),
      coalesce(p_description, ''),
      coalesce(nullif(btrim(p_group_label), ''), 'General'),
      coalesce(p_is_enabled, true),
      coalesce(p_sort_order, 0),
      coalesce(nullif(btrim(p_source), ''), 'admin')
    )
    ON CONFLICT ((lower(btrim(code)))) DO UPDATE
    SET
      name = excluded.name,
      description = excluded.description,
      group_label = excluded.group_label,
      is_enabled = excluded.is_enabled,
      sort_order = excluded.sort_order,
      source = excluded.source,
      updated_at = now()
    RETURNING id INTO v_id;

    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;

  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(p_slots)
    ORDER BY coalesce((value->>'sort_order')::int, 0)
  LOOP
    v_default := upper(btrim(v_item->>'default_position'));
    v_allow := coalesce((v_item->>'allow_relabel')::boolean, false);
    SELECT coalesce(
      array_agg(DISTINCT upper(btrim(x))) FILTER (WHERE btrim(x) <> ''),
      ARRAY[v_default]::text[]
    )
    INTO v_allowed
    FROM unnest(
      coalesce(
        ARRAY(
          SELECT jsonb_array_elements_text(
            coalesce(v_item->'allowed_positions', '[]'::jsonb)
          )
        ),
        ARRAY[v_default]::text[]
      )
    ) AS t(x);

    IF NOT (v_default = ANY (v_allowed)) THEN
      v_allowed := array_prepend(v_default, v_allowed);
    END IF;

    INSERT INTO public.gpsl_formation_slots (
      formation_id, slot_key, default_position, x, y, sort_order,
      allow_relabel, allowed_positions
    )
    VALUES (
      v_id,
      upper(btrim(v_item->>'slot_key')),
      v_default,
      (v_item->>'x')::numeric,
      (v_item->>'y')::numeric,
      coalesce((v_item->>'sort_order')::int, v_sort),
      v_allow,
      CASE WHEN v_allow THEN v_allowed ELSE ARRAY[v_default]::text[] END
    );
    v_sort := v_sort + 1;
  END LOOP;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_formation_delete(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  DELETE FROM public.gpsl_formations WHERE id = p_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_formation_set_settings(
  p_catalogue_live boolean DEFAULT NULL,
  p_enforce_mirroring boolean DEFAULT NULL,
  p_max_cf_ss int DEFAULT NULL
)
RETURNS public.gpsl_formation_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_formation_settings;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.gpsl_formation_settings
  SET
    catalogue_live = coalesce(p_catalogue_live, catalogue_live),
    enforce_mirroring = coalesce(p_enforce_mirroring, enforce_mirroring),
    max_cf_ss = coalesce(p_max_cf_ss, max_cf_ss),
    updated_at = now()
  WHERE id = 1
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_formations_list(p_enabled_only boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings jsonb;
  v_rows jsonb;
BEGIN
  SELECT to_jsonb(s) - 'id'
  INTO v_settings
  FROM public.gpsl_formation_settings s
  WHERE s.id = 1;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', f.id,
        'code', f.code,
        'name', f.name,
        'description', f.description,
        'group_label', f.group_label,
        'is_enabled', f.is_enabled,
        'sort_order', f.sort_order,
        'source', f.source,
        'updated_at', f.updated_at,
        'slots', (
          SELECT coalesce(
            jsonb_agg(
              jsonb_build_object(
                'slot_key', s.slot_key,
                'default_position', s.default_position,
                'x', s.x,
                'y', s.y,
                'sort_order', s.sort_order,
                'allow_relabel', s.allow_relabel,
                'allowed_positions', to_jsonb(s.allowed_positions)
              )
              ORDER BY s.sort_order, s.slot_key
            ),
            '[]'::jsonb
          )
          FROM public.gpsl_formation_slots s
          WHERE s.formation_id = f.id
        )
      )
      ORDER BY f.sort_order, f.name
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.gpsl_formations f
  WHERE (NOT p_enabled_only) OR f.is_enabled;

  RETURN jsonb_build_object(
    'settings', coalesce(v_settings, '{}'::jsonb),
    'formations', coalesce(v_rows, '[]'::jsonb),
    'positions', to_jsonb(public.gpsl_formation_position_catalogue())
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_formation_position_catalogue() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_formation_count_cf_ss(text[]) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_formation_validate_slots(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_formation_upsert(text, text, text, text, boolean, int, jsonb, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_formation_delete(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_formation_set_settings(boolean, boolean, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_formations_list(boolean) TO authenticated, anon;

ALTER TABLE public.gpsl_formations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpsl_formation_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpsl_formation_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_formations_read ON public.gpsl_formations;
CREATE POLICY gpsl_formations_read ON public.gpsl_formations
  FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS gpsl_formation_slots_read ON public.gpsl_formation_slots;
CREATE POLICY gpsl_formation_slots_read ON public.gpsl_formation_slots
  FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS gpsl_formation_settings_read ON public.gpsl_formation_settings;
CREATE POLICY gpsl_formation_settings_read ON public.gpsl_formation_settings
  FOR SELECT TO authenticated, anon USING (true);

-- ---------------------------------------------------------------------------
-- Seed current Match Day presets (upsert by code)
-- Direct inserts so SQL Editor (no JWT) can seed.
DO $seed$
DECLARE
  v_id uuid;
BEGIN
  -- 4-4-2
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-4-2'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-4-2', '4-4-2', 'Balanced, classic shape', 'Back-4', true, 0, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-4-2', description = 'Balanced, classic shape',
      group_label = 'Back-4', sort_order = 0, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'LMF', 14.0, 46.0, 5, true, ARRAY['LMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'CMF', 38.0, 50.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'RMF', 62.0, 50.0, 7, true, ARRAY['RMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RMF', 86.0, 46.0, 8, true, ARRAY['RMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'CF', 38.0, 18.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 62.0, 18.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 4-3-3
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-3-3'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-3-3', '4-3-3', 'High pressing, possession, wide play', 'Back-4', true, 10, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-3-3', description = 'High pressing, possession, wide play',
      group_label = 'Back-4', sort_order = 10, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 16.0, 48.0, 5, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'DMF', 50.0, 52.0, 6, false, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 84.0, 48.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'LWF', 22.0, 22.0, 8, true, ARRAY['LWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 12.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWF', 78.0, 22.0, 10, true, ARRAY['RWF']::text[]);
  END IF;
  -- 4-3-2-1
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-3-2-1'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-3-2-1', '4-3-2-1', 'Narrow "Christmas Tree", strong central buildup', 'Back-4', true, 20, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-3-2-1', description = 'Narrow "Christmas Tree", strong central buildup',
      group_label = 'Back-4', sort_order = 20, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 22.0, 52.0, 5, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'CMF', 50.0, 54.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 78.0, 52.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'AMF', 38.0, 32.0, 8, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'AMF', 62.0, 32.0, 9, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 12.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 4-3-1-2
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-3-1-2'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-3-1-2', '4-3-1-2', 'Central overload with AMF link play', 'Back-4', true, 30, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-3-1-2', description = 'Central overload with AMF link play',
      group_label = 'Back-4', sort_order = 30, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 22.0, 52.0, 5, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'CMF', 50.0, 54.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 78.0, 52.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'AMF', 50.0, 34.0, 8, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'SS', 38.0, 18.0, 9, true, ARRAY['SS']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 62.0, 18.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 4-2-3-1
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-2-3-1'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-2-3-1', '4-2-3-1', 'Flexible, wide or central transitions', 'Back-4', true, 40, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-2-3-1', description = 'Flexible, wide or central transitions',
      group_label = 'Back-4', sort_order = 40, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'DMF', 38.0, 54.0, 5, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'DMF', 62.0, 54.0, 6, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'LWF', 18.0, 32.0, 7, true, ARRAY['LWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'AMF', 50.0, 36.0, 8, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWF', 82.0, 32.0, 9, true, ARRAY['RWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 12.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 4-2-1-3
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-2-1-3'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-2-1-3', '4-2-1-3', 'Defensive midfield cover + structured buildup', 'Back-4', true, 50, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-2-1-3', description = 'Defensive midfield cover + structured buildup',
      group_label = 'Back-4', sort_order = 50, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'DMF', 38.0, 56.0, 5, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'DMF', 62.0, 56.0, 6, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'AMF', 50.0, 40.0, 7, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'LWF', 22.0, 20.0, 8, true, ARRAY['LWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 12.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWF', 78.0, 20.0, 10, true, ARRAY['RWF']::text[]);
  END IF;
  -- 4-1-4-1
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-1-4-1'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-1-4-1', '4-1-4-1', 'Strong defensive block with a single pivot', 'Back-4', true, 60, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-1-4-1', description = 'Strong defensive block with a single pivot',
      group_label = 'Back-4', sort_order = 60, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'DMF', 50.0, 56.0, 5, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'LMF', 14.0, 42.0, 6, true, ARRAY['LMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'CMF', 38.0, 44.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 62.0, 44.0, 8, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RMF', 86.0, 42.0, 9, true, ARRAY['RMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 14.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 4-1-2-3
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('4-1-2-3'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('4-1-2-3', '4-1-2-3', 'Aggressive, high-pressing, forward-loaded variant', 'Back-4', true, 70, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '4-1-2-3', description = 'Aggressive, high-pressing, forward-loaded variant',
      group_label = 'Back-4', sort_order = 70, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LB', 12.0, 68.0, 1, true, ARRAY['LB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 36.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 64.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'RB', 88.0, 68.0, 4, true, ARRAY['RB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'DMF', 50.0, 56.0, 5, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 36.0, 44.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 64.0, 44.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'LWF', 22.0, 20.0, 8, true, ARRAY['LWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 12.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWF', 78.0, 20.0, 10, true, ARRAY['RWF']::text[]);
  END IF;
  -- 3-4-3
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('3-4-3'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('3-4-3', '3-4-3', 'Wide, attacking, wing-driven', 'Back-3', true, 80, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '3-4-3', description = 'Wide, attacking, wing-driven',
      group_label = 'Back-3', sort_order = 80, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 28.0, 72.0, 1, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 50.0, 74.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'CB', 72.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LMF', 14.0, 48.0, 4, true, ARRAY['LMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 38.0, 50.0, 5, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 62.0, 50.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RMF', 86.0, 48.0, 7, true, ARRAY['RMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'LWF', 22.0, 20.0, 8, true, ARRAY['LWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 12.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'RWF', 78.0, 20.0, 10, true, ARRAY['RWF']::text[]);
  END IF;
  -- 3-2-4-1
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('3-2-4-1'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('3-2-4-1', '3-2-4-1', 'Midfield dominance, possession-heavy', 'Back-3', true, 90, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '3-2-4-1', description = 'Midfield dominance, possession-heavy',
      group_label = 'Back-3', sort_order = 90, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 28.0, 72.0, 1, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 50.0, 74.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'CB', 72.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'DMF', 38.0, 54.0, 4, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'DMF', 62.0, 54.0, 5, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LMF', 14.0, 42.0, 6, true, ARRAY['LMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'CMF', 36.0, 42.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'CMF', 50.0, 44.0, 8, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RMF', 86.0, 42.0, 9, true, ARRAY['RMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 14.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 3-2-3-2
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('3-2-3-2'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('3-2-3-2', '3-2-3-2', 'Balanced, with wide attacking options', 'Back-3', true, 100, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '3-2-3-2', description = 'Balanced, with wide attacking options',
      group_label = 'Back-3', sort_order = 100, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 28.0, 72.0, 1, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 50.0, 74.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'CB', 72.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 38.0, 50.0, 4, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 62.0, 50.0, 5, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LWF', 18.0, 30.0, 6, true, ARRAY['LWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'AMF', 50.0, 34.0, 7, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWF', 82.0, 30.0, 8, true, ARRAY['RWF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'CF', 38.0, 16.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 62.0, 16.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 3-1-4-2
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('3-1-4-2'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('3-1-4-2', '3-1-4-2', 'Central play, requires high-stamina wide mids', 'Back-3', true, 110, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '3-1-4-2', description = 'Central play, requires high-stamina wide mids',
      group_label = 'Back-3', sort_order = 110, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 28.0, 72.0, 1, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 50.0, 74.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'CB', 72.0, 72.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'DMF', 50.0, 54.0, 4, true, ARRAY['DMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LMF', 12.0, 42.0, 5, true, ARRAY['LMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 36.0, 44.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 64.0, 44.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RMF', 88.0, 42.0, 8, true, ARRAY['RMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'CF', 38.0, 16.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 62.0, 16.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 5-3-2
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('5-3-2'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('5-3-2', '5-3-2', 'Very solid defensively, counter-attack friendly', 'Back-5', true, 120, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '5-3-2', description = 'Very solid defensively, counter-attack friendly',
      group_label = 'Back-5', sort_order = 120, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LWB', 8.0, 58.0, 1, true, ARRAY['LWB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 30.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 50.0, 74.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'CB', 70.0, 72.0, 4, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWB', 92.0, 58.0, 5, true, ARRAY['RWB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 30.0, 46.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'CMF', 50.0, 48.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 70.0, 46.0, 8, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'CF', 38.0, 16.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 62.0, 16.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 5-2-2-1
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('5-2-2-1'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('5-2-2-1', '5-2-2-1', 'Defensive with wide counter-attacking threat', 'Back-5', true, 130, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '5-2-2-1', description = 'Defensive with wide counter-attacking threat',
      group_label = 'Back-5', sort_order = 130, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LWB', 8.0, 58.0, 1, true, ARRAY['LWB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 30.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 50.0, 74.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'CB', 70.0, 72.0, 4, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWB', 92.0, 58.0, 5, true, ARRAY['RWB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 38.0, 48.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 62.0, 48.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'AMF', 32.0, 30.0, 8, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'AMF', 68.0, 30.0, 9, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 50.0, 12.0, 10, true, ARRAY['CF']::text[]);
  END IF;
  -- 5-2-1-2
  SELECT id INTO v_id FROM public.gpsl_formations
  WHERE lower(btrim(code)) = lower(btrim('5-2-1-2'));
  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_formations (code, name, description, group_label, is_enabled, sort_order, source)
    VALUES ('5-2-1-2', '5-2-1-2', 'Compact, central counter-attacking shape', 'Back-5', true, 140, 'seed')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_formations SET
      name = '5-2-1-2', description = 'Compact, central counter-attacking shape',
      group_label = 'Back-5', sort_order = 140, updated_at = now()
    WHERE id = v_id;
    DELETE FROM public.gpsl_formation_slots WHERE formation_id = v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_formation_slots WHERE formation_id = v_id) THEN
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'GK', 'GK', 50.0, 86.0, 0, true, ARRAY['GK']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LB', 'LWB', 8.0, 58.0, 1, true, ARRAY['LWB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB1', 'CB', 30.0, 72.0, 2, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CB2', 'CB', 50.0, 74.0, 3, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RB', 'CB', 70.0, 72.0, 4, true, ARRAY['CB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RWF', 'RWB', 92.0, 58.0, 5, true, ARRAY['RWB']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LMF', 'CMF', 38.0, 48.0, 6, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'RMF', 'CMF', 62.0, 48.0, 7, true, ARRAY['CMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CMF', 'AMF', 50.0, 34.0, 8, true, ARRAY['AMF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'LWF', 'CF', 38.0, 16.0, 9, true, ARRAY['CF']::text[]);
    INSERT INTO public.gpsl_formation_slots (formation_id, slot_key, default_position, x, y, sort_order, allow_relabel, allowed_positions) VALUES (v_id, 'CF', 'CF', 62.0, 16.0, 10, true, ARRAY['CF']::text[]);
  END IF;
END;
$seed$;

NOTIFY pgrst, 'reload schema';
