import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("csvFile")?.addEventListener("change", onFilePicked);
  document.getElementById("clearBtn")?.addEventListener("click", () => {
    const ta = document.getElementById("importCsv");
    const file = document.getElementById("csvFile");
    if (ta) ta.value = "";
    if (file) file.value = "";
    const out = document.getElementById("previewOut");
    if (out) out.textContent = "";
    setStatus("importStatus", "");
  });
  document.getElementById("previewBtn")?.addEventListener("click", () => runImport(false));
  document.getElementById("applyBtn")?.addEventListener("click", () => runImport(true));
});

async function onFilePicked(e) {
  const file = e.target?.files?.[0];
  if (!file) return;
  const text = await file.text();
  const ta = document.getElementById("importCsv");
  if (ta) ta.value = text;
  setStatus("importStatus", `Loaded ${file.name} (${text.split(/\r?\n/).length} lines). Preview before apply.`, true);
}

/** Minimal CSV parser: handles quotes and commas. */
export function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let inQuotes = false;
  const s = String(text || "").replace(/^\uFEFF/, "");

  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    const next = s[i + 1];
    if (inQuotes) {
      if (ch === '"' && next === '"') {
        cell += '"';
        i++;
      } else if (ch === '"') {
        inQuotes = false;
      } else {
        cell += ch;
      }
      continue;
    }
    if (ch === '"') {
      inQuotes = true;
      continue;
    }
    if (ch === ",") {
      row.push(cell);
      cell = "";
      continue;
    }
    if (ch === "\n" || (ch === "\r" && next === "\n")) {
      row.push(cell);
      cell = "";
      if (row.some((c) => String(c).trim() !== "")) rows.push(row);
      row = [];
      if (ch === "\r") i++;
      continue;
    }
    if (ch === "\r") {
      row.push(cell);
      cell = "";
      if (row.some((c) => String(c).trim() !== "")) rows.push(row);
      row = [];
      continue;
    }
    cell += ch;
  }
  row.push(cell);
  if (row.some((c) => String(c).trim() !== "")) rows.push(row);
  return rows;
}

function rowsToObjects(csvRows) {
  if (!csvRows?.length) return [];
  const headers = csvRows[0].map((h) => String(h || "").trim());
  const out = [];
  for (let r = 1; r < csvRows.length; r++) {
    const line = csvRows[r];
    if (!line?.length) continue;
    const obj = {};
    let any = false;
    for (let c = 0; c < headers.length; c++) {
      const key = headers[c];
      if (!key) continue;
      const val = line[c] != null ? String(line[c]).trim() : "";
      if (val !== "") any = true;
      obj[key] = val;
    }
    if (any) out.push(obj);
  }
  return out;
}

function formatPreview(data) {
  if (!data) return "No data.";
  const lines = [
    `Rows in file: ${data.input_rows ?? "?"}`,
    `Unique slugs: ${data.unique_slugs ?? "?"}`,
    `Duplicate slugs skipped: ${data.duplicate_slugs_skipped ?? 0}`,
    `Would insert: ${data.would_insert ?? data.inserted ?? 0}`,
    `Would update: ${data.would_update ?? data.updated ?? 0}`,
    `Renames (name/slug): ${data.would_rename ?? data.renamed ?? 0}`,
    `Unchanged: ${data.unchanged ?? 0}`,
  ];
  if (data.clubs_manager_rating_synced != null) {
    lines.push(`Clubs manager_rating synced: ${data.clubs_manager_rating_synced}`);
  }
  if (data.note) lines.push(`\n${data.note}`);
  if (data.retained) {
    lines.push("\nRetained: contracts, signed wages, ids, career stints, listings/bids.");
  }
  const errors = Array.isArray(data.errors) ? data.errors : [];
  if (errors.length) {
    lines.push(`\nErrors (${errors.length}):`);
    for (const e of errors.slice(0, 20)) {
      lines.push(`  row ${e.row}: ${e.error}${e.name ? ` (${e.name})` : ""}`);
    }
  }
  const samples = Array.isArray(data.samples) ? data.samples : [];
  if (samples.length) {
    lines.push("\nSamples:");
    for (const s of samples) {
      if (s.action === "insert") {
        lines.push(
          `  + ${s.name} [${s.slug}] rating ${s.rating} MV ${formatMoney(s.market_value)}`
        );
      } else {
        lines.push(
          `  ~ ${s.name}` +
            (s.name_before && s.name_before !== s.name ? ` (was ${s.name_before})` : "") +
            ` [${s.slug}]` +
            (s.contracted_club ? ` @ ${s.contracted_club}` : " (FA)") +
            ` rating ${s.rating_before}→${s.rating_after}` +
            (s.overload_after != null
              ? ` overload ${s.overload_before ?? 0}→${s.overload_after}`
              : "") +
            ` MV ${formatMoney(s.mv_before)}→${formatMoney(s.mv_after)}`
        );
      }
    }
  }
  return lines.join("\n");
}

async function runImport(apply) {
  const text = document.getElementById("importCsv")?.value || "";
  const objects = rowsToObjects(parseCsv(text));
  const out = document.getElementById("previewOut");

  if (!objects.length) {
    setStatus("importStatus", "❌ Paste or upload a CSV with a header row and at least one manager.", false);
    if (out) out.textContent = "";
    return;
  }

  if (apply) {
    if (
      !confirm(
        `Upsert ${objects.length} manager row(s)?\n\n` +
          `Existing contracts, career history, and IDs are kept.\n` +
          `Managers not in this file are not deleted.`
      )
    ) {
      return;
    }
  }

  setStatus("importStatus", apply ? "Applying…" : "Previewing…");
  const rpc = apply ? "admin_managers_catalog_upsert" : "admin_managers_catalog_preview";
  try {
    const { data, error } = await supabase.rpc(rpc, { p_rows: objects });
    if (error) throw error;
    if (out) out.textContent = formatPreview(data);
    const errCount = Array.isArray(data?.errors) ? data.errors.length : 0;
    if (apply) {
      setStatus(
        "importStatus",
        `✅ Done — inserted ${data?.inserted ?? 0}, updated ${data?.updated ?? 0}, unchanged ${data?.unchanged ?? 0}` +
          (errCount ? `, ${errCount} row error(s)` : "") +
          ".",
        true
      );
    } else {
      setStatus(
        "importStatus",
        `✅ Preview — insert ${data?.would_insert ?? 0}, update ${data?.would_update ?? 0}, unchanged ${data?.unchanged ?? 0}` +
          (errCount ? `, ${errCount} row error(s)` : "") +
          ". Apply when ready.",
        true
      );
    }
  } catch (err) {
    if (out) out.textContent = "";
    setStatus(
      "importStatus",
      "❌ " +
        (err.message || "Failed") +
        " — run supabase/sql/patches/admin_managers_overload_previous_name_20260815.sql",
      false
    );
  }
}
