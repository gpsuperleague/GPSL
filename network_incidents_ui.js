/**
 * Mid-match network / visibility incidents (owners).
 * Additive UI — does not change fixture status or scheduling itself.
 */
import { supabase } from "./global.js";

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function statusLabel(st) {
  const m = {
    logged: "Logged",
    peer_retry: "Peer: retry",
    peer_reschedule: "Peer: reschedule",
    escalated: "Escalated (held for staff)",
    resolved: "Resolved",
  };
  return m[st] || st;
}

async function listIncidents(fixtureId) {
  const { data, error } = await supabase.rpc(
    "fixture_network_incident_list_for_fixture",
    { p_fixture_id: fixtureId }
  );
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}

async function refreshMount(mount, fixture, myClubShort) {
  if (!mount || !fixture?.id) {
    if (mount) mount.innerHTML = "";
    return;
  }

  const played = String(fixture.status || "") === "played";
  let rows = [];
  let loadErr = "";
  try {
    rows = await listIncidents(fixture.id);
  } catch (err) {
    loadErr = err?.message || "Could not load network incidents";
  }

  const my = String(myClubShort || "").toUpperCase();

  mount.innerHTML = `
    <div class="ni-panel" style="margin:12px 0;padding:12px 14px;border:1px solid #444;border-radius:6px;background:#141418;">
      <div style="display:flex;flex-wrap:wrap;align-items:baseline;gap:8px 14px;margin-bottom:8px;">
        <strong style="color:#fc6;font-size:14px;">Network / mid-match issue</strong>
        <span style="font-size:12px;color:#999;">Logs visibility + video evidence. Does not change fixture status.</span>
      </div>
      ${
        loadErr
          ? `<p style="color:#f99;font-size:13px;margin:0 0 8px;">${escapeHtml(loadErr)}</p>`
          : ""
      }
      <div id="niList" style="display:grid;gap:8px;margin-bottom:10px;">
        ${
          rows.length === 0
            ? `<p style="margin:0;font-size:13px;color:#888;">No network reports on this fixture yet.</p>`
            : rows
                .map((r) => {
                  const isParty =
                    my &&
                    (my === String(r.reporter_club_short_name || "").toUpperCase() ||
                      my === String(r.opponent_club_short_name || "").toUpperCase());
                  const open =
                    r.status === "logged" ||
                    r.status === "peer_retry" ||
                    r.status === "peer_reschedule";
                  const canEscalate = isParty && open;
                  const canAck = isParty && open;
                  return `
            <div style="border:1px solid #2a2a2a;border-radius:4px;padding:8px 10px;background:#1a1a1a;font-size:13px;">
              <div style="color:#ddd;">
                <b>${escapeHtml(String(r.reporter_club_short_name || "").toUpperCase())}</b>
                reported
                · ${escapeHtml(statusLabel(r.status))}
                ${r.hold_requested ? " · <span style=\"color:#fc6;\">hold</span>" : ""}
              </div>
              <div style="color:#999;font-size:12px;margin-top:4px;">
                Score ${escapeHtml(r.score_home ?? "?")}–${escapeHtml(r.score_away ?? "?")}
                at ${escapeHtml(r.match_minute ?? "?")}'
                · visibility ${r.visibility_ok ? "ok" : "poor"}
                · video ${r.video_available ? "yes" : "no"}
                ${r.evidence_url ? ` · <a href="${escapeHtml(r.evidence_url)}" target="_blank" rel="noopener" style="color:#9cf;">evidence</a>` : ""}
              </div>
              ${r.note ? `<div style="color:#bbb;margin-top:4px;white-space:pre-wrap;">${escapeHtml(r.note)}</div>` : ""}
              ${
                r.resolve_outcome
                  ? `<div style="color:#8d8;margin-top:4px;">Outcome: ${escapeHtml(r.resolve_outcome)}${r.resolve_note ? " — " + escapeHtml(r.resolve_note) : ""}</div>`
                  : ""
              }
              ${
                canAck || canEscalate
                  ? `<div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;">
                  ${
                    canAck
                      ? `<button type="button" class="button secondary ni-ack" data-id="${r.id}" data-action="retry" style="padding:4px 10px;font-size:12px;">Agree retry</button>
                         <button type="button" class="button secondary ni-ack" data-id="${r.id}" data-action="reschedule" style="padding:4px 10px;font-size:12px;">Agree reschedule</button>`
                      : ""
                  }
                  ${
                    canEscalate
                      ? `<button type="button" class="button danger ni-escalate" data-id="${r.id}" style="padding:4px 10px;font-size:12px;">Escalate to staff</button>`
                      : ""
                  }
                </div>`
                  : ""
              }
            </div>`;
                })
                .join("")
        }
      </div>
      ${
        played
          ? `<p style="margin:0;font-size:12px;color:#888;">Fixture already played — new reports closed.</p>`
          : `<details style="margin-top:4px;">
        <summary style="cursor:pointer;color:#fc6;font-size:13px;">File a network report</summary>
        <div style="display:grid;gap:8px;margin-top:10px;max-width:420px;">
          <label style="font-size:12px;color:#bbb;">Score at issue (home – away)
            <div style="display:flex;gap:8px;align-items:center;margin-top:4px;">
              <input type="number" id="niScoreH" min="0" max="99" style="width:64px;padding:6px;background:#111;border:1px solid #444;color:#eee;border-radius:4px;">
              <span>–</span>
              <input type="number" id="niScoreA" min="0" max="99" style="width:64px;padding:6px;background:#111;border:1px solid #444;color:#eee;border-radius:4px;">
            </div>
          </label>
          <label style="font-size:12px;color:#bbb;">Match minute
            <input type="number" id="niMinute" min="0" max="120" style="display:block;width:80px;margin-top:4px;padding:6px;background:#111;border:1px solid #444;color:#eee;border-radius:4px;">
          </label>
          <label style="font-size:12px;color:#bbb;display:flex;gap:8px;align-items:center;">
            <input type="checkbox" id="niVisibility" checked> Opponent / pitch still visible
          </label>
          <label style="font-size:12px;color:#bbb;display:flex;gap:8px;align-items:center;">
            <input type="checkbox" id="niVideo"> Match video / clip available
          </label>
          <label style="font-size:12px;color:#bbb;">Evidence URL (optional)
            <input type="url" id="niEvidence" maxlength="2000" placeholder="https://…" style="display:block;width:100%;margin-top:4px;padding:6px;background:#111;border:1px solid #444;color:#eee;border-radius:4px;">
          </label>
          <label style="font-size:12px;color:#bbb;">Note
            <textarea id="niNote" maxlength="2000" rows="3" placeholder="What happened?" style="display:block;width:100%;margin-top:4px;padding:6px;background:#111;border:1px solid #444;color:#eee;border-radius:4px;resize:vertical;"></textarea>
          </label>
          <div>
            <button type="button" class="button" id="niSubmit">Submit report</button>
            <span id="niStatus" style="margin-left:8px;font-size:12px;color:#aaa;"></span>
          </div>
        </div>
      </details>`
      }
    </div>
  `;

  mount.querySelector("#niSubmit")?.addEventListener("click", async () => {
    const statusEl = mount.querySelector("#niStatus");
    const numOrNull = (id) => {
      const v = mount.querySelector(id)?.value;
      if (v === "" || v == null) return null;
      const n = Number(v);
      return Number.isFinite(n) ? n : null;
    };
    statusEl.textContent = "Saving…";
    try {
      const { data, error } = await supabase.rpc("fixture_network_incident_file", {
        p_fixture_id: fixture.id,
        p_score_home: numOrNull("#niScoreH"),
        p_score_away: numOrNull("#niScoreA"),
        p_match_minute: numOrNull("#niMinute"),
        p_visibility_ok: Boolean(mount.querySelector("#niVisibility")?.checked),
        p_video_available: Boolean(mount.querySelector("#niVideo")?.checked),
        p_evidence_url: mount.querySelector("#niEvidence")?.value || null,
        p_note: mount.querySelector("#niNote")?.value || null,
      });
      if (error) throw error;
      statusEl.textContent = data?.ok ? "Logged." : "Saved.";
      await refreshMount(mount, fixture, myClubShort);
    } catch (err) {
      statusEl.textContent = err?.message || "Failed";
      statusEl.style.color = "#f99";
    }
  });

  mount.querySelectorAll(".ni-ack").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = Number(btn.getAttribute("data-id"));
      const action = btn.getAttribute("data-action");
      if (!confirm(`Mark this network incident as peer ${action}? Fixture status stays unchanged — use scheduling if you need a new kick-off.`)) {
        return;
      }
      try {
        const { error } = await supabase.rpc("fixture_network_incident_peer_ack", {
          p_incident_id: id,
          p_action: action,
        });
        if (error) throw error;
        await refreshMount(mount, fixture, myClubShort);
      } catch (err) {
        alert(err?.message || "Failed");
      }
    });
  });

  mount.querySelectorAll(".ni-escalate").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = Number(btn.getAttribute("data-id"));
      const note = prompt("Optional note for staff escalation:") || null;
      if (
        !confirm(
          "Escalate to staff? This flags a hold for admin review. Fixture status is not changed automatically."
        )
      ) {
        return;
      }
      try {
        const { error } = await supabase.rpc("fixture_network_incident_escalate", {
          p_incident_id: id,
          p_note: note,
        });
        if (error) throw error;
        await refreshMount(mount, fixture, myClubShort);
      } catch (err) {
        alert(err?.message || "Failed");
      }
    });
  });
}

/**
 * Ensure mount exists after #fixturePreview and refresh for current fixture.
 */
export async function wireNetworkIncidentsPanel(fixture, myClubShort) {
  let mount = document.getElementById("networkIncidentsMount");
  if (!mount) {
    const preview = document.getElementById("fixturePreview");
    if (!preview?.parentElement) return;
    mount = document.createElement("div");
    mount.id = "networkIncidentsMount";
    preview.insertAdjacentElement("afterend", mount);
  }
  await refreshMount(mount, fixture, myClubShort);
}
