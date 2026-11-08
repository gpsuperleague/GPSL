/**
 * Read-only formation pitch (Match Day layout) for TOTM / awards displays.
 */

import {
  DEFAULT_FORMATION_ID,
  getFormation,
  formationDisplayName,
} from "./matchday_formations.js";
import {
  pesdbPlayerCardUrl,
  pesdbPlayerUrl,
  playerNameLinkHtml,
  clubNameLinkHtml,
  escapePlayerHtml,
  PESDB_FALLBACK_CARD_IMG,
} from "./player_links.js";

function escapeHtml(text) {
  return escapePlayerHtml(text);
}

function renderMemberStats(member) {
  const cells = [
    { val: member.appearances ?? 0, lbl: "apps" },
    { val: member.goals ?? 0, lbl: "G" },
    { val: member.assists ?? 0, lbl: "A" },
    {
      val: member.avg_rating != null ? Number(member.avg_rating).toFixed(2) : "—",
      lbl: "avg",
    },
  ];

  return `<div class="pitch-stat-grid">${cells
    .map(
      (c) => `
      <div class="pitch-stat-cell">
        <span class="pitch-stat-val">${escapeHtml(String(c.val))}</span>
        <span class="pitch-stat-lbl">${escapeHtml(c.lbl)}</span>
      </div>`
    )
    .join("")}</div>`;
}

function renderPitchPlayerCard(member, { highlight = false, showStats = true, showClub = true } = {}) {
  if (!member?.player_id) {
    return '<span class="pitch-slot-placeholder" aria-hidden="true"></span>';
  }

  const id = String(member.player_id);
  const name = member.player_name || id;
  const highlightClass = highlight ? " pitch-player-card--highlight" : "";
  const club = showClub
    ? `<div class="spc-club pitch-player-club">
          ${clubNameLinkHtml(member.club_short_name, member.club_name || member.club_short_name)}
        </div>`
    : "";

  return `
    <div class="squad-player-card squad-player-card--pitch pitch-player-card--readonly${highlightClass}">
      <a href="${pesdbPlayerUrl(id)}" target="_blank" rel="noopener" class="squad-player-card-thumb-link">
        <img src="${pesdbPlayerCardUrl(id)}" alt="" onerror="this.src='${PESDB_FALLBACK_CARD_IMG}'">
      </a>
      <div class="spc-meta pitch-player-meta">
        <div class="spc-name pitch-player-name">${playerNameLinkHtml(id, name)}</div>
        ${club}
        ${showStats ? renderMemberStats(member) : ""}
      </div>
    </div>`;
}

function renderPitchSlot(slot, member, opts) {
  const label = member?.slot_label || slot.label;
  const highlight =
    opts.highlightClub && member?.club_short_name === opts.highlightClub;

  return `
    <div class="pitch-slot pitch-slot--readonly" data-slot-id="${escapeHtml(slot.id)}" style="left:${slot.x}%;top:${slot.y}%;">
      <span class="pitch-slot-label pitch-slot-label--readonly">${escapeHtml(label)}</span>
      <div class="pitch-slot-drop pitch-slot-drop--readonly">
        ${
          member
            ? renderPitchPlayerCard(member, {
                highlight,
                showStats: opts.showStats !== false,
                showClub: opts.showClub !== false,
              })
            : '<span class="pitch-slot-placeholder" aria-hidden="true"></span>'
        }
      </div>
    </div>`;
}

/**
 * @param {object} options
 * @param {string} [options.formationId]
 * @param {Array} [options.members] — rows with pitch_slot, player_id, player_name, etc.
 * @param {string} [options.metaHtml]
 * @param {string|null} [options.highlightClub]
 * @param {string} [options.tableHtml]
 * @param {Array} [options.slots] — override template slots ({ id, x, y, label })
 * @param {string} [options.title]
 * @param {boolean} [options.showStats]
 * @param {boolean} [options.showClub]
 */
export function renderFormationPitchHtml({
  formationId,
  members = [],
  metaHtml = "",
  highlightClub = null,
  tableHtml = "",
  slots = null,
  title = "",
  showStats = true,
  showClub = true,
}) {
  const formation = getFormation(formationId || DEFAULT_FORMATION_ID);
  const bySlot = new Map(members.map((m) => [m.pitch_slot, m]));
  const slotList = Array.isArray(slots) && slots.length ? slots : formation.slots;
  const caption = title || formationDisplayName(formation);
  const slotsHtml = slotList
    .map((slot) =>
      renderPitchSlot(slot, bySlot.get(slot.id), { highlightClub, showStats, showClub })
    )
    .join("");

  return `
    <div class="pitch-display">
      ${metaHtml}
      <p class="pitch-display-formation">${escapeHtml(caption)}</p>
      <div class="pitch-stage pitch-stage--readonly">
        <div class="football-pitch football-pitch--readonly" role="img" aria-label="${escapeHtml(caption)} formation">
          <div class="pitch-center-circle" aria-hidden="true"></div>
          ${slotsHtml}
        </div>
      </div>
      ${
        tableHtml
          ? `<details class="pitch-display-table"><summary>View stats table</summary>${tableHtml}</details>`
          : ""
      }
    </div>`;
}
