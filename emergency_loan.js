/**
 * Emergency loans — FA ≤66 when injuries/suspensions leave available squad under 24 (from August).
 * Half-season: Aug–Dec → end Dec; Jan–May → end May. Fee ₿2.5m to central bank.
 */

export const EMERGENCY_LOAN_FEE = 2_500_000;
export const EMERGENCY_LOAN_MAX_RATING = 66;

export function emergencyLoanBadgeHtml() {
  return '<span class="squad-loan-badge squad-loan-badge--emergency" title="Emergency loan (injury/suspension shortfall)">Emergency loan</span>';
}

function formatFee(n) {
  const v = Number(n) || 0;
  return `₿${v.toLocaleString("en-GB")}`;
}

function monthLabel(m) {
  if (!m) return "";
  return String(m).charAt(0).toUpperCase() + String(m).slice(1);
}

/** @param {import("@supabase/supabase-js").SupabaseClient} supabase */
export async function loadEmergencyLoanStatus(supabase, clubShort = null) {
  const args = clubShort ? { p_club_short_name: clubShort } : {};
  const { data, error } = await supabase.rpc("club_emergency_loan_status", args);
  if (error) {
    console.warn("club_emergency_loan_status:", error);
    return null;
  }
  return data;
}

/** @returns {Promise<Set<string>>} */
export async function loadActiveEmergencyLoanPlayerIds(supabase, clubShort) {
  if (!clubShort) return new Set();
  const { data, error } = await supabase
    .from("club_emergency_loans")
    .select("player_id")
    .eq("club_short_name", clubShort)
    .eq("status", "active");
  if (error) {
    console.warn("club_emergency_loans:", error);
    return new Set();
  }
  return new Set((data || []).map((row) => String(row.player_id)));
}

export async function loadEmergencyLoanCandidates(supabase, limit = 40) {
  const { data, error } = await supabase.rpc("club_emergency_loan_candidates", {
    p_limit: limit,
  });
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}

export async function takeEmergencyLoan(supabase, playerId) {
  return supabase.rpc("club_emergency_loan_take", {
    p_player_id: String(playerId),
  });
}

export function emergencyLoanBannerHtml(status) {
  if (!status?.eligible) return "";
  const ends = monthLabel(status.ends_gpsl_month);
  const need = Number(status.need) || 0;
  const slots = Number(status.slots_available) || 0;
  const fee = formatFee(status.loan_fee ?? EMERGENCY_LOAN_FEE);
  const afford = status.can_afford !== false;
  return `
    <div class="emergency-loan-banner" id="emergencyLoanBanner">
      <div class="emergency-loan-banner-copy">
        <strong>Emergency loan available</strong>
        <span>
          Only ${status.available}/${status.min_squad} fit players
          (injured/suspended). You can take up to ${slots} loan${slots === 1 ? "" : "s"}
          from free agents rated ≤${status.max_rating ?? EMERGENCY_LOAN_MAX_RATING}
          until end of ${ends}. Fee ${fee} to Central Bank.
        </span>
        ${need > slots ? `<span class="emergency-loan-banner-note">Shortfall ${need}; ${slots} slot${slots === 1 ? "" : "s"} free this half-season.</span>` : ""}
      </div>
      <button type="button" class="button emergency-loan-open-btn" id="emergencyLoanOpenBtn"
        ${afford ? "" : "disabled"}
        title="${afford ? "Browse free agents for emergency loan" : "Insufficient balance"}">
        Take emergency loan
      </button>
    </div>`;
}

/**
 * Modal picker — returns chosen player_id or null.
 * @param {Array<object>} candidates
 * @param {object} status
 */
export function openEmergencyLoanPicker(candidates, status) {
  return new Promise((resolve) => {
    const existing = document.getElementById("emergencyLoanModal");
    existing?.remove();

    const ends = monthLabel(status?.ends_gpsl_month);
    const fee = formatFee(status?.loan_fee ?? EMERGENCY_LOAN_FEE);
    const rows = (candidates || [])
      .map((c) => {
        const id = escapeHtml(String(c.player_id || ""));
        const name = escapeHtml(c.name || id);
        const pos = escapeHtml(c.position || "—");
        const nat = escapeHtml(c.nation || "—");
        const age = c.age != null ? escapeHtml(String(c.age)) : "—";
        const rating = c.rating != null ? escapeHtml(String(c.rating)) : "—";
        return `<tr>
          <td>${name}</td>
          <td>${pos}</td>
          <td>${nat}</td>
          <td class="num">${age}</td>
          <td class="num">${rating}</td>
          <td><button type="button" class="button emergency-loan-pick" data-player-id="${id}">Loan</button></td>
        </tr>`;
      })
      .join("");

    const el = document.createElement("div");
    el.id = "emergencyLoanModal";
    el.className = "emergency-loan-modal";
    el.innerHTML = `
      <div class="emergency-loan-dialog" role="dialog" aria-modal="true" aria-label="Emergency loan">
        <header class="emergency-loan-dialog-head">
          <h3>Emergency loan</h3>
          <button type="button" class="emergency-loan-close" aria-label="Close">×</button>
        </header>
        <p class="emergency-loan-dialog-intro">
          Free agents rated ≤${status?.max_rating ?? EMERGENCY_LOAN_MAX_RATING}.
          Fee ${fee}. Returns to free agency at end of ${ends || "the half-season"}.
        </p>
        <div class="emergency-loan-table-wrap">
          ${
            rows
              ? `<table class="emergency-loan-table">
                  <thead><tr><th>Player</th><th>Pos</th><th>Nation</th><th>Age</th><th>R</th><th></th></tr></thead>
                  <tbody>${rows}</tbody>
                </table>`
              : `<p class="note">No eligible free agents found (≤${EMERGENCY_LOAN_MAX_RATING}).</p>`
          }
        </div>
      </div>`;
    document.body.appendChild(el);

    const close = (value) => {
      el.remove();
      resolve(value);
    };
    el.querySelector(".emergency-loan-close")?.addEventListener("click", () => close(null));
    el.addEventListener("click", (e) => {
      if (e.target === el) close(null);
    });
    el.querySelectorAll(".emergency-loan-pick").forEach((btn) => {
      btn.addEventListener("click", () => {
        close(btn.getAttribute("data-player-id"));
      });
    });
  });
}

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Shared styles for banner + modal (inject once). */
export function ensureEmergencyLoanStyles() {
  if (document.getElementById("emergencyLoanStyles")) return;
  const style = document.createElement("style");
  style.id = "emergencyLoanStyles";
  style.textContent = `
.emergency-loan-banner {
  display:flex; flex-wrap:wrap; gap:12px; align-items:center; justify-content:space-between;
  margin:0 0 12px; padding:12px 14px; border-radius:8px;
  background:#1a2218; border:1px solid #3a5a3a; color:#cfc;
}
.emergency-loan-banner-copy { display:flex; flex-direction:column; gap:4px; min-width:0; flex:1; font-size:13px; }
.emergency-loan-banner-copy strong { color:#9fd4b0; font-size:14px; }
.emergency-loan-banner-note { color:#9a9; font-size:12px; }
.emergency-loan-open-btn { white-space:nowrap; background:#2a5535 !important; }
.emergency-loan-open-btn:disabled { opacity:.45; cursor:not-allowed; }
.squad-loan-badge--emergency { background:#3a2a55; color:#d8c8f0; border-color:#654; }

.emergency-loan-modal {
  position:fixed; inset:0; z-index:10000; background:rgba(0,0,0,.65);
  display:flex; align-items:center; justify-content:center; padding:16px;
}
.emergency-loan-dialog {
  width:min(640px, 100%); max-height:min(80vh, 720px); overflow:auto;
  background:#121212; border:1px solid #333; border-radius:10px; padding:14px 16px; color:#eee;
}
.emergency-loan-dialog-head { display:flex; align-items:center; justify-content:space-between; gap:8px; }
.emergency-loan-dialog-head h3 { margin:0; font-size:16px; }
.emergency-loan-close { background:transparent; border:0; color:#aaa; font-size:22px; cursor:pointer; line-height:1; }
.emergency-loan-dialog-intro { font-size:13px; color:#9ab; margin:8px 0 12px; }
.emergency-loan-table { width:100%; border-collapse:collapse; font-size:13px; }
.emergency-loan-table th, .emergency-loan-table td { padding:6px 8px; border-bottom:1px solid #2a2a2a; text-align:left; }
.emergency-loan-table .num { text-align:right; font-variant-numeric:tabular-nums; }
.emergency-loan-pick { padding:4px 10px; font-size:12px; background:#2a5535; color:#cfc; border:0; border-radius:4px; cursor:pointer; }
`;
  document.head.appendChild(style);
}
