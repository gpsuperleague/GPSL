import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

export function readSupabaseConfig() {
  const txt = readFileSync(join(root, "supabase_client.js"), "utf8");
  const m = txt.match(
    /createClient\(\s*\n?\s*"([^"]+)",\s*\n?\s*"([^"]+)"/
  );
  if (!m) throw new Error("Could not parse supabase_client.js");
  return { url: m[1], anonKey: m[2] };
}
