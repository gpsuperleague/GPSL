#!/usr/bin/env node
/**
 * Regenerate data/manager_portraits.json from images/managers/*.{jpg,png}
 * Run after fetch_manager_images.mjs or when adding portraits manually.
 */
import { readdirSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dir = join(root, "images", "managers");
const out = join(root, "data", "manager_portraits.json");

if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

const slugs = new Set();
for (const name of readdirSync(dir)) {
  const m = name.match(/^(.+)\.(jpe?g|png)$/i);
  if (m) slugs.add(m[1].toLowerCase());
}

writeFileSync(
  out,
  JSON.stringify({ slugs: [...slugs].sort() }, null, 2) + "\n",
  "utf8"
);
console.log(`manager_portraits.json — ${slugs.size} slug(s)`);
