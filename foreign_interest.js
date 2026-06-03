/**
 * Foreign club interest (squad sell-to-foreign UX).
 */

export const FOREIGN_SALE_ACTION_PREFIX = "foreign:";

/** "A, B and C are tracking your players" */
export function formatForeignTrackingMessage(teams) {
  const list = (teams || []).map((t) => String(t).trim()).filter(Boolean);
  if (list.length === 0) return "";

  const names = formatEnglishList(list);
  const verb = list.length === 1 ? "is" : "are";
  return `${names} ${verb} tracking your players`;
}

export function formatEnglishList(items) {
  if (!items.length) return "";
  if (items.length === 1) return items[0];
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}

export function foreignSaleActionValue(index) {
  return `${FOREIGN_SALE_ACTION_PREFIX}${index}`;
}

export function parseForeignSaleAction(action) {
  if (!action || !String(action).startsWith(FOREIGN_SALE_ACTION_PREFIX)) {
    return null;
  }
  const idx = Number(String(action).slice(FOREIGN_SALE_ACTION_PREFIX.length));
  if (!Number.isInteger(idx) || idx < 0) return null;
  return idx;
}

export function foreignSaleOptionsHtml(teams) {
  return (teams || [])
    .map(
      (name, i) =>
        `<option value="${foreignSaleActionValue(i)}">Sell to ${escapeHtml(name)}</option>`
    )
    .join("\n");
}

export function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
