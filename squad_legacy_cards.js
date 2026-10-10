/**
 * Squad page: legacy cards (no longer on pesdb.net) at the club, with what was
 * paid and a return-for-refund button. Hidden when the club has none.
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

  const rows = cards
    .map((c) => {
      const refund = Number(c.refund) || 0;
      const paidParts = [
        `fee ${formatMoney(Number(c.fee_paid) || 0)}`,
        Number(c.agent_fee) > 0 ? `agent ${formatMoney(Number(c.agent_fee))}` : "",
        Number(c.income_tax) > 0 ? `tax ${formatMoney(Number(c.income_tax))}` : "",
      ]
        .filter(Boolean)
        .join(" + ");
      const label = refund > 0 ? `Return &amp; refund ${formatMoney(refund)}` : "Release (nothing to refund)";
      return `<tr>
        <td>${escapeHtml(c.name)}${
          c.bought_while_legacy ? ' <span class="legacy-flag" title="Bought after the card went legacy">bought while legacy</span>' : ""
        }</td>
        <td>${escapeHtml(c.position || "")}</td>
        <td>${escapeHtml(c.how || "—")}<br><span class="note">${escapeHtml(ukDate(c.bought_at))}</span></td>
        <td>${escapeHtml(ukDate(c.legacy_since))}</td>
        <td>${c.already_refunded ? "Already refunded" : `${paidParts}<br><b>${formatMoney(refund)}</b>`}</td>
        <td>${
          canAct
            ? `<button type="button" class="btn-secondary legacy-refund-btn" data-player-id="${escapeHtml(
                c.player_id
              )}" data-name="${escapeHtml(c.name)}" data-refund="${refund}">${label}</button>`
            : ""
        }</td>
      </tr>`;
    })
    .join("");

  el.hidden = false;
  el.innerHTML = `
    <h2 class="section-header">Legacy cards in your squad</h2>
    <p class="note" style="color:#ddd;">
      These cards are no longer on pesdb.net, so they can't be sold or listed. You can hand any of them back
      at any time, whatever their contract: the player becomes a free agent and the Central Bank refunds what
      you paid for him — fee, agent fee and income tax. No release slot is used.
    </p>
    <table class="star-demotion-table">
      <thead><tr><th>Player</th><th>Pos</th><th>How signed</th><th>Went legacy</th><th>Paid / refund</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <p id="legacyCardsStatus" class="note" role="status"></p>`;

  el.querySelectorAll(".legacy-refund-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const refund = Number(btn.dataset.refund) || 0;
      const msg =
        refund > 0
          ? `Hand ${btn.dataset.name} back and get ${formatMoney(refund)} refunded?\n\nHe becomes a free agent and leaves your squad. This can't be undone.`
          : `Release ${btn.dataset.name}? There is no purchase to refund.\n\nHe becomes a free agent and leaves your squad. This can't be undone.`;
      if (!confirm(msg)) return;
      el.querySelectorAll(".legacy-refund-btn").forEach((b) => (b.disabled = true));
      const status = el.querySelector("#legacyCardsStatus");
      const { data: res, error: refErr } = await supabase.rpc("player_legacy_card_refund", {
        p_player_id: btn.dataset.playerId,
      });
      if (refErr) {
        if (status) {
          status.textContent = refErr.message || "Refund failed.";
          status.style.color = "#e88";
        }
        el.querySelectorAll(".legacy-refund-btn").forEach((b) => (b.disabled = false));
        return;
      }
      alert(
        Number(res?.refund) > 0
          ? `${res.player_name} returned — ${formatMoney(Number(res.refund))} refunded.`
          : `${res?.player_name || btn.dataset.name} released.`
      );
      if (typeof onChanged === "function") await onChanged();
      else await mountLegacyCardsPanel(supabase, clubShort, onChanged, { staffPreview });
    });
  });
}
