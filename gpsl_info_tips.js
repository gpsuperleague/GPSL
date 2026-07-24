/**
 * Translucent hover / focus info tips (data-gpsl-tip).
 * Event-delegated — works for content re-rendered later.
 */

const TIP_ATTR = "data-gpsl-tip";
const TIP_CLASS = "gpsl-has-tip";

let tipEl = null;
let activeAnchor = null;
let hideTimer = null;
let bound = false;

export function escapeTipAttr(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;");
}

/** data-gpsl-tip + tabindex only (merge gpsl-has-tip into your existing class). */
export function tipDataAttrs(text) {
  const tip = String(text ?? "").trim();
  if (!tip) return "";
  return ` ${TIP_ATTR}="${escapeTipAttr(tip)}" tabindex="0"`;
}

/** Full class="gpsl-has-tip …" + data-gpsl-tip when building the element’s only class attr. */
export function tipAttrs(text, extraClass = "") {
  const tip = String(text ?? "").trim();
  const cls = [TIP_CLASS, extraClass].filter(Boolean).join(" ");
  if (!tip) return extraClass ? ` class="${extraClass}"` : "";
  return ` class="${cls}" ${TIP_ATTR}="${escapeTipAttr(tip)}" tabindex="0"`;
}

/** Wrap inner HTML in a tip span (keeps links clickable inside). */
export function withInfoTip(innerHtml, text, { className = "", as = "span" } = {}) {
  const tip = String(text ?? "").trim();
  if (!tip) return innerHtml;
  const cls = [TIP_CLASS, className].filter(Boolean).join(" ");
  return `<${as} class="${cls}" ${TIP_ATTR}="${escapeTipAttr(tip)}" tabindex="0">${innerHtml}</${as}>`;
}

function ensureTipEl() {
  if (tipEl && document.body.contains(tipEl)) return tipEl;
  tipEl = document.createElement("div");
  tipEl.className = "gpsl-info-tip";
  tipEl.setAttribute("role", "tooltip");
  tipEl.hidden = true;
  document.body.appendChild(tipEl);
  return tipEl;
}

function findTipAnchor(node) {
  if (!node || node.nodeType !== 1) return null;
  return node.closest(`[${TIP_ATTR}]`);
}

function positionTip(anchor) {
  const el = ensureTipEl();
  const rect = anchor.getBoundingClientRect();
  const margin = 10;
  const tipRect = el.getBoundingClientRect();
  let top = rect.bottom + margin;
  let left = rect.left + rect.width / 2 - tipRect.width / 2;

  if (top + tipRect.height > window.innerHeight - 8) {
    top = rect.top - tipRect.height - margin;
  }
  if (top < 8) top = 8;
  if (left < 8) left = 8;
  if (left + tipRect.width > window.innerWidth - 8) {
    left = window.innerWidth - tipRect.width - 8;
  }

  el.style.top = `${Math.round(top)}px`;
  el.style.left = `${Math.round(left)}px`;
}

function showTip(anchor) {
  const text = anchor?.getAttribute(TIP_ATTR);
  if (!text) return;
  clearTimeout(hideTimer);
  activeAnchor = anchor;
  const el = ensureTipEl();
  el.textContent = text;
  el.hidden = false;
  el.classList.add("is-visible");
  // dual rAF so layout runs before measure
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      if (activeAnchor === anchor) positionTip(anchor);
    });
  });
}

function hideTipSoon() {
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => {
    activeAnchor = null;
    if (!tipEl) return;
    tipEl.classList.remove("is-visible");
    tipEl.hidden = true;
  }, 80);
}

function onPointerOver(e) {
  const anchor = findTipAnchor(e.target);
  if (!anchor) return;
  showTip(anchor);
}

function onPointerOut(e) {
  const anchor = findTipAnchor(e.target);
  if (!anchor) return;
  const next = e.relatedTarget;
  if (next && anchor.contains(next)) return;
  if (next === tipEl || tipEl?.contains(next)) return;
  hideTipSoon();
}

function onFocusIn(e) {
  const anchor = findTipAnchor(e.target);
  if (anchor) showTip(anchor);
}

function onFocusOut(e) {
  const anchor = findTipAnchor(e.target);
  if (!anchor) return;
  const next = e.relatedTarget;
  if (next && anchor.contains(next)) return;
  hideTipSoon();
}

function onScrollOrResize() {
  if (activeAnchor && tipEl && !tipEl.hidden) {
    positionTip(activeAnchor);
  }
}

/** Call once per page (safe to call again). */
export function initGpslInfoTips(root = document) {
  if (bound) return;
  bound = true;
  root.addEventListener("pointerover", onPointerOver);
  root.addEventListener("pointerout", onPointerOut);
  root.addEventListener("focusin", onFocusIn);
  root.addEventListener("focusout", onFocusOut);
  window.addEventListener("scroll", onScrollOrResize, true);
  window.addEventListener("resize", onScrollOrResize);
}
