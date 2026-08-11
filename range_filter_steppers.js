/**
 * − / + steppers flanking dual-range age / rating / market-value filters.
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
  if (document.getElementById("range-stepper-styles")) return;
  const style = document.createElement("style");
  style.id = "range-stepper-styles";
  style.textContent = `
    .range-filter-step-row {
      display: flex;
      align-items: center;
      gap: 6px;
      margin-top: 2px;
    }
    .range-filter-step-row .range-filter-sliders {
      flex: 1 1 auto;
      min-width: 0;
      margin-top: 0;
    }
    .range-step-btn {
      flex: 0 0 auto;
      width: 28px;
      height: 26px;
      padding: 0;
      border: 1px solid #666;
      border-radius: 4px;
      background: #222;
      color: #ffaa22;
      font-size: 16px;
      font-weight: 700;
      line-height: 1;
      cursor: pointer;
      user-select: none;
    }
    .range-step-btn:hover:not(:disabled) {
      background: #333;
      border-color: #ff9900;
    }
    .range-step-btn:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }
  `;
  document.head.appendChild(style);
}

/**
 * Wrap each matching .range-filter's sliders with − (left) and + (right).
 * Nudges the last-used thumb (default: − → min, + → max) by the input's step
 * (or stepForCol), then dispatches `input` so existing handlers run.
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
    if (wrap.querySelector(".range-filter-step-row")) return;

    const sliders = wrap.querySelector(".range-filter-sliders");
    if (!sliders) return;

    const minEl = sliders.querySelector(".range-filter-min");
    const maxEl = sliders.querySelector(".range-filter-max");
    if (!minEl || !maxEl) return;

    const row = document.createElement("div");
    row.className = "range-filter-step-row";

    const minus = document.createElement("button");
    minus.type = "button";
    minus.className = "range-step-btn";
    minus.dataset.dir = "-1";
    minus.setAttribute("aria-label", `Decrease ${col} filter`);
    minus.textContent = "−";

    const plus = document.createElement("button");
    plus.type = "button";
    plus.className = "range-step-btn";
    plus.dataset.dir = "1";
    plus.setAttribute("aria-label", `Increase ${col} filter`);
    plus.textContent = "+";

    sliders.replaceWith(row);
    row.append(minus, sliders, plus);

    let activeEnd = null;

    const syncDisabled = () => {
      const dis = minEl.disabled || maxEl.disabled;
      minus.disabled = dis;
      plus.disabled = dis;
    };

    const mark = (end) => {
      activeEnd = end;
    };
    minEl.addEventListener("pointerdown", () => mark("min"));
    maxEl.addEventListener("pointerdown", () => mark("max"));
    minEl.addEventListener("focus", () => mark("min"));
    maxEl.addEventListener("focus", () => mark("max"));

    const stepSize = () => {
      if (typeof opts.stepForCol === "function") {
        const s = Number(opts.stepForCol(col));
        if (Number.isFinite(s) && s > 0) return s;
      }
      const fromEl = Number(minEl.step);
      if (Number.isFinite(fromEl) && fromEl > 0) return fromEl;
      return rangeStepperStep(col);
    };

    const nudge = (dir) => {
      if (minEl.disabled || maxEl.disabled) return;
      const end = activeEnd || (dir < 0 ? "min" : "max");
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
      activeEnd = end;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      syncDisabled();
    };

    minus.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      nudge(-1);
    });
    plus.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      nudge(1);
    });

    const mo = new MutationObserver(syncDisabled);
    mo.observe(minEl, { attributes: true, attributeFilter: ["disabled"] });
    mo.observe(maxEl, { attributes: true, attributeFilter: ["disabled"] });
    syncDisabled();
  });
}
