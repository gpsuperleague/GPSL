import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

/** @type {any} */
let lotteryState = null;

const KIND_LABELS = {
  owner_credits: "Owner credits",
  medical_token: "Injury treatment",
  ban_reduction: "Ban reduction",
  appeal_card: "Red card appeal card",
  fee_discount: "Transfer fee discount",
};

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function settingCell(p) {
  if (p.prize_kind === "owner_credits") {
    return `₿ <input type="number" min="1" step="1" data-field="amount" value="${escapeHtml(
      p.amount ?? 500
    )}" style="width:90px;">`;
  }
  if (p.prize_kind === "medical_token") {
    const v = Number(p.param_int) || 2;
    return `<select data-field="param_int">${[2, 4, 6, 8, 10]
      .map((n) => `<option value="${n}"${n === v ? " selected" : ""}>−${n} matches</option>`)
      .join("")}</select>`;
  }
  if (p.prize_kind === "fee_discount") {
    return `<input type="number" min="1" max="50" step="1" data-field="param_int" value="${escapeHtml(
      p.param_int ?? 10
    )}" style="width:60px;"> %`;
  }
  if (p.prize_kind === "ban_reduction") return '<span class="muted">−1 match</span>';
  return '<span class="muted">—</span>';
}

function renderPrizes() {
  const wrap = document.getElementById("prizesWrap");
  const prizes = lotteryState?.prizes || [];
  const totalWeight = prizes
    .filter((p) => p.enabled && Number(p.weight) > 0)
    .reduce((sum, p) => sum + Number(p.weight), 0);

  wrap.innerHTML = `
    <table class="lot-table">
      <thead><tr>
        <th>Prize</th><th>Setting</th><th>On</th><th>Weight</th><th>Chance</th><th>Custom label (optional)</th><th></th>
      </tr></thead>
      <tbody>
        ${prizes
          .map((p) => {
            const w = Number(p.weight) || 0;
            const chance =
              p.enabled && w > 0 && totalWeight > 0 ? `${Math.round((w / totalWeight) * 100)}%` : "—";
            return `<tr data-prize-id="${p.id}">
              <td>${escapeHtml(KIND_LABELS[p.prize_kind] || p.prize_kind)}</td>
              <td>${settingCell(p)}</td>
              <td><input type="checkbox" data-field="enabled"${p.enabled ? " checked" : ""}></td>
              <td><input type="number" min="0" step="1" data-field="weight" value="${w}" style="width:60px;"></td>
              <td class="lot-chance">${chance}</td>
              <td><input type="text" data-field="label" value="${escapeHtml(p.label || "")}" placeholder="${escapeHtml(
                p.default_label || ""
              )}" style="width:100%;min-width:220px;"></td>
              <td><button type="button" class="button" data-save-prize="${p.id}">Save</button></td>
            </tr>`;
          })
          .join("")}
      </tbody>
    </table>
    <p class="muted" style="font-size:12px;margin:8px 0 0;">
      Chance is each prize's weight out of the total of all switched-on prizes (club prizes are skipped for a winner without a club).
    </p>`;

  wrap.querySelectorAll("[data-save-prize]").forEach((btn) => {
    btn.addEventListener("click", () => savePrize(Number(btn.getAttribute("data-save-prize"))));
  });
}

function renderEntrants() {
  const wrap = document.getElementById("entrantsWrap");
  const rows = lotteryState?.entrants || [];
  wrap.innerHTML = rows.length
    ? `${rows.length} supporter${rows.length === 1 ? "" : "s"}: ` +
      rows
        .map((r) => `${escapeHtml(r.owner_tag)}${r.club ? ` <span class="muted">(${escapeHtml(r.club)})</span>` : ""}`)
        .join(", ")
    : '<span class="muted">No current supporters — the draw is skipped until someone is flagged.</span>';
}

function renderDraws() {
  const wrap = document.getElementById("drawsWrap");
  const rows = lotteryState?.draws || [];
  if (!rows.length) {
    wrap.innerHTML = '<span class="muted">No draws yet.</span>';
    return;
  }
  wrap.innerHTML = `
    <table class="lot-table">
      <thead><tr><th>Month</th><th>Winner</th><th>Club</th><th>Prize</th><th>Entrants</th><th>Drawn</th></tr></thead>
      <tbody>
        ${rows
          .map(
            (d) => `<tr>
              <td>${escapeHtml(d.draw_ym)}</td>
              <td>${escapeHtml(d.owner_tag || "—")}</td>
              <td>${escapeHtml(d.club_short_name || "—")}</td>
              <td>${escapeHtml(d.prize_label)}</td>
              <td>${escapeHtml(d.entrants)}</td>
              <td>${escapeHtml(new Date(d.drawn_at).toLocaleString("en-GB"))}${
                d.drawn_by === "admin" ? ' <span class="muted">(admin)</span>' : ""
              }</td>
            </tr>`
          )
          .join("")}
      </tbody>
    </table>`;
}

function render() {
  renderPrizes();
  renderEntrants();
  renderDraws();
  const btn = document.getElementById("drawNowBtn");
  if (btn) {
    btn.disabled = !!lotteryState?.drawn_this_month;
    btn.title = lotteryState?.drawn_this_month
      ? `Already drawn for ${lotteryState.current_ym}`
      : `Run the ${lotteryState?.current_ym || ""} draw now instead of waiting for the 1st`;
  }
}

async function loadState() {
  setStatus("statusLine", "Loading…");
  const { data, error } = await supabase.rpc("admin_supporter_lottery_state");
  if (error) {
    setStatus("statusLine", `${error.message} — run supporters_lottery_20261001.sql`, false);
    return;
  }
  lotteryState = data;
  setStatus(
    "statusLine",
    data?.drawn_this_month
      ? `${data.current_ym}: already drawn.`
      : `${data?.current_ym}: not drawn yet — runs automatically on the 1st.`
  );
  render();
}

async function savePrize(id) {
  const row = document.querySelector(`tr[data-prize-id="${id}"]`);
  if (!row) return;
  const field = (name) => row.querySelector(`[data-field="${name}"]`);
  const amountEl = field("amount");
  const paramEl = field("param_int");
  const { error } = await supabase.rpc("admin_supporter_lottery_save_prize", {
    p_id: id,
    p_weight: Number(field("weight")?.value) || 0,
    p_enabled: !!field("enabled")?.checked,
    p_amount: amountEl ? Number(amountEl.value) || null : null,
    p_param_int: paramEl ? Number(paramEl.value) || null : null,
    p_label: field("label")?.value || "",
  });
  if (error) {
    setStatus("statusLine", `❌ ${error.message}`, false);
    return;
  }
  setStatus("statusLine", "✅ Prize saved.");
  await loadState();
}

async function drawNow() {
  if (!confirm(`Draw the ${lotteryState?.current_ym || "this month's"} Supporters' lottery now? This pays out the prize and announces the winner.`)) {
    return;
  }
  setStatus("statusLine", "Drawing…");
  const { data, error } = await supabase.rpc("admin_supporter_lottery_draw_now");
  if (error) {
    setStatus("statusLine", `❌ ${error.message}`, false);
    return;
  }
  if (data?.skipped) {
    setStatus("statusLine", `Not drawn: ${String(data.skipped).replace(/_/g, " ")}.`, "warn");
  } else {
    setStatus("statusLine", `🎟️ ${data?.owner_tag || "Winner"} won: ${data?.prize_label}.`);
  }
  await loadState();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("refreshBtn").onclick = () => loadState();
  document.getElementById("drawNowBtn").onclick = () => drawNow();
  await loadState();
});
