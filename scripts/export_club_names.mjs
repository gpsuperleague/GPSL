#!/usr/bin/env node
/**
 * Export GPSL club names — one per line (single column text).
 *
 * Usage (from repo root):
 *   node scripts/export_club_names.mjs
 *   node scripts/export_club_names.mjs -o club_names.txt
 *   node scripts/export_club_names.mjs --short          # ShortName codes instead of Club
 *   node scripts/export_club_names.mjs --include-foreign
 *
 * Reads Supabase URL/key from supabase_client.js (anon key — public Clubs read).
 */

import { writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { createClient } from "@supabase/supabase-js";
import { readSupabaseConfig } from "./lib/supabaseFromRepo.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

function parseArgs(argv) {
  const out = {
    output: join(root, "club_names.txt"),
    short: false,
    includeForeign: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--short") out.short = true;
    else if (a === "--include-foreign") out.includeForeign = true;
    else if (a === "-o" || a === "--output") {
      out.output = argv[++i];
      if (!out.output) throw new Error("Missing path after -o");
    } else if (a === "-h" || a === "--help") {
      console.log(`Usage: node scripts/export_club_names.mjs [-o file.txt] [--short] [--include-foreign]`);
      process.exit(0);
    } else {
      throw new Error(`Unknown option: ${a}`);
    }
  }
  return out;
}

async function main() {
  const opts = parseArgs(process.argv);
  const { url, anonKey } = readSupabaseConfig();
  const supabase = createClient(url, anonKey);

  let query = supabase.from("Clubs").select("ShortName, Club").order("Club", { ascending: true });
  if (!opts.includeForeign) {
    query = query.neq("ShortName", "FOREIGN");
  }

  const { data, error } = await query;
  if (error) throw error;

  const lines = (data || [])
    .map((row) => (opts.short ? row.ShortName : row.Club))
    .filter(Boolean);

  const text = `${lines.join("\n")}\n`;
  writeFileSync(opts.output, text, "utf8");
  console.log(`Wrote ${lines.length} club name${lines.length === 1 ? "" : "s"} → ${opts.output}`);
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
