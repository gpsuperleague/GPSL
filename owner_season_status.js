/**
 * Owner season board status (mirrors admin Season owner board ticks).
 * Testing / Live Season 1 — In or Out.
 * Club auction — In, Out, or Completed (already has a club).
 */

export function seasonStatusFromRegistry(self) {
  let auction = "out";
  if (self?.has_club) auction = "completed";
  else if (self?.needs_club_auction) auction = "in";

  return {
    testIn: !!self?.confirmed_test_season,
    liveIn: !!self?.confirmed_live_season,
    auction,
  };
}

function pillInOut(inOut) {
  const on = !!inOut;
  const cls = on ? "owner-season-pill is-in" : "owner-season-pill is-out";
  const label = on ? "In" : "Out";
  return `<span class="${cls}" aria-label="${label}">${label}</span>`;
}

function auctionPill(state) {
  if (state === "completed") {
    return `<span class="owner-season-pill is-done" aria-label="Completed" title="Already own a club">Completed</span>`;
  }
  if (state === "in") {
    return `<span class="owner-season-pill is-in" aria-label="In">In</span>`;
  }
  return `<span class="owner-season-pill is-out" aria-label="Out">Out</span>`;
}

/**
 * @param {HTMLElement|null} root
 * @param {object|null} self — owner_registry_get_self payload
 * @param {{ compact?: boolean }} [opts]
 */
export function renderOwnerSeasonStatus(root, self, opts = {}) {
  if (!root) return;
  if (!self?.authenticated) {
    root.hidden = true;
    root.innerHTML = "";
    return;
  }

  const { testIn, liveIn, auction } = seasonStatusFromRegistry(self);
  const compact = !!opts.compact;
  root.hidden = false;
  root.innerHTML = `
    ${compact ? "" : "<h2>Season</h2>"}
    ${compact ? "" : '<p class="note">Your place on the season board (set by admin).</p>'}
    <ul class="owner-season-status-list${compact ? " is-compact" : ""}">
      <li>
        <span class="owner-season-label">Testing season</span>
        ${pillInOut(testIn)}
      </li>
      <li>
        <span class="owner-season-label">Live participation · Season 1</span>
        ${pillInOut(liveIn)}
      </li>
      <li>
        <span class="owner-season-label">Club auction invitation</span>
        ${auctionPill(auction)}
      </li>
    </ul>
  `;
}

export const OWNER_SEASON_STATUS_CSS = `
.owner-season-status-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.owner-season-status-list.is-compact {
  flex-direction: row;
  flex-wrap: wrap;
  gap: 8px 14px;
}
.owner-season-status-list li {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 8px 10px;
  background: #141414;
  border: 1px solid #2a2a2a;
  border-radius: 6px;
}
.owner-season-status-list.is-compact li {
  flex: 1 1 180px;
  padding: 6px 10px;
}
.owner-season-label {
  font-size: 13px;
  color: #ccc;
  line-height: 1.3;
}
.owner-season-pill {
  flex: 0 0 auto;
  min-width: 2.6em;
  text-align: center;
  font-size: 12px;
  font-weight: bold;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  padding: 4px 10px;
  border-radius: 4px;
  border: 1px solid #444;
}
.owner-season-pill.is-in {
  color: #1a1a1a;
  background: #8d8;
  border-color: #6a6;
}
.owner-season-pill.is-out {
  color: #bbb;
  background: #2a2a2a;
  border-color: #444;
}
.owner-season-pill.is-done {
  color: #1a1a1a;
  background: #8ab;
  border-color: #689;
}
`;
