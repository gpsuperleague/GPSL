#!/usr/bin/env python3
"""Bundle club_kits_cof.js + wiki_football_kits.js into index.ts for Dashboard deploy."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COF = ROOT / "club_kits_cof.js"
WIKI = ROOT / "wiki_football_kits.js"
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
    raw = HANDLER.read_text(encoding="utf-8")
    if CREATE_IMPORT in raw:
        raw = raw.split(CREATE_IMPORT, 1)[1].lstrip("\n")
    # Strip leftover Image import if present
    raw = raw.replace('import { Image } from "npm:imagescript@1.3.0";\n', "")
    raw = raw.replace('import { Image } from "npm:imagescript@1.3.0";', "")
    return raw.lstrip("\n")


def main() -> None:
    cof = strip_exports(COF.read_text(encoding="utf-8"))
    wiki = strip_exports(WIKI.read_text(encoding="utf-8"))
    handler = extract_handler_source()

    out = (
        "// GPSL club-kits-cof-sync — single file for Supabase Dashboard deploy\n"
        "// Re-bundle: python scripts/bundle_club_kits_edge.py\n\n"
        f"{RUNTIME_IMPORT}\n"
        f"{CREATE_IMPORT}\n\n"
        f"{cof.rstrip()}\n\n"
        f"{wiki.rstrip()}\n\n"
        f"{handler.lstrip()}"
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(out, encoding="utf-8")
    print(f"Wrote bundled {OUT} ({len(out)} chars)")


if __name__ == "__main__":
    main()
