#!/usr/bin/env node
/**
 * Export active international nations (nation select / player pool list).
 *
 * Usage (from repo root):
 *   node scripts/export_international_nations.mjs
 *   node scripts/export_international_nations.mjs -o international_nations_list.txt
 *   node scripts/export_international_nations.mjs --tsv
 */

import { writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { createClient } from "@supabase/supabase-js";
import { readSupabaseConfig } from "./lib/supabaseFromRepo.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

function parseArgs(argv) {
  const out = { output: join(root, "international_nations_list.txt"), tsv: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--tsv") out.tsv = true;
    else if (a === "-o" || a === "--output") {
      out.output = argv[++i];
      if (!out.output) throw new Error("Missing path after -o");
    } else if (a === "-h" || a === "--help") {
      console.log(
        "Usage: node scripts/export_international_nations.mjs [-o file.txt] [--tsv]"
      );
      process.exit(0);
    } else {
      throw new Error(`Unknown option: ${a}`);
    }
  }
  return out;
}

const args = parseArgs(process.argv);
const { url, anonKey } = readSupabaseConfig(root);
const supabase = createClient(url, anonKey);

const { data, error } = await supabase
  .from("international_nations_public")
  .select("code, name, seed_rank")
  .order("seed_rank", { ascending: true });

if (error) {
  console.error(error.message);
  process.exit(1);
}

const lines = (data || []).map((row) =>
  args.tsv
    ? `${row.code}\t${row.name}\t${row.seed_rank}`
    : `${row.seed_rank}. ${row.code} — ${row.name}`
);

writeFileSync(args.output, `${lines.join("\n")}\n`, "utf8");
console.log(`Wrote ${lines.length} nations to ${args.output}`);
