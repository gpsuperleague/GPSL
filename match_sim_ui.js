/**
 * Match result simulation — shared UI helpers (toggleable via global_settings).
 */
import { supabase } from "./global.js";

/**
 * @returns {Promise<{ enabled: boolean, isAdmin: boolean, error: string|null }>}
 */
export async function loadMatchSimStatus() {
  const { data, error } = await supabase.rpc("match_result_simulation_status");
  if (error) {
    console.warn("match_result_simulation_status:", error);
    return {
      enabled: false,
      isAdmin: false,
      error: error.message || "Simulation status unavailable (run match_result_simulation.sql)",
    };
  }
  const row = data && typeof data === "object" ? data : {};
  return {
    enabled: row.enabled === true || row.match_result_simulation_enabled === true,
    isAdmin: row.is_admin === true,
    error: null,
  };
}

export async function setMatchSimEnabled(enabled) {
  const { data, error } = await supabase.rpc("admin_set_match_result_simulation_enabled", {
    p_enabled: !!enabled,
  });
  if (error) throw error;
  return data?.match_result_simulation_enabled === true;
}

/**
 * @param {{ enabled: boolean, isAdmin?: boolean, error?: string|null }} status
 * @param {{ onToggle?: (next: boolean) => void }} [opts]
 */
export function matchSimBannerHtml(status, opts = {}) {
  if (status?.error) {
    return `<p class="match-sim-banner match-sim-banner--err" id="matchSimBanner">${escapeHtml(status.error)}</p>`;
  }
  if (!status?.enabled && !status?.isAdmin) return "";

  const state = status.enabled
    ? `<span class="match-sim-on">ON</span> — Simulate buttons are available on your fixtures.`
    : `<span class="match-sim-off">OFF</span> — owners cannot simulate results.`;

  const toggle = status.isAdmin
    ? `<button type="button" class="btn-link match-sim-toggle" id="matchSimToggleBtn" data-next="${
        status.enabled ? "0" : "1"
      }">${status.enabled ? "Turn OFF" : "Turn ON"}</button>`
    : "";

  return `<p class="match-sim-banner" id="matchSimBanner">Match simulation ${state} ${toggle}</p>`;
}

export function wireMatchSimBannerToggle(onChanged) {
  const btn = document.getElementById("matchSimToggleBtn");
  if (!btn) return;
  btn.addEventListener("click", async () => {
    const next = btn.getAttribute("data-next") === "1";
    const label = next ? "Enable match simulation for all owners?" : "Disable match simulation?";
    if (!confirm(label)) return;
    btn.disabled = true;
    try {
      await setMatchSimEnabled(next);
      if (typeof onChanged === "function") await onChanged(next);
    } catch (err) {
      alert(err?.message || String(err));
      btn.disabled = false;
    }
  });
}

export function matchSimButtonHtml(fixtureId) {
  return `<button type="button" class="btn-link sim-result-btn" data-sim-fixture="${escapeHtml(
    String(fixtureId)
  )}">Simulate</button>`;
}

/**
 * @param {(fixtureId: string, btn: HTMLButtonElement) => void} handler
 */
export function wireMatchSimButtons(root, handler) {
  root?.querySelectorAll("[data-sim-fixture]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-sim-fixture");
      if (!id) return;
      handler(id, btn);
    });
  });
}

export async function runMatchSimulation(fixtureId, btn) {
  if (btn) {
    btn.disabled = true;
    btn.textContent = "Simulating…";
  }
  const { data, error } = await supabase.rpc("competition_simulate_fixture_result", {
    p_fixture_id: Number(fixtureId),
  });
  if (error) {
    if (btn) {
      btn.disabled = false;
      btn.textContent = "Simulate";
    }
    throw error;
  }
  if (btn) {
    const score =
      data?.home_goals != null && data?.away_goals != null
        ? `${data.home_goals}–${data.away_goals}`
        : "";
    btn.textContent = score ? `Done ${score}` : "Done";
  }
  return data;
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Shared CSS snippet for pages that show sim UI. */
export const MATCH_SIM_BANNER_STYLE = `
.match-sim-banner { font-size:13px; color:#bbb; margin:0 0 12px; padding:8px 12px; background:#1a221a; border:1px solid #345; border-radius:6px; }
.match-sim-banner--err { background:#2a1515; border-color:#633; color:#f88; }
.match-sim-on { color:#9fd4b0; font-weight:bold; }
.match-sim-off { color:#f88; font-weight:bold; }
.btn-link.sim-result-btn, button.sim-result-btn {
  display:inline-block; padding:4px 10px; font-size:12px; font-weight:bold;
  background:#2a5535; color:#cfc; border:1px solid #3a6; border-radius:4px; cursor:pointer;
}
.btn-link.sim-result-btn:disabled, button.sim-result-btn:disabled { opacity:.6; cursor:wait; }
.match-sim-toggle { margin-left:8px; background:#444; color:#eee; border:0; }
`;
