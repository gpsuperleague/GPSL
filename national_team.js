import { supabase, initGlobal } from "./global.js";
import {
  loadInternationalNations,
  loadNationalSquad,
  loadMyNation,
  releaseCallup,
  callUpPlayer,
} from "./international.js";

function getNationCode() {
  return new URLSearchParams(window.location.search).get("nation")?.toUpperCase() || null;
}

function renderSquad(rows, isMyNation) {
  const el = document.getElementById("squadTable");
  if (!el) return;
  if (!rows.length) {
    el.innerHTML = '<p class="empty">No players called up yet.</p>';
    return;
  }
  const body = rows
    .map((r) => {
      const rating = r.intl_avg_rating != null ? r.intl_avg_rating.toFixed(2) : "—";
      const releaseBtn = isMyNation
        ? `<button type="button" class="button" data-release="${r.player_id}" style="padding:4px 8px;font-size:11px;">Release</button>`
        : "";
      return `
        <tr>
          <td>${r.player_name || r.player_id}</td>
          <td>${r.player_position || "—"}</td>
          <td>${r.player_age ?? "—"}</td>
          <td>${r.club_short_name}</td>
          <td>${r.intl_caps}</td>
          <td>${r.intl_goals}</td>
          <td>${r.intl_assists}</td>
          <td>${r.intl_potm}</td>
          <td>${rating}</td>
          <td>${releaseBtn}</td>
        </tr>`;
    })
    .join("");

  el.innerHTML = `
    <table class="intl-table">
      <thead>
        <tr>
          <th>Player</th><th>Pos</th><th>Age</th><th>Club</th>
          <th>Caps</th><th>G</th><th>A</th><th>POTM</th><th>Avg</th><th></th>
        </tr>
      </thead>
      <tbody>${body}</tbody>
    </table>`;

  if (isMyNation) {
    el.querySelectorAll("[data-release]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const res = await releaseCallup(btn.dataset.release, supabase);
        if (res.error) {
          alert(res.error);
          return;
        }
        location.reload();
      });
    });
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();

  const code = getNationCode();
  const nations = await loadInternationalNations(supabase);
  const nation = nations.find((n) => n.code === code) || nations[0];
  if (!nation) {
    document.getElementById("natTitle").textContent = "National team not found";
    return;
  }

  const myNation = await loadMyNation(supabase);
  const isMyNation = myNation?.code === nation.code;

  document.getElementById("natFlag").textContent = nation.flag_emoji;
  document.getElementById("natTitle").textContent = nation.name;
  document.getElementById("natMeta").innerHTML = nation.owner_club
    ? `Managed by <b>${nation.owner_club_name || nation.owner_club}</b> (${nation.owner_club})`
    : "Unassigned — available in nation selection";

  if (isMyNation) {
    const link = document.getElementById("callUpLink");
    if (link) link.hidden = false;
  }

  if (!code && nation.code) {
    history.replaceState(null, "", `?nation=${encodeURIComponent(nation.code)}`);
  }

  const squad = await loadNationalSquad(nation.code, supabase);
  renderSquad(squad, isMyNation);

  if (isMyNation) {
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data: clubRow } = await supabase
      .from("Clubs")
      .select("ShortName")
      .eq("owner_id", user?.id)
      .maybeSingle();
    if (clubRow?.ShortName) {
      const { data: clubPlayers } = await supabase
        .from("Players")
        .select("Konami_ID, Name, Position, Age, Nation")
        .eq("Contracted_Team", clubRow.ShortName)
        .order("Name");
      const called = new Set(squad.map((s) => s.player_id));
      const pool = (clubPlayers || []).filter(
        (p) => !called.has(String(p.Konami_ID))
      );
      const panel = document.getElementById("callUpPanel");
      const poolEl = document.getElementById("clubPoolTable");
      if (panel && poolEl) {
        panel.hidden = false;
        if (!pool.length) {
          poolEl.innerHTML = '<p class="empty">All club players are already called up.</p>';
        } else {
          poolEl.innerHTML = `
            <table class="intl-table">
              <thead><tr><th>Player</th><th>Pos</th><th>Age</th><th></th></tr></thead>
              <tbody>
                ${pool
                  .map(
                    (p) => `
                  <tr>
                    <td style="text-align:left">${p.Name}</td>
                    <td>${p.Position || "—"}</td>
                    <td>${p.Age ?? "—"}</td>
                    <td><button type="button" class="button" data-call="${p.Konami_ID}" style="padding:4px 10px;font-size:11px;">Call up</button></td>
                  </tr>`
                  )
                  .join("")}
              </tbody>
            </table>`;
          poolEl.querySelectorAll("[data-call]").forEach((btn) => {
            btn.addEventListener("click", async () => {
              const res = await callUpPlayer(String(btn.dataset.call), supabase);
              if (res.error) {
                alert(res.error);
                return;
              }
              location.reload();
            });
          });
        }
      }
    }
  }
});
