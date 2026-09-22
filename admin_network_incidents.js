import { supabase, initGlobal, isGpslAdminUser } from "./global.js";

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

let includeResolved = false;

async function loadList() {
  const status = document.getElementById("listStatus");
  const list = document.getElementById("incidentsList");
  status.textContent = "Loading…";
  list.innerHTML = "";

  const { data, error } = await supabase.rpc("fixture_network_incident_admin_list", {
    p_include_resolved: includeResolved,
  });

  if (error) {
    status.textContent = error.message || "Failed to load";
    return;
  }

  const rows = Array.isArray(data) ? data : [];
  status.textContent = `${rows.length} incident(s)`;

  if (!rows.length) {
    list.innerHTML = `<p style="color:#888;">None.</p>`;
    return;
  }

  list.innerHTML = rows
    .map((r) => {
      const title = `${String(r.home_club_short_name || "").toUpperCase()} vs ${String(
        r.away_club_short_name || ""
      ).toUpperCase()}`;
      const open = r.status !== "resolved";
      return `
      <div class="ni-card" data-id="${r.id}">
        <h3>
          #${r.id} · ${escapeHtml(title)}
          <span class="status-pill status-${escapeHtml(r.status)}">${escapeHtml(r.status)}</span>
          ${r.hold_requested ? `<span class="status-pill status-escalated">hold</span>` : ""}
        </h3>
        <div class="ni-meta">
          Fixture ${r.fixture_id}
          · ${escapeHtml(r.competition_type || "")}
          ${r.division ? " · " + escapeHtml(r.division) : ""}
          ${r.cup_code ? " · " + escapeHtml(r.cup_code) : ""}
          · month ${escapeHtml(r.gpsl_month || "—")}
          · fixture status <b>${escapeHtml(r.fixture_status || "")}</b>
          <br>
          Reporter <b>${escapeHtml(String(r.reporter_club_short_name || "").toUpperCase())}</b>
          → ${escapeHtml(String(r.opponent_club_short_name || "").toUpperCase())}
          · score ${escapeHtml(r.score_home ?? "?")}–${escapeHtml(r.score_away ?? "?")}
          @ ${escapeHtml(r.match_minute ?? "?")}'
          · visibility ${r.visibility_ok ? "ok" : "poor"}
          · video ${r.video_available ? "yes" : "no"}
          ${
            r.evidence_url
              ? ` · <a href="${escapeHtml(r.evidence_url)}" target="_blank" rel="noopener" style="color:#9cf;">evidence</a>`
              : ""
          }
          · <a href="matchday.html?fixture=${r.fixture_id}" style="color:#9cf;">Match Day</a>
        </div>
        ${r.note ? `<div class="ni-note">${escapeHtml(r.note)}</div>` : ""}
        ${
          r.resolve_outcome
            ? `<div class="ni-note" style="color:#8d8;">Resolved: ${escapeHtml(
                r.resolve_outcome
              )}${r.resolve_note ? " — " + escapeHtml(r.resolve_note) : ""}</div>`
            : ""
        }
        ${
          open
            ? `<label>Outcome
            <select data-outcome>
              <option value="dismiss">Dismiss</option>
              <option value="forfeit_reporter">Forfeit reporter (weak / no evidence)</option>
              <option value="forfeit_opponent">Forfeit opponent</option>
              <option value="free_replay">Free replay</option>
              <option value="resume">Resume (score + minute)</option>
              <option value="carry_over">Carry-over (admin path)</option>
            </select>
          </label>
          <label>Note to clubs
            <textarea data-note maxlength="2000" placeholder="Decision note (optional)"></textarea>
          </label>
          <div class="ni-actions">
            <button type="button" class="button" data-resolve>Resolve (record only)</button>
          </div>`
            : ""
        }
      </div>`;
    })
    .join("");

  list.querySelectorAll("[data-resolve]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const card = btn.closest(".ni-card");
      const id = Number(card?.getAttribute("data-id"));
      const outcome = card.querySelector("[data-outcome]")?.value;
      const note = card.querySelector("[data-note]")?.value || null;
      if (
        !confirm(
          `Record outcome "${outcome}" for incident #${id}?\n\nThis does NOT auto-change the fixture. Apply forfeit/replay with existing tools if needed.`
        )
      ) {
        return;
      }
      btn.disabled = true;
      try {
        const { error: resErr } = await supabase.rpc(
          "fixture_network_incident_admin_resolve",
          {
            p_incident_id: id,
            p_outcome: outcome,
            p_note: note,
          }
        );
        if (resErr) throw resErr;
        await loadList();
      } catch (err) {
        alert(err?.message || "Resolve failed");
        btn.disabled = false;
      }
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    window.location = "login.html";
    return;
  }
  const ok = await isGpslAdminUser();
  if (!ok) {
    document.getElementById("listStatus").textContent = "Admin only.";
    return;
  }

  document.getElementById("filterOpenBtn")?.addEventListener("click", () => {
    includeResolved = false;
    loadList();
  });
  document.getElementById("filterAllBtn")?.addEventListener("click", () => {
    includeResolved = true;
    loadList();
  });

  await loadList();
});
