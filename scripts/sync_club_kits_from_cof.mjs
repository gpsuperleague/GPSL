#!/usr/bin/env node
/**
 * Download latest COF kit PNGs into images/clubs_kits/ and upsert club_kits paths.
 *
 * Usage:
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/sync_club_kits_from_cof.mjs
 */

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";
import {
  fetchLatestCofKits,
  downloadCofImage,
} from "../club_kits_cof.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const OUT_DIR = path.join(ROOT, "images", "clubs_kits");

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!url || !key) {
  console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
  process.exit(1);
}

const supabase = createClient(url, key);

async function main() {
  await fs.mkdir(OUT_DIR, { recursive: true });

  const { data: clubs, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club, Nation")
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error) throw error;

  let ok = 0;
  let fail = 0;

  for (const club of clubs || []) {
    const short = club.ShortName;
    process.stdout.write(`${short} … `);

    try {
      const cof = await fetchLatestCofKits(club.Nation, club.Club, short);
      if (cof.error) throw new Error(cof.error);

      const paths = { home: null, away: null, third: null };

      for (const [kind, src] of Object.entries(cof.kits || {})) {
        if (!src) continue;
        const { bytes } = await downloadCofImage(src);
        const rel = `images/clubs_kits/${short}_${kind}.png`;
        const abs = path.join(ROOT, rel);
        await fs.writeFile(abs, bytes);
        paths[kind] = rel;
      }

      const { error: saveErr } = await supabase.from("club_kits").upsert(
        {
          club_short_name: short,
          home_image_url: paths.home,
          away_image_url: paths.away,
          third_image_url: paths.third,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "club_short_name" }
      );
      if (saveErr) throw saveErr;

      console.log("ok");
      ok += 1;
    } catch (err) {
      console.log(`fail — ${err.message}`);
      fail += 1;
    }
  }

  console.log(`\nDone: ${ok} ok, ${fail} failed`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
