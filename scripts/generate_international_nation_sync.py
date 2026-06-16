#!/usr/bin/env python3
"""
Build international nation catalog + SQL sync patch + flag slug map.

Usage (repo root):
  python scripts/generate_international_nation_sync.py
"""

from __future__ import annotations

import json
import re
import textwrap
from pathlib import Path

import pycountry

ROOT = Path(__file__).resolve().parents[1]
DATA_PATH = ROOT / "data" / "international_nation_catalog.json"
SQL_PATH = ROOT / "supabase" / "sql" / "patches" / "international_sync_gpdb_nations.sql"
FLAGS_PATH = ROOT / "international_flags.js"

# Existing GPSL 60 — keep these codes; extra aliases help GPDB label matching.
EXISTING = {
    "ARG": {"a2": "ar", "aliases": ["Argentina"]},
    "FRA": {"a2": "fr", "aliases": ["France"]},
    "BRA": {"a2": "br", "aliases": ["Brazil"]},
    "ENG": {"a2": "gb-eng", "aliases": ["England"]},
    "BEL": {"a2": "be", "aliases": ["Belgium"]},
    "POR": {"a2": "pt", "aliases": ["Portugal"]},
    "NED": {"a2": "nl", "aliases": ["Netherlands", "Holland"]},
    "ESP": {"a2": "es", "aliases": ["Spain"]},
    "ITA": {"a2": "it", "aliases": ["Italy"]},
    "CRO": {"a2": "hr", "aliases": ["Croatia"]},
    "URU": {"a2": "uy", "aliases": ["Uruguay"]},
    "MAR": {"a2": "ma", "aliases": ["Morocco"]},
    "COL": {"a2": "co", "aliases": ["Colombia"]},
    "GER": {"a2": "de", "aliases": ["Germany"]},
    "MEX": {"a2": "mx", "aliases": ["Mexico"]},
    "USA": {"a2": "us", "aliases": ["United States", "USA", "United States of America"]},
    "SUI": {"a2": "ch", "aliases": ["Switzerland"]},
    "JPN": {"a2": "jp", "aliases": ["Japan"]},
    "SEN": {"a2": "sn", "aliases": ["Senegal"]},
    "IRN": {"a2": "ir", "aliases": ["IR Iran", "Iran"]},
    "DEN": {"a2": "dk", "aliases": ["Denmark"]},
    "KOR": {"a2": "kr", "aliases": ["Korea Republic", "South Korea", "Republic of Korea"]},
    "AUS": {"a2": "au", "aliases": ["Australia"]},
    "UKR": {"a2": "ua", "aliases": ["Ukraine"]},
    "TUR": {"a2": "tr", "aliases": ["Türkiye", "Turkiye", "Turkey"]},
    "ECU": {"a2": "ec", "aliases": ["Ecuador"]},
    "POL": {"a2": "pl", "aliases": ["Poland"]},
    "SRB": {"a2": "rs", "aliases": ["Serbia"]},
    "WAL": {"a2": "gb-wls", "aliases": ["Wales"]},
    "CAN": {"a2": "ca", "aliases": ["Canada"]},
    "GHA": {"a2": "gh", "aliases": ["Ghana"]},
    "NOR": {"a2": "no", "aliases": ["Norway"]},
    "PAR": {"a2": "py", "aliases": ["Paraguay"]},
    "CRC": {"a2": "cr", "aliases": ["Costa Rica"]},
    "EGY": {"a2": "eg", "aliases": ["Egypt"]},
    "ALG": {"a2": "dz", "aliases": ["Algeria"]},
    "SCO": {"a2": "gb-sct", "aliases": ["Scotland"]},
    "AUT": {"a2": "at", "aliases": ["Austria"]},
    "HUN": {"a2": "hu", "aliases": ["Hungary"]},
    "CZE": {"a2": "cz", "aliases": ["Czechia", "Czech Republic"]},
    "NGA": {"a2": "ng", "aliases": ["Nigeria"]},
    "PAN": {"a2": "pa", "aliases": ["Panama"]},
    "TUN": {"a2": "tn", "aliases": ["Tunisia"]},
    "PER": {"a2": "pe", "aliases": ["Peru"]},
    "CHI": {"a2": "cl", "aliases": ["Chile"]},
    "ROU": {"a2": "ro", "aliases": ["Romania"]},
    "SVK": {"a2": "sk", "aliases": ["Slovakia"]},
    "SWE": {"a2": "se", "aliases": ["Sweden"]},
    "FIN": {"a2": "fi", "aliases": ["Finland"]},
    "IRL": {"a2": "ie", "aliases": ["Republic of Ireland", "Ireland"]},
    "CMR": {"a2": "cm", "aliases": ["Cameroon"]},
    "RSA": {"a2": "za", "aliases": ["South Africa"]},
    "JAM": {"a2": "jm", "aliases": ["Jamaica"]},
    "BOL": {"a2": "bo", "aliases": ["Bolivia"]},
    "VEN": {"a2": "ve", "aliases": ["Venezuela"]},
    "IRQ": {"a2": "iq", "aliases": ["Iraq"]},
    "QAT": {"a2": "qa", "aliases": ["Qatar"]},
    "KSA": {"a2": "sa", "aliases": ["Saudi Arabia"]},
    "NZL": {"a2": "nz", "aliases": ["New Zealand"]},
    "CHN": {"a2": "cn", "aliases": ["China PR", "China", "People's Republic of China"]},
}

# ISO 3166-1 alpha-3 -> existing GPSL nation code (when they differ)
ISO3_TO_GPSL = {
    "DEU": "GER",
    "ZAF": "RSA",
    "SAU": "KSA",
    "CHL": "CHI",
    "CRI": "CRC",
    "URY": "URU",
    "NLD": "NED",
    "CHE": "SUI",
    "DNK": "DEN",
    "PRT": "POR",
    "HRV": "CRO",
    "PRY": "PAR",
    "DZA": "ALG",
    "IRN": "IRN",
    "KOR": "KOR",
    "CHN": "CHN",
}
ISO3_TO_GPSL.update({code: code for code in EXISTING})

EXTRA_ISO3 = {
    "GRC": "GRE",
    "COG": "CGO",
    "MKD": "MKD",
    "TZA": "TAN",
    "VNM": "VIE",
    "MMR": "MYA",
    "KHM": "CAM",
    "PSE": "PLE",
    "XKX": "KOS",
}
EXTRA_ENTRIES = {
    "GRE": {"a2": "gr", "aliases": ["Greece"]},
    "NIR": {"a2": "gb-nir", "aliases": ["Northern Ireland"]},
    "KOS": {"a2": "xk", "aliases": ["Kosovo"]},
    "TPE": {"a2": "tw", "aliases": ["Chinese Taipei", "Taiwan"]},
    "PLE": {"a2": "ps", "aliases": ["Palestine"]},
    "CGO": {"a2": "cg", "aliases": ["Congo", "Congo Republic", "Republic of the Congo"]},
    "COD": {"a2": "cd", "aliases": ["DR Congo", "Democratic Republic of the Congo", "Congo DR"]},
    "VIE": {"a2": "vn", "aliases": ["Vietnam", "Viet Nam"]},
    "MYA": {"a2": "mm", "aliases": ["Myanmar", "Burma"]},
    "BRU": {"a2": "bn", "aliases": ["Brunei", "Brunei Darussalam"]},
    "CAM": {"a2": "kh", "aliases": ["Cambodia"]},
    "PRK": {"a2": "kp", "aliases": ["Korea DPR", "North Korea", "Korea Democratic People's Republic"]},
    "TAN": {"a2": "tz", "aliases": ["Tanzania"]},
    "CIV": {"a2": "ci", "aliases": ["Côte d'Ivoire", "Cote d'Ivoire", "Ivory Coast"]},
    "MKD": {"a2": "mk", "aliases": ["North Macedonia", "Macedonia"]},
    "GBR": {"a2": "gb", "aliases": ["Great Britain", "United Kingdom", "UK"]},
}


def normalize_label(text: str) -> str:
    s = (text or "").strip()
    s = re.sub(r"\s+", "", s)
    s = re.sub(r"[^A-Za-z]", "", s)
    return s.upper()


def alpha2_to_emoji(a2: str) -> str:
    if not a2 or len(a2) < 2 or a2.startswith("gb-"):
        return "🏳️"
    pair = a2[:2].upper()
    if not pair.isalpha():
        return "🏳️"
    return "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in pair)


def sql_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def build_catalog() -> list[dict]:
    by_code: dict[str, dict] = {}

    def add_entry(code: str, a2: str, aliases: list[str], emoji: str | None = None) -> None:
        code = code.upper()
        if len(code) != 3 or not code.isalpha():
            return
        flag = emoji or alpha2_to_emoji(a2)
        alias_set = {a.strip() for a in aliases if a and a.strip()}
        alias_set.add(code)
        if code in by_code:
            by_code[code]["aliases"] = sorted(set(by_code[code]["aliases"]) | alias_set)
            return
        by_code[code] = {
            "code": code,
            "flagcdn_slug": a2.lower(),
            "flag_emoji": flag,
            "aliases": sorted(alias_set),
        }

    for code, meta in EXISTING.items():
        add_entry(code, meta["a2"], meta["aliases"])

    for code, meta in EXTRA_ENTRIES.items():
        add_entry(code, meta["a2"], meta["aliases"])

    for country in pycountry.countries:
        iso3 = country.alpha_3
        code = EXTRA_ISO3.get(iso3, ISO3_TO_GPSL.get(iso3, iso3))
        names = {country.name}
        if getattr(country, "official_name", None):
            names.add(country.official_name)
        if getattr(country, "common_name", None):
            names.add(country.common_name)
        if code in by_code:
            by_code[code]["aliases"] = sorted(set(by_code[code]["aliases"]) | names)
            continue
        add_entry(code, country.alpha_2.lower(), sorted(names))

    return sorted(by_code.values(), key=lambda x: x["code"])


def render_flags_js(catalog: list[dict]) -> str:
    lines = []
    for row in catalog:
        slug = row["flagcdn_slug"]
        lines.append(f'  {row["code"]}: "{slug}",')
    body = "\n".join(lines)
    return f"""/**
 * GPSL international nation flag images (images/flags/{{CODE}}.png or flagcdn fallback).
 * Slugs match flagcdn.com (ISO 3166-1 alpha-2 or UK subdivisions).
 * Generated by scripts/generate_international_nation_sync.py — do not edit by hand.
 */

/** @type {{Record<string, string>}} */
export const FLAGCDN_SLUG_BY_CODE = {{
{body}
}};

export function nationFlagCode(nationOrCode) {{
  if (!nationOrCode) return null;
  if (typeof nationOrCode === "string") return nationOrCode.trim().toUpperCase() || null;
  const code = nationOrCode.code ?? nationOrCode.nation_code;
  return code ? String(code).trim().toUpperCase() : null;
}}

export function nationFlagCdnSrc(code) {{
  const slug = code && FLAGCDN_SLUG_BY_CODE[code];
  return slug ? `https://flagcdn.com/w40/${{slug}}.png` : null;
}}

export function nationFlagSrc(nationOrCode) {{
  const code = nationFlagCode(nationOrCode);
  if (!code || !FLAGCDN_SLUG_BY_CODE[code]) return null;
  return `images/flags/${{code}}.png`;
}}

export function renderNationFlag(nation, size = "lg") {{
  const code = nationFlagCode(nation);
  const emoji =
    (typeof nation === "object" && nation?.flag_emoji) || "🏳️";
  const sizeCls = size === "sm" ? "nat-flag-sm" : "nat-flag-lg";
  const localSrc = nationFlagSrc(code);
  const cdnSrc = nationFlagCdnSrc(code);

  if (localSrc || cdnSrc) {{
    const alt = typeof nation === "object" && nation?.name ? nation.name : code || "Nation";
    const primary = localSrc || cdnSrc;
    const fallback = localSrc && cdnSrc && localSrc !== cdnSrc ? cdnSrc : null;
    const onerr = fallback
      ? `this.onerror=null;this.src='${{fallback}}';`
      : `this.style.display='none';this.nextElementSibling?.classList.remove('nat-flag-fallback-hidden');`;
    return (
      `<img class="nat-flag-img ${{sizeCls}}" src="${{primary}}" alt="${{escapeAttr(alt)}} flag" loading="lazy" ` +
      `onerror="${{onerr}}" />` +
      `<span class="nat-flag nat-flag-fallback ${{sizeCls}} nat-flag-fallback-hidden" aria-hidden="true">${{emoji}}</span>`
    );
  }}

  return `<span class="nat-flag ${{sizeCls}}" aria-hidden="true">${{emoji}}</span>`;
}}

function escapeAttr(text) {{
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}}
"""


def render_sql(catalog: list[dict]) -> str:
    catalog_json = json.dumps(catalog, ensure_ascii=False)
    values = []
    for row in catalog:
        aliases_sql = "ARRAY[" + ", ".join(sql_quote(a) for a in row["aliases"]) + "]::text[]"
        values.append(
            f"  ({sql_quote(row['code'])}, {sql_quote(row['flag_emoji'])}, "
            f"{sql_quote(row['flagcdn_slug'])}, {aliases_sql})"
        )
    values_sql = ",\n".join(values)

    return textwrap.dedent(
        f"""\
        -- =============================================================================
        -- Sync GPDB Players.Nation labels into international_nations (nation select / pool)
        -- Run after competition_international.sql + international_callup_gpdb.sql
        -- Safe re-run. Then: SELECT public.international_sync_gpdb_nations();
        -- =============================================================================

        CREATE TABLE IF NOT EXISTS public.international_nation_catalog (
          code text PRIMARY KEY CHECK (code ~ '^[A-Z]{{3}}$'),
          flag_emoji text NOT NULL DEFAULT '🏳️',
          flagcdn_slug text,
          aliases text[] NOT NULL DEFAULT '{{}}'::text[]
        );

        TRUNCATE public.international_nation_catalog;

        INSERT INTO public.international_nation_catalog (code, flag_emoji, flagcdn_slug, aliases)
        VALUES
        {values_sql}
        ;

        CREATE OR REPLACE FUNCTION public.international_catalog_match_code(p_label text)
        RETURNS text
        LANGUAGE sql
        STABLE
        SET search_path = public
        AS $$
          SELECT c.code
          FROM public.international_nation_catalog c
          WHERE public.international_normalize_nation_label(p_label) = ANY (
            SELECT public.international_normalize_nation_label(a)
            FROM unnest(c.aliases) AS a
          )
          ORDER BY length(c.code)
          LIMIT 1;
        $$;

        CREATE OR REPLACE FUNCTION public.international_gpdb_matches_nation(
          p_gpdb_label text,
          p_nation_code text
        )
        RETURNS boolean
        LANGUAGE sql
        STABLE
        SET search_path = public
        AS $$
          SELECT EXISTS (
            SELECT 1
            FROM public.international_nations n
            WHERE n.code = upper(btrim(p_nation_code))
              AND n.active = true
              AND (
                public.international_normalize_nation_label(p_gpdb_label)
                  = public.international_normalize_nation_label(n.name)
                OR public.international_normalize_nation_label(p_gpdb_label)
                  = upper(n.code)
                OR public.international_catalog_match_code(p_gpdb_label) = n.code
              )
          );
        $$;

        CREATE OR REPLACE FUNCTION public.international_generate_nation_code(p_label text)
        RETURNS text
        LANGUAGE plpgsql
        STABLE
        SET search_path = public
        AS $function$
        DECLARE
          v_base text;
          v_code text;
          v_i integer := 0;
        BEGIN
          v_base := left(public.international_normalize_nation_label(p_label), 3);
          IF v_base IS NULL OR v_base = '' THEN
            v_base := 'XXX';
          END IF;
          v_code := v_base;
          WHILE EXISTS (
            SELECT 1 FROM public.international_nations n WHERE n.code = v_code
          ) OR EXISTS (
            SELECT 1 FROM public.international_nation_catalog c WHERE c.code = v_code
          ) LOOP
            v_i := v_i + 1;
            v_code := left(v_base, greatest(1, 3 - length(v_i::text))) || v_i::text;
            IF length(v_code) > 3 THEN
              v_code := right(md5(p_label || v_i::text), 3);
              v_code := upper(regexp_replace(v_code, '[^A-Z]', 'X', 'g'));
            END IF;
            EXIT WHEN v_i > 99;
          END LOOP;
          RETURN v_code;
        END;
        $function$;

        CREATE OR REPLACE FUNCTION public.international_sync_gpdb_nations()
        RETURNS jsonb
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = public
        AS $function$
        DECLARE
          v_row record;
          v_code text;
          v_emoji text;
          v_rank integer;
          v_inserted integer := 0;
          v_skipped integer := 0;
        BEGIN
          IF NOT public.is_gpsl_admin()
             AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
            RAISE EXCEPTION 'Admin only';
          END IF;

          SELECT coalesce(max(seed_rank), 0) INTO v_rank FROM public.international_nations;

          FOR v_row IN
            SELECT
              p."Nation" AS label,
              count(*)::integer AS players
            FROM public."Players" p
            WHERE btrim(coalesce(p."Nation", '')) <> ''
              AND NOT EXISTS (
                SELECT 1
                FROM public.international_nations n
                WHERE n.active = true
                  AND public.international_gpdb_matches_nation(p."Nation", n.code)
              )
            GROUP BY p."Nation"
            ORDER BY players DESC, p."Nation"
          LOOP
            v_code := public.international_catalog_match_code(v_row.label);

            IF v_code IS NULL THEN
              v_code := public.international_generate_nation_code(v_row.label);
              v_emoji := '🏳️';
            ELSE
              SELECT c.flag_emoji INTO v_emoji
              FROM public.international_nation_catalog c
              WHERE c.code = v_code;
            END IF;

            IF EXISTS (
              SELECT 1 FROM public.international_nations n WHERE n.code = v_code
            ) THEN
              v_skipped := v_skipped + 1;
              CONTINUE;
            END IF;

            v_rank := v_rank + 1;
            INSERT INTO public.international_nations (code, name, flag_emoji, seed_rank, active)
            VALUES (v_code, v_row.label, coalesce(v_emoji, '🏳️'), v_rank, true);
            v_inserted := v_inserted + 1;
          END LOOP;

          RETURN jsonb_build_object(
            'inserted', v_inserted,
            'skipped_existing_code', v_skipped,
            'active_nations', (SELECT count(*) FROM public.international_nations WHERE active = true)
          );
        END;
        $function$;

        -- Nation select UI: total active nations + draft order size
        DROP VIEW IF EXISTS public.international_selection_public;
        CREATE VIEW public.international_selection_public
        WITH (security_invoker = false)
        AS
        SELECT
          w.id,
          w.phase,
          w.is_open,
          w.opens_at,
          w.closes_at,
          w.current_pick_rank,
          (
            SELECT d.club_short_name
            FROM public.international_owner_draft_order() d
            WHERE d.pick_order = w.current_pick_rank
            LIMIT 1
          ) AS current_pick_club,
          (
            SELECT count(*)::integer
            FROM public.international_owner_nations ion
            WHERE ion.is_active = true
          ) AS nations_assigned,
          (
            SELECT count(*)::integer
            FROM public.international_owner_draft_order()
          ) AS draft_order_size,
          (
            SELECT count(*)::integer
            FROM public.international_nations n
            WHERE n.active = true
          ) AS nations_total
        FROM public.international_selection_windows w
        WHERE w.is_open = true
        ORDER BY w.id DESC
        LIMIT 1;

        CREATE OR REPLACE FUNCTION public.international_player_matches_nation(
          p_player_id text,
          p_nation_code text
        )
        RETURNS boolean
        LANGUAGE sql
        STABLE
        SET search_path = public
        AS $$
          SELECT EXISTS (
            SELECT 1
            FROM public."Players" p
            JOIN public.international_nations n ON n.code = upper(btrim(p_nation_code))
            WHERE p."Konami_ID"::text = btrim(p_player_id)
              AND n.active = true
              AND public.international_gpdb_matches_nation(p."Nation", n.code)
          );
        $$;

        GRANT SELECT ON public.international_nation_catalog TO authenticated;
        GRANT EXECUTE ON FUNCTION public.international_sync_gpdb_nations() TO authenticated;
        GRANT EXECUTE ON FUNCTION public.international_catalog_match_code(text) TO authenticated;
        GRANT EXECUTE ON FUNCTION public.international_gpdb_matches_nation(text, text) TO authenticated;

        NOTIFY pgrst, 'reload schema';
        """
    )


def main() -> None:
    catalog = build_catalog()
    DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
    DATA_PATH.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    SQL_PATH.write_text(render_sql(catalog), encoding="utf-8")
    FLAGS_PATH.write_text(render_flags_js(catalog), encoding="utf-8")
    print(f"Catalog entries: {len(catalog)}")
    print(f"Wrote {DATA_PATH.relative_to(ROOT)}")
    print(f"Wrote {SQL_PATH.relative_to(ROOT)}")
    print(f"Wrote {FLAGS_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
