#!/usr/bin/env python3
"""Bundle club_kits_cof.js into index.ts for single-file Supabase Dashboard deploy."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
COF = ROOT / "club_kits_cof.js"
HANDLER = ROOT / "supabase/functions/club-kits-cof-sync/handler.ts"
OUT = ROOT / "supabase/functions/club-kits-cof-sync/index.ts"

CREATE_IMPORT = 'import { createClient } from "npm:@supabase/supabase-js@2";'
RUNTIME_IMPORT = 'import "jsr:@supabase/functions-js/edge-runtime.d.ts";'


def strip_exports(text: str) -> str:
    text = text.replace("export const ", "const ")
    text = text.replace("export function ", "function ")
    text = text.replace("export async function ", "async function ")
    return text


def extract_handler_source() -> str:
    """Read handler body (cors + Deno.serve) from handler.ts or legacy index.ts."""
    if HANDLER.exists():
        raw = HANDLER.read_text(encoding="utf-8")
        if CREATE_IMPORT in raw:
            return raw.split(CREATE_IMPORT, 1)[1].lstrip("\n")
        return raw

    raw = OUT.read_text(encoding="utf-8")
    m = re.search(r"\nconst corsHeaders = \{", raw)
    if not m:
        raise SystemExit("Could not find handler section (const corsHeaders)")
    return raw[m.start() + 1 :]


def main() -> None:
    cof = strip_exports(COF.read_text(encoding="utf-8"))
    handler = extract_handler_source()

    out = (
        "// GPSL club-kits-cof-sync — single file for Supabase Dashboard deploy\n"
        "// Re-bundle: python scripts/bundle_club_kits_edge.py\n\n"
        f"{RUNTIME_IMPORT}\n"
        f"{CREATE_IMPORT}\n\n"
        f"{cof.rstrip()}\n\n"
        f"{handler.lstrip()}"
    )

    OUT.write_text(out, encoding="utf-8")
    print(f"Wrote bundled {OUT} ({len(out)} chars)")


if __name__ == "__main__":
    main()
