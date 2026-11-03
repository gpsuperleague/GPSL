/**
 * Want-to-sell marks (private) + other clubs scouting your players (badge tips).
 */
import { escapeHtml } from "./foreign_interest.js";

export function saleMarkBadgeHtml(marked, note) {
  if (!marked) return "";
  const tip = note
    ? `Marked for sale — ${note}`
    : "Marked for sale (your note only — not listed yet)";
  return `<span class="squad-sale-mark-badge gpsl-has-tip" data-gpsl-tip="${escapeHtml(
    tip
  )}" title="${escapeHtml(tip)}" tabindex="0">SELL</span>`;
}

export function scoutingInterestBadgesHtml(clubs) {
  const list = Array.isArray(clubs) ? clubs : [];
  if (!list.length) return "";
  return list
    .map((c) => {
      const short = String(c?.club_short_name || "").trim().toUpperCase();
      if (!short) return "";
      const clubName = String(c?.club_name || short).trim();
      const tag = String(c?.owner_tag || "—").trim();
      const tip = `${clubName} · ${tag}${
        c?.is_active_target ? " · active target" : ""
      }`;
      return `<img class="squad-scout-interest-badge tc-scout-interest-badge gpsl-has-tip" src="images/club_badges/${encodeURIComponent(
        short
      )}.png" alt="${escapeHtml(short)}" width="18" height="18" loading="lazy" data-gpsl-tip="${escapeHtml(
        tip
      )}" title="${escapeHtml(tip)}" tabindex="0" onerror="this.style.display='none'">`;
    })
    .filter(Boolean)
    .join("");
}

export async function loadClubSaleMarks(supabase) {
  const { data, error } = await supabase.rpc("club_player_sale_marks_list");
  if (error) throw error;
  const marks = Array.isArray(data?.marks) ? data.marks : [];
  const byPlayer = new Map();
  for (const m of marks) {
    const pid = String(m?.player_id ?? "").trim();
    if (!pid) continue;
    byPlayer.set(pid, m);
  }
  return {
    marks,
    byPlayer,
    totalMarketValue: Number(data?.total_market_value || 0),
    club: data?.club || null,
  };
}

export async function setClubSaleMark(
  supabase,
  playerId,
  wantToSell,
  note = null
) {
  const { data, error } = await supabase.rpc("club_player_sale_mark_set", {
    p_player_id: String(playerId ?? "").trim(),
    p_want_to_sell: !!wantToSell,
    p_note: note == null || note === "" ? null : String(note).slice(0, 280),
  });
  if (error) throw error;
  return data;
}

export async function loadMyPlayersScoutingInterest(supabase, playerIds = null) {
  const payload =
    Array.isArray(playerIds) && playerIds.length
      ? { p_player_ids: playerIds.map((id) => String(id)) }
      : { p_player_ids: null };
  const { data, error } = await supabase.rpc(
    "club_my_players_scouting_interest",
    payload
  );
  if (error) throw error;
  const raw = data?.by_player && typeof data.by_player === "object"
    ? data.by_player
    : {};
  const byPlayer = new Map();
  for (const [pid, clubs] of Object.entries(raw)) {
    byPlayer.set(String(pid), Array.isArray(clubs) ? clubs : []);
  }
  return { byPlayer, club: data?.club || null };
}
