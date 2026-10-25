/**
 * Squad page: legacy cards (no longer on pesdb.net) at the club.
 * Owners may release for market value in GPSL June / July only.
 * Does not use voluntary / New Owner release quotas.
 * Player becomes a free agent but stays unsignable while legacy.
 */
import { formatMoney } from "./competition.js";
import { escapeHtml } from "./escape_html.js";

function ukDate(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-GB", {
    timeZone: "Europe/London",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export async function mountLegacyCardsPanel(supabase, clubShort, onChanged, { staffPreview = false } = {}) {
  const el = document.getElementById("legacyCardsPanel");
  if (!el || !clubShort) return;

  const { data, error } = await supabase.rpc("club_legacy_cards", {
    p_club_short_name: staffPreview ? clubShort : null,
  });
  const cards = Array.isArray(data?.cards) ? data.cards : [];
  if (error || !cards.length) {
    el.hidden = true;
    el.innerHTML = "";
    return;
  }

  const canAct = !staffPreview && data?.is_owner !== false;
  const windowOpen = data?.release_window_open === true || data?.can_release === true;
  const canRelease = canAct && windowOpen;

  const rows = cards
    .map((c) => {
      const payout = Number(c.refund) || 0;
      const mv = Number(c.market_value) || 0;
      let actionCell = "";
      if (c.already_refunded) {
        actionCell = '<span class="note">Already released</span>';
      } else if (canRelease) {
        const label =
          payout > 0
            ? `Release for market value ${formatMoney(payout)}`
            : "Release (market value ₿0)";
        actionCell = `<button type="button" class="btn-secondary legacy-refund-btn" data-player-id="${escapeHtml(
          c.player_id
        )}" data-name="${escapeHtml(c.name)}" data-refund="${payout}">${label}</button>`;
      } else if (canAct) {
        actionCell =
          '<span class="note">Release in GPSL June / July only</span>';
      }
      return `<tr>
        <td>${escapeHtml(c.name)}${
          c.bought_while_legacy
            ? ' <span class="legacy-flag" title="Bought after the card went legacy">bought while legacy</span>'
            : ""
        }</td>
        <td>${escapeHtml(c.position || "")}</td>
        <td>${escapeHtml(c.how || "—")}<br><span class="note">${escapeHtml(ukDate(c.bought_at))}</span></td>
        <td>${escapeHtml(ukDate(c.legacy_since))}</td>
        <td><b>${formatMoney(mv)}</b></td>
        <td>${actionCell}</td>
      </tr>`;
    })
    .join("");

  const windowNote = windowOpen
    ? "Release for market value is open now (GPSL June / July)."
    : "Release for market value is only available in <b>GPSL June and July</b>.";

  el.hidden = false;
  el.innerHTML = `
    <h2 class="section-header">Legacy cards in your squad</h2>
    <p class="note" style="color:#ddd;">
      These cards left pesdb.net and stay tagged <b>legacy</b> on your squad.
      In <b>GPSL June and July</b> you can release any of them for <b>market value</b>
      (any contract length). That does <b>not</b> use a voluntary or New Owner release slot.
      They become free agents but remain <b>unsignable</b> while legacy — until a future sync restores the card.
    </p>
    <p class="note" style="color:${windowOpen ? "#8c8" : "#e8a87c"};">${windowNote}</p>
    <table class="star-demotion-table">
      <thead><tr><th>Player</th><th>Pos</th><th>How signed</th><th>Went legacy</th><th>Market value</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <p id="legacyCardsStatus" class="note" role="status"></p>`;

  el.querySelectorAll(".legacy-refund-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const payout = Number(btn.dataset.refund) || 0;
      const msg =
        payout > 0
          ? `Release ${btn.dataset.name} for ${formatMoney(payout)} (market value)?\n\nHe becomes a free agent and stays unsignable while legacy. No release slot is used. This can't be undone.`
          : `Release ${btn.dataset.name}? Market value is ₿0.\n\nHe becomes a free agent and stays unsignable while legacy. No release slot is used. This can't be undone.`;
      if (!confirm(msg)) return;
      el.querySelectorAll(".legacy-refund-btn").forEach((b) => (b.disabled = true));
      const status = el.querySelector("#legacyCardsStatus");
      const { data: res, error: refErr } = await supabase.rpc("player_legacy_card_refund", {
        p_player_id: btn.dataset.playerId,
      });
      if (refErr) {
        if (status) {
          status.textContent = refErr.message || "Release failed.";
          status.style.color = "#e88";
        }
        el.querySelectorAll(".legacy-refund-btn").forEach((b) => (b.disabled = false));
        return;
      }
      alert(
        Number(res?.refund) > 0
          ? `${res.player_name} released for ${formatMoney(Number(res.refund))} (market value).`
          : `${res?.player_name || btn.dataset.name} released.`
      );
      if (typeof onChanged === "function") await onChanged();
      else await mountLegacyCardsPanel(supabase, clubShort, onChanged, { staffPreview });
    });
  });
}
