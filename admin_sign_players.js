import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import { formatMoney } from "./competition.js";

primeAdminPageChrome();

/** @type {Map<string, object>} */
const basket = new Map();
/** @type {object|null} */
let lastPreview = null;

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  wireUi();
  await loadClubs();
});

function wireUi() {
  document.getElementById("searchBtn")?.addEventListener("click", runSearch);
  document.getElementById("searchQ")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      runSearch();
    }
  });
  document.getElementById("previewBtn")?.addEventListener("click", () => runSign(true));
  document.getElementById("signBtn")?.addEventListener("click", () => runSign(false));
  document.getElementById("clearBtn")?.addEventListener("click", () => {
    basket.clear();
    lastPreview = null;
    renderBasket();
    document.getElementById("signBtn").disabled = true;
    document.getElementById("resultBox").textContent = "";
    setStatus("pageStatus", "Basket cleared.");
  });
  document.getElementById("clubSelect")?.addEventListener("change", () => {
    lastPreview = null;
    document.getElementById("signBtn").disabled = true;
  });
}

async function loadClubs() {
  const sel = document.getElementById("clubSelect");
  const { data, error } = await supabase
    .from("Clubs")
    .select("ShortName, Club")
    .neq("ShortName", "FOREIGN")
    .order("Club");

  if (error || !data?.length) {
    sel.innerHTML = '<option value="">Failed to load clubs</option>';
    return;
  }

  sel.innerHTML =
    '<option value="">Select club…</option>' +
    data
      .map(
        (c) =>
          `<option value="${escapeHtml(c.ShortName)}">${escapeHtml(c.Club || c.ShortName)} (${escapeHtml(c.ShortName)})</option>`
      )
      .join("");
}

async function runSearch() {
  const q = document.getElementById("searchQ")?.value?.trim() || "";
  const box = document.getElementById("searchResults");
  if (q.length < 2) {
    box.innerHTML = `<p class="empty">Type at least 2 characters.</p>`;
    return;
  }
  box.innerHTML = `<p class="empty">Searching…</p>`;
  const { data, error } = await supabase.rpc("admin_search_free_agents_for_sign", {
    p_query: q,
    p_limit: 40,
  });
  if (error) {
    box.innerHTML = `<p class="empty">${escapeHtml(error.message)}</p>`;
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  if (!rows.length) {
    box.innerHTML = `<p class="empty">No free agents matched.</p>`;
    return;
  }
  box.innerHTML = `
    <table class="sign-table">
      <thead><tr>
        <th></th><th>Player</th><th>Pos</th><th class="num">OVR</th><th class="num">MV</th>
      </tr></thead>
      <tbody>
        ${rows
          .map((r) => {
            const id = String(r.player_id || "");
            const inBasket = basket.has(id);
            return `<tr>
              <td><button type="button" class="button add-btn" data-id="${escapeHtml(id)}" ${
                inBasket ? "disabled" : ""
              }>${inBasket ? "Added" : "Add"}</button></td>
              <td>${escapeHtml(r.player_name)} <span class="hint">${escapeHtml(id)}</span></td>
              <td>${escapeHtml(r.position || "—")}</td>
              <td class="num">${r.rating ?? "—"}</td>
              <td class="num">${escapeHtml(formatMoney(Number(r.market_value) || 0))}</td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  box.querySelectorAll(".add-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-id");
      const row = rows.find((r) => String(r.player_id) === id);
      if (!row) return;
      basket.set(id, row);
      lastPreview = null;
      document.getElementById("signBtn").disabled = true;
      btn.disabled = true;
      btn.textContent = "Added";
      renderBasket();
    });
  });
}

function renderBasket() {
  const box = document.getElementById("basketBox");
  const totals = document.getElementById("totalsBox");
  const rows = [...basket.values()];
  if (!rows.length) {
    box.innerHTML = `<p class="empty">No players selected yet.</p>`;
    totals.hidden = true;
    return;
  }

  let feeSum = 0;
  box.innerHTML = `
    <table class="sign-table">
      <thead><tr>
        <th>Player</th><th>Pos</th><th class="num">OVR</th><th class="num">MV</th><th></th>
      </tr></thead>
      <tbody>
        ${rows
          .map((r) => {
            const mv = Number(r.market_value) || 0;
            feeSum += mv;
            const id = String(r.player_id || "");
            return `<tr>
              <td>${escapeHtml(r.player_name)} <span class="hint">${escapeHtml(id)}</span></td>
              <td>${escapeHtml(r.position || "—")}</td>
              <td class="num">${r.rating ?? "—"}</td>
              <td class="num">${escapeHtml(formatMoney(mv))}</td>
              <td><button type="button" class="button rm-btn" data-id="${escapeHtml(id)}">Remove</button></td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>`;

  totals.hidden = false;
  totals.innerHTML = `<b>${rows.length}</b> player(s) · fees <b>${escapeHtml(
    formatMoney(feeSum)
  )}</b> (income tax added on Preview)`;

  box.querySelectorAll(".rm-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      basket.delete(btn.getAttribute("data-id"));
      lastPreview = null;
      document.getElementById("signBtn").disabled = true;
      renderBasket();
    });
  });
}

async function runSign(dryRun) {
  const club = document.getElementById("clubSelect")?.value || "";
  const ids = [...basket.keys()];
  const out = document.getElementById("resultBox");
  if (!club) {
    setStatus("pageStatus", "Pick a club first.", true);
    return;
  }
  if (!ids.length) {
    setStatus("pageStatus", "Add at least one free agent.", true);
    return;
  }
  if (!dryRun && !lastPreview?.ok) {
    setStatus("pageStatus", "Run Preview first.", true);
    return;
  }

  setStatus("pageStatus", dryRun ? "Previewing…" : "Signing…");
  out.textContent = "";

  const { data, error } = await supabase.rpc("admin_sign_free_agents_at_mv", {
    p_club_short_name: club,
    p_player_ids: ids,
    p_dry_run: dryRun,
  });

  if (error) {
    setStatus("pageStatus", error.message, true);
    out.textContent = error.message;
    return;
  }

  lastPreview = dryRun ? data : null;
  document.getElementById("signBtn").disabled = !(dryRun && data?.ok && Number(data.signed_count) > 0);

  const lines = [
    dryRun ? "PREVIEW" : "SIGNED",
    `Club ${data.club} · tax ${data.income_tax_pct}%`,
    `Balance before ${formatMoney(Number(data.balance_before) || 0)} · squad ${data.squad_before}`,
    `Would sign / signed: ${data.signed_count} · skipped: ${data.skipped_count}`,
    `Fees ${formatMoney(Number(data.fees_total) || 0)} + est. tax ${formatMoney(
      Number(data.est_income_tax_total) || 0
    )} = ${formatMoney(Number(data.est_total_cost) || 0)}`,
  ];

  if (Array.isArray(data.signed) && data.signed.length) {
    lines.push("", "Signed:");
    for (const s of data.signed) {
      lines.push(
        `  ${s.player_name} (${s.player_id}) ${s.position || ""} ${s.rating ?? ""} · ${formatMoney(
          Number(s.market_value) || 0
        )}`
      );
    }
  }
  if (Array.isArray(data.skipped) && data.skipped.length) {
    lines.push("", "Skipped:");
    for (const s of data.skipped) {
      lines.push(`  ${s.player_name || s.player_id}: ${s.reason}${s.detail ? " — " + s.detail : ""}`);
    }
  }

  out.textContent = lines.join("\n");
  setStatus(
    "pageStatus",
    dryRun
      ? `Preview ready — ${data.signed_count} to sign. Click Sign to apply.`
      : `Done — signed ${data.signed_count}.`
  );

  if (!dryRun && Number(data.signed_count) > 0) {
    for (const s of data.signed || []) basket.delete(String(s.player_id));
    renderBasket();
    document.getElementById("signBtn").disabled = true;
  }
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
