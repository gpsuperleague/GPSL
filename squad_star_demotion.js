/**
 * Squad page: shown only when the club lost big-club status this season and is
 * over its reduced star cap — release over-cap stars at 125% MV until August.
 */
import { formatMoney } from "./competition.js";
import { escapeHtml } from "./escape_html.js";

export async function mountStarDemotionPanel(supabase, clubShort, onReleased) {
  const el = document.getElementById("starDemotionPanel");
  if (!el || !clubShort) return;

  const { data, error } = await supabase.rpc("club_star_demotion_state", {
    p_club_short_name: clubShort,
  });
  if (error || !data?.demoted || Number(data.over) <= 0) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }

  const deadline = data.deadline
    ? new Date(data.deadline).toLocaleString("en-GB", {
        weekday: "short",
        day: "numeric",
        month: "short",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "GPSL August";

  const rows = (data.stars || [])
    .map(
      (s) => `<tr>
        <td>${escapeHtml(s.name)}</td>
        <td>${escapeHtml(s.position || "")}</td>
        <td>${escapeHtml(String(s.rating ?? ""))}</td>
        <td>${formatMoney(Number(s.market_value) || 0)}</td>
        <td><b>${formatMoney(Number(s.release_fee) || 0)}</b></td>
        <td>${
          data.window_open
            ? `<button type="button" class="btn-secondary star-demotion-release" data-player-id="${escapeHtml(
                s.player_id
              )}" data-name="${escapeHtml(s.name)}" data-fee="${Number(s.release_fee) || 0}">Release @ 125%</button>`
            : ""
        }</td>
      </tr>`
    )
    .join("");

  el.hidden = false;
  el.innerHTML = `
    <h2 class="section-header">⭐ Lost big-club status</h2>
    <p class="note" style="color:#ddd;">
      Your star cap is now <b>${data.star_cap}</b> and you have <b>${data.star_count}</b> star players
      (<b>${data.over}</b> over). ${
        data.window_open
          ? `Until <b>${escapeHtml(deadline)}</b> you can sell on the open market, or release an over-cap star here for <b>125% of market value</b>.`
          : "The 125% release window has closed."
      }
      Still over the cap when August starts: lowest-rated stars are released at market value plus a ₿2.5m fine each.
    </p>
    <table class="star-demotion-table">
      <thead><tr><th>Player</th><th>Pos</th><th>Rating</th><th>Market value</th><th>You receive</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <p id="starDemotionStatus" class="note" role="status"></p>`;

  el.querySelectorAll(".star-demotion-release").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const fee = formatMoney(Number(btn.dataset.fee) || 0);
      if (!confirm(`Release ${btn.dataset.name} for ${fee} (125% of market value)? This can't be undone.`)) return;
      el.querySelectorAll(".star-demotion-release").forEach((b) => (b.disabled = true));
      const status = el.querySelector("#starDemotionStatus");
      const { error: relErr } = await supabase.rpc("player_star_demotion_release", {
        p_player_id: btn.dataset.playerId,
      });
      if (relErr) {
        if (status) {
          status.textContent = relErr.message || "Release failed.";
          status.style.color = "#e88";
        }
        el.querySelectorAll(".star-demotion-release").forEach((b) => (b.disabled = false));
        return;
      }
      if (typeof onReleased === "function") await onReleased();
      else await mountStarDemotionPanel(supabase, clubShort, onReleased);
    });
  });
}
