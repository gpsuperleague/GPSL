/**
 * − / + steppers flanking dual-range age / rating / market-value filters.
 * Left pair controls the min thumb; right pair controls the max thumb.
 * Age & rating: step 1. Market-value-like money cols: step ₿500,000.
 */

export const RANGE_STEP_MONEY = 500_000;

const MONEY_COLS = new Set(["market_value", "listed_price", "current_bid"]);

const DEFAULT_STEPPER_COLS = new Set([
  "Age",
  "age",
  "Rating",
  "rating",
  "market_value",
  "listed_price",
  "current_bid",
]);

export function rangeStepperStep(col) {
  return MONEY_COLS.has(col) ? RANGE_STEP_MONEY : 1;
}

export function ensureRangeStepperStyles() {
  const STYLE_ID = "range-stepper-styles-v2";
  if (document.getElementById(STYLE_ID)) return;
  document.getElementById("range-stepper-styles")?.remove();
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = `
    .range-filter-step-row {
      display: flex;
      align-items: center;
      gap: 6px;
      margin-top: 2px;
    }
    .range-filter-step-row .range-filter-sliders {
      flex: 1 1 auto;
      min-width: 160px;
    }
    .range-step-pair {
      display: inline-flex;
      flex: 0 0 auto;
      align-items: center;
      gap: 3px;
      padding: 2px;
      border: 1px solid #3a3a3a;
      border-radius: 5px;
      background: #181818;
    }
    .range-step-btn {
      flex: 0 0 auto;
      width: 24px;
      height: 24px;
      padding: 0;
      border: 1px solid #555;
      border-radius: 3px;
      background: #252525;
      color: #ffaa22;
      font-size: 15px;
      font-weight: 700;
      line-height: 1;
      cursor: pointer;
      user-select: none;
    }
    .range-step-btn:hover:not(:disabled) {
      background: #333;
      border-color: #ff9900;
      color: #ffcc66;
    }
    .range-step-btn:active:not(:disabled) {
      background: #3d2a00;
    }
    .range-step-btn:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }
  `;
  document.head.appendChild(style);
}

function makeStepButton(dir, end, col) {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "range-step-btn";
  btn.dataset.dir = String(dir);
  btn.dataset.end = end;
  const verb = dir < 0 ? "Decrease" : "Increase";
  const which = end === "min" ? "minimum" : "maximum";
  btn.setAttribute("aria-label", `${verb} ${col} ${which}`);
  btn.textContent = dir < 0 ? "−" : "+";
  return btn;
}

function makeStepPair(end, col) {
  const pair = document.createElement("div");
  pair.className = "range-step-pair";
  pair.dataset.end = end;
  pair.append(makeStepButton(-1, end, col), makeStepButton(1, end, col));
  return pair;
}

/**
 * Wrap each matching .range-filter's sliders with −/+ on both sides.
 * Left pair → min thumb; right pair → max thumb.
 *
 * @param {{
 *   root?: ParentNode,
 *   cols?: string[],
 *   stepForCol?: (col: string) => number,
 * }} [opts]
 */
export function installRangeSteppers(opts = {}) {
  ensureRangeStepperStyles();
  const root = opts.root || document;
  const allow = opts.cols ? new Set(opts.cols) : DEFAULT_STEPPER_COLS;

  root.querySelectorAll(".range-filter[data-col]").forEach((wrap) => {
    const col = wrap.getAttribute("data-col") || "";
    if (!allow.has(col)) return;

    // Upgrade older single-button layout if present.
    const existingRow = wrap.querySelector(".range-filter-step-row");
    if (existingRow?.querySelector(".range-step-pair")) return;
    if (existingRow) {
      const keep = existingRow.querySelector(".range-filter-sliders");
      if (keep) existingRow.replaceWith(keep);
      else existingRow.remove();
    }

    const sliders = wrap.querySelector(".range-filter-sliders");
    if (!sliders) return;

    const minEl = sliders.querySelector(".range-filter-min");
    const maxEl = sliders.querySelector(".range-filter-max");
    if (!minEl || !maxEl) return;

    const row = document.createElement("div");
    row.className = "range-filter-step-row";
    const leftPair = makeStepPair("min", col);
    const rightPair = makeStepPair("max", col);

    sliders.replaceWith(row);
    row.append(leftPair, sliders, rightPair);

    const allBtns = [...leftPair.querySelectorAll(".range-step-btn"), ...rightPair.querySelectorAll(".range-step-btn")];

    const syncDisabled = () => {
      const dis = minEl.disabled || maxEl.disabled;
      for (const btn of allBtns) btn.disabled = dis;
    };

    const stepSize = () => {
      if (typeof opts.stepForCol === "function") {
        const s = Number(opts.stepForCol(col));
        if (Number.isFinite(s) && s > 0) return s;
      }
      const fromEl = Number(minEl.step);
      if (Number.isFinite(fromEl) && fromEl > 0) return fromEl;
      return rangeStepperStep(col);
    };

    const nudge = (end, dir) => {
      if (minEl.disabled || maxEl.disabled) return;
      const el = end === "min" ? minEl : maxEl;
      const step = stepSize();
      const floor = Number(el.min);
      const ceiling = Number(el.max);
      let next = Number(el.value) + dir * step;
      if (!Number.isFinite(next)) return;
      next = Math.max(floor, Math.min(ceiling, next));

      const otherVal = Number(end === "min" ? maxEl.value : minEl.value);
      if (end === "min" && next > otherVal) next = otherVal;
      if (end === "max" && next < otherVal) next = otherVal;

      el.value = String(next);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      syncDisabled();
    };

    row.addEventListener("click", (e) => {
      const btn = e.target?.closest?.(".range-step-btn");
      if (!btn || !row.contains(btn)) return;
      e.preventDefault();
      e.stopPropagation();
      const end = btn.dataset.end === "max" ? "max" : "min";
      const dir = Number(btn.dataset.dir) < 0 ? -1 : 1;
      nudge(end, dir);
    });

    const mo = new MutationObserver(syncDisabled);
    mo.observe(minEl, { attributes: true, attributeFilter: ["disabled"] });
    mo.observe(maxEl, { attributes: true, attributeFilter: ["disabled"] });
    syncDisabled();
  });
}
