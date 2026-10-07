import { supabase, initGlobal, getAuthUser } from "./global.js";

const DIVISIONS = [
  { id: "superleague", label: "Super League" },
  { id: "championship_a", label: "Championship A" },
  { id: "championship_b", label: "Championship B" },
];

const BAND_LABELS = {
  on_target: "On target",
  slight: "Slight miss",
  bad: "Bad miss",
  abysmal: "Abysmal miss",
};

const MANAGER_TONE = {
  continues: "ok",
  renew: "ok",
  awaiting_renewal: "warn",
  leaves: "bad",
  sacked: "bad",
  none: "muted",
};

const MANAGER_SHORT = {
  continues: "Contract continues",
  renew: "Open to renew",
  awaiting_renewal: "Awaiting renewal",
  leaves: "Leaves (refuses deal)",
  sacked: "Sacked",
  none: "No manager",
};

const FINANCE_STALE_MS = 6 * 60 * 60 * 1000;

let board = null;
let division = "all";
let onlyConsequences = false;
let search = "";
let myClub = null;
let isAdmin = false;

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function money(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  const abs = Math.abs(v);
  const sign = v < 0 ? "−" : "";
  if (abs >= 1_000_000) return `${sign}₿${(abs / 1_000_000).toFixed(abs >= 100_000_000 ? 0 : 1)}m`;
  if (abs >= 1_000) return `${sign}₿${Math.round(abs / 1_000)}k`;
  return `${sign}₿${Math.round(abs)}`;
}

function ordinal(n) {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  const m10 = v % 10;
  const m100 = v % 100;
  const suf = m10 === 1 && m100 !== 11 ? "st" : m10 === 2 && m100 !== 12 ? "nd" : m10 === 3 && m100 !== 13 ? "rd" : "th";
  return `${v}${suf}`;
}

function timeAgo(iso) {
  if (!iso) return null;
  const ms = Date.now() - new Date(iso).getTime();
  if (!Number.isFinite(ms)) return null;
  const mins = Math.round(ms / 60000);
  if (mins < 2) return "just now";
  if (mins < 60) return `${mins} min ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 48) return `${hrs}h ago`;
  return `${Math.round(hrs / 24)} days ago`;
}

function chip(text, tone) {
  return `<span class="sr-chip sr-chip--${tone}">${esc(text)}</span>`;
}

function hasConsequence(r) {
  const m = r.manager?.code;
  return (
    r.club?.code === "missed" ||
    m === "leaves" ||
    m === "sacked" ||
    m === "awaiting_renewal" ||
    !!r.finance?.ffp
  );
}

function expectationCell(r) {
  const band = r.band || "on_target";
  const tone = band === "on_target" ? "ok" : band === "slight" ? "warn" : "bad";
  const cupMet = (r.cup_targets || []).filter((t) => t.applicable);
  const cupLine = cupMet.length
    ? `<div class="sr-sub">Cup: ${cupMet
        .map((t) => `${esc(t.label)} ${t.met ? "✔" : "✘"}`)
        .join(" · ")}</div>`
    : "";
  return `
    <div>${r.expected_position ? `Expected <b>${ordinal(r.expected_position)}</b>` : "Expected —"}
      ${r.expectation_label ? `<span class="sr-sub">(${esc(r.expectation_label)})</span>` : ""}</div>
    <div class="sr-sub">${esc(r.tier || "—")} club${
      r.baseline_expected_position && r.expected_position && r.baseline_expected_position !== r.expected_position
        ? ` · baseline ${ordinal(r.baseline_expected_position)}, manager lift +${r.baseline_expected_position - r.expected_position}`
        : ""
    }</div>
    <div>${chip(BAND_LABELS[band] || band, tone)}${r.cup_rescued ? ` ${chip("Cup rescue", "ok")}` : ""}</div>
    ${r.band_provisional ? `<div class="sr-sub" title="The official status appears once the first month's league fixtures are all played">Early season — from the live table</div>` : ""}
    ${cupLine}`;
}

function clubOutcomeCell(r) {
  const c = r.club || {};
  if (c.code !== "missed") {
    return `<div class="sr-sub">${esc(c.text || "—")}</div>`;
  }
  const listing = c.listing || {};
  const pool = listing.pool || [];
  const shown = pool.slice(0, 6).map((p) => `${esc(p.name)} (${p.rating ?? "?"})`);
  const more = pool.length > 6 ? ` +${pool.length - 6} more` : "";
  return `
    <div>${chip(`Owner fined ${c.board_fine_pct || 25}% of personal wealth`, "bad")}</div>
    <div class="sr-block"><b>Transfer request:</b> ${esc(listing.rule || "one player")} — listed at market value until sold.</div>
    <div class="sr-sub">${pool.length ? `Could be: ${shown.join(", ")}${more}` : "No eligible player — no listing."}</div>`;
}

function managerCell(r) {
  const m = r.manager || {};
  if (!m.name) return `<span class="sr-sub">No manager</span>`;
  const met =
    m.target_met === true ? chip("Target hit", "ok") : m.target_met === false ? chip("Target missed", "bad") : chip("Pending", "muted");
  const yearTxt = m.pending_renewal
    ? "Deal finished"
    : m.seasons_remaining > 1
      ? `Year ${m.deal_season} of deal · ${m.seasons_remaining - 1} season left after this`
      : `Final year of deal (year ${m.deal_season})`;
  return `
    <div><a class="sr-link" href="manager_career.html?manager=${encodeURIComponent(m.id)}">${esc(m.name)}</a> <span class="sr-sub">(${m.rating ?? "—"})</span></div>
    <div class="sr-sub">Target: ${esc(m.target_label || "—")}</div>
    <div>${met}</div>
    <div class="sr-sub">${esc(yearTxt)} · ${m.deal_hits} hit${m.deal_hits === 1 ? "" : "s"} this deal</div>`;
}

function managerOutcomeCell(r) {
  const m = r.manager || {};
  const tone = MANAGER_TONE[m.code] || "muted";
  return `
    <div>${chip(MANAGER_SHORT[m.code] || m.code || "—", tone)}</div>
    <div class="sr-sub">${esc(m.text || "")}</div>
    ${m.next_season ? `<div class="sr-block sr-next">Next season: ${esc(m.next_season)}</div>` : ""}`;
}

function financeCell(r) {
  const f = r.finance;
  if (!f) return `<span class="sr-sub">Not projected yet</span>`;
  const lines = [
    `<div>Now <b>${money(f.balance_now)}</b></div>`,
    `<div>Projected close <b class="${Number(f.closing) < 0 ? "sr-neg" : "sr-plus"}">${money(f.closing)}</b></div>`,
  ];
  if (f.eos_posted) lines.push(`<div class="sr-sub">Season finances already closed</div>`);
  if (Number(f.debt_interest) > 0) {
    lines.push(`<div class="sr-sub">Includes debt interest −${money(f.debt_interest)}</div>`);
  }
  if (f.ffp) {
    lines.push(`<div>${chip(`FFP fine ${money(f.ffp_fine || board.ffp_fine)}`, "bad")}</div>`);
    const rel = f.releases || [];
    if (rel.length) {
      lines.push(
        `<div class="sr-block"><b>Forced sales:</b> ${rel
          .map((p) => `${esc(p.name)} (${money(p.market_value)})`)
          .join(", ")}</div>`
      );
    }
    lines.push(`<div class="sr-sub">Can't buy players in the next transfer window</div>`);
  } else if (Number(f.closing) < 0) {
    const room = Number(board.ffp_threshold) + Number(f.closing);
    lines.push(`<div class="sr-sub">${money(room)} above the FFP line</div>`);
  }
  return lines.join("");
}

function renderSummary(rows) {
  const n = (fn) => rows.filter(fn).length;
  const items = [
    ["Board fines", n((r) => r.club?.code === "missed"), "bad"],
    ["Transfer requests", n((r) => r.club?.code === "missed" && (r.club.listing?.pool_count || 0) > 0), "bad"],
    ["Managers leaving", n((r) => r.manager?.code === "leaves"), "bad"],
    ["Managers sacked", n((r) => r.manager?.code === "sacked"), "bad"],
    ["Open to renew", n((r) => r.manager?.code === "renew"), "ok"],
    ["FFP fines", n((r) => r.finance?.ffp), "bad"],
  ];
  return `<div class="sr-summary">${items
    .map(([label, count, tone]) => `<div class="sr-stat sr-stat--${count ? tone : "muted"}"><b>${count}</b><span>${label}</span></div>`)
    .join("")}</div>`;
}

function render() {
  const root = document.getElementById("srBoard");
  if (!root || !board) return;
  const q = search.trim().toLowerCase();
  const rows = (board.rows || []).filter((r) => {
    if (division !== "all" && r.division !== division) return false;
    if (onlyConsequences && !hasConsequence(r)) return false;
    if (q) {
      const hay = `${r.club_name} ${r.club_short_name} ${r.owner_name || ""} ${r.manager?.name || ""}`.toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });

  const sections = DIVISIONS.map((d) => {
    const list = rows.filter((r) => r.division === d.id);
    if (!list.length) return "";
    return `<section class="sr-div">
      <h2>${d.label}</h2>
      <div class="sr-scroll"><table class="sr-table">
        <thead><tr>
          <th>Pos</th><th>Club</th><th>Expectation</th><th>Club outcome</th>
          <th>Manager</th><th>Manager outcome</th><th>Finances</th>
        </tr></thead>
        <tbody>${list
          .map(
            (r) => `<tr class="${r.club_short_name === myClub ? "sr-me" : ""}">
            <td class="sr-pos">${r.position ?? "—"}<div class="sr-sub">${r.points ?? 0} pts · ${r.played ?? 0} pl</div></td>
            <td><b>${esc(r.club_name)}</b><div class="sr-sub">${esc(r.owner_name || "No owner")}</div></td>
            <td>${expectationCell(r)}</td>
            <td>${clubOutcomeCell(r)}</td>
            <td>${managerCell(r)}</td>
            <td>${managerOutcomeCell(r)}</td>
            <td>${financeCell(r)}</td>
          </tr>`
          )
          .join("")}</tbody>
      </table></div>
    </section>`;
  }).join("");

  root.innerHTML =
    renderSummary(rows) +
    (sections || `<p class="sr-empty">No clubs match these filters.</p>`);
}

function renderMeta() {
  const el = document.getElementById("srMeta");
  if (!el || !board) return;
  const ago = timeAgo(board.finance_computed_at);
  el.innerHTML = `${esc(board.season_label || "Current season")} · league positions as they stand now · finance projection ${
    ago ? `updated ${ago}` : "not published yet"
  }${isAdmin ? ` <button type="button" class="button sr-refresh" id="srRefreshFinance">Refresh finance projection</button>` : ""}`;
  document.getElementById("srRefreshFinance")?.addEventListener("click", () => publishFinance(true));
}

async function loadBoard() {
  const { data, error } = await supabase.rpc("season_review_board");
  if (error || !data?.ok) {
    const root = document.getElementById("srBoard");
    if (root) {
      root.innerHTML = `<p class="sr-empty">Could not load the season review${
        error ? `: ${esc(error.message)}` : data?.reason ? ` (${esc(data.reason)})` : ""
      }.</p>`;
    }
    return false;
  }
  board = data;
  renderMeta();
  render();
  return true;
}

async function publishFinance(manual) {
  const btn = document.getElementById("srRefreshFinance");
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Projecting…";
  }
  try {
    const { buildLeagueFinanceForecast } = await import("./admin_league_finance_forecast.js");
    const forecast = await buildLeagueFinanceForecast(supabase, {
      onProgress: (done, total) => {
        if (btn) btn.textContent = `Projecting… ${done}/${total}`;
      },
    });
    const rows = forecast.clubs.map((c) => {
      const pendingPreEos = Object.entries(c.pending)
        .filter(([id]) => id !== "eos_debt_interest" && id !== "eos_ffp")
        .reduce((s, [, v]) => s + (Number(v) || 0), 0);
      return {
        club: c.club,
        balance_now: Math.round(c.balanceNow),
        pre_close: Math.round(c.balanceNow + pendingPreEos),
        eos_posted:
          Math.abs(Number(c.posted.eos_debt_interest) || 0) > 0.5 ||
          Math.abs(Number(c.posted.eos_ffp) || 0) > 0.5,
      };
    });
    const { error } = await supabase.rpc("admin_season_review_publish_finance", { p_rows: rows });
    if (error) throw error;
    await loadBoard();
  } catch (err) {
    console.error("Season review finance publish:", err);
    if (manual) alert(`Finance projection failed: ${err.message || err}`);
    if (btn) {
      btn.disabled = false;
      btn.textContent = "Refresh finance projection";
    }
  }
}

function wireControls() {
  document.querySelectorAll("#srTabs button").forEach((b) => {
    b.addEventListener("click", () => {
      division = b.dataset.div;
      document.querySelectorAll("#srTabs button").forEach((x) => x.classList.toggle("active", x === b));
      render();
    });
  });
  document.getElementById("srOnlyConsequences")?.addEventListener("change", (e) => {
    onlyConsequences = !!e.target.checked;
    render();
  });
  let t = null;
  document.getElementById("srSearch")?.addEventListener("input", (e) => {
    clearTimeout(t);
    t = setTimeout(() => {
      search = e.target.value;
      render();
    }, 150);
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  wireControls();

  const user = await getAuthUser();
  if (user) {
    const [{ data: club }, { data: admin }] = await Promise.all([
      supabase.from("Clubs").select("ShortName").eq("owner_id", user.id).maybeSingle(),
      supabase.rpc("is_gpsl_admin"),
    ]);
    myClub = club?.ShortName ?? null;
    isAdmin = admin === true;
  }

  const ok = await loadBoard();
  if (!ok || !isAdmin) return;
  const at = board.finance_computed_at ? new Date(board.finance_computed_at).getTime() : 0;
  if (!at || Date.now() - at > FINANCE_STALE_MS) void publishFinance(false);
});
