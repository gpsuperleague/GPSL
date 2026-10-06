/**
 * Scouting page: turn plain title="" hovers into GPSL info tips (data-gpsl-tip),
 * including content rendered later (target lists, tactic board, auto-bid panel).
 */

const TIP_ATTR = "data-gpsl-tip";
const TIP_CLASS = "gpsl-has-tip";
const SKIP_TAGS = new Set(["IFRAME", "OPTION", "HTML", "HEAD", "TITLE", "LINK", "STYLE", "SCRIPT"]);

function upgradeEl(el) {
  if (!el || el.nodeType !== 1 || SKIP_TAGS.has(el.tagName)) return;
  if (el.closest("#nav")) return;
  const title = el.getAttribute("title");
  if (title == null) return;
  const text = title.trim();
  el.removeAttribute("title");
  if (!text || el.hasAttribute(TIP_ATTR)) return;
  el.setAttribute(TIP_ATTR, text);
  el.classList.add(TIP_CLASS);
  if (!el.hasAttribute("aria-label") && !el.textContent.trim()) {
    el.setAttribute("aria-label", text);
  }
}

function upgradeTree(root) {
  if (!root || root.nodeType !== 1) return;
  upgradeEl(root);
  root.querySelectorAll("[title]").forEach(upgradeEl);
}

let observer = null;

export function upgradeTitlesToTips(root = document.body) {
  if (!root) return;
  upgradeTree(root);
  if (observer) return;
  observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      if (m.type === "attributes") {
        upgradeEl(m.target);
      } else {
        m.addedNodes.forEach((n) => upgradeTree(n));
      }
    }
  });
  observer.observe(root, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["title"],
  });
}
