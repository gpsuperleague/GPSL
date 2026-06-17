/**
 * Comma-formatted ₿ amount fields (bid modals, offers, filters).
 */

export function parseMoneyInput(value) {
  if (value == null || value === "") return 0;
  const n = Number(String(value).replace(/,/g, "").trim());
  return Number.isFinite(n) ? n : 0;
}

export function formatMoneyDigits(amount) {
  const n = Math.round(Number(amount) || 0);
  return n.toLocaleString("en-GB");
}

export function setMoneyInputValue(input, amount) {
  if (!input) return;
  input.value = formatMoneyDigits(amount);
}

/** Format field while typing; returns parsed numeric value. */
export function formatMoneyInputField(
  input,
  { min = null, allowEmpty = false, enforceMin = false } = {}
) {
  if (!input) return 0;
  const raw = String(input.value ?? "").replace(/,/g, "").trim();
  if (allowEmpty && raw === "") return 0;

  let val = Number(raw);
  if (!Number.isFinite(val) || val < 0) val = 0;
  if (enforceMin && min != null && min > 0 && raw !== "" && val < min) {
    val = min;
  }

  if (raw !== "" || !allowEmpty) {
    input.value = formatMoneyDigits(val);
  }
  return val;
}

export function adjustMoneyInput(input, delta, { min = 0 } = {}) {
  const cur = parseMoneyInput(input?.value);
  const next = Math.max(min, cur + delta);
  setMoneyInputValue(input, next);
  return next;
}

/**
 * Wire live comma formatting on an amount input.
 * min: number or () => number
 */
export function wireMoneyBidInput(input, { min = 0, onChange } = {}) {
  if (!input) return null;

  const resolveMin = () => (typeof min === "function" ? min() : min);

  const handler = () => {
    const val = formatMoneyInputField(input, { enforceMin: false });
    onChange?.(val);
  };

  input.addEventListener("input", handler);

  return {
    parse: () => parseMoneyInput(input.value),
    set: (n) => {
      setMoneyInputValue(input, n);
      onChange?.(parseMoneyInput(input.value));
    },
    adjust: (delta) => {
      const v = adjustMoneyInput(input, delta, { min: resolveMin() });
      onChange?.(v);
      return v;
    },
    refreshMin: () => handler(),
  };
}
