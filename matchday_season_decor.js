/**
 * Seasonal decoration motifs for Fixtures matchday header panels.
 * Inline SVG — clipped inside .matchday-head, non-interactive.
 */

function icon(svgInner, { x = "50%", y = "50%", size = 22, rotate = 0, opacity = 0.7 } = {}) {
  return (
    `<span class="md-season-icon" style="` +
    `left:${x};top:${y};width:${size}px;height:${size}px;` +
    `opacity:${opacity};transform:translate(-50%,-50%) rotate(${rotate}deg);` +
    `">` +
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" aria-hidden="true">${svgInner}</svg>` +
    `</span>`
  );
}

/* Compact motif library */
const M = {
  sunglasses:
    `<path fill="#f0c14b" d="M3 10h6l1 1.5H14L15 10h6v2.2c0 2.4-1.8 4.3-4.2 4.3S13 14.6 13 12.2h-2c0 2.4-1.8 4.3-4.2 4.3S3 14.6 3 12.2V10z"/><path fill="#222" d="M4.2 11.2h4.2v2.4c0 1.2-.9 2.1-2.1 2.1S4.2 14.8 4.2 13.6v-2.4zm11.4 0h4.2v2.4c0 1.2-.9 2.1-2.1 2.1s-2.1-.9-2.1-2.1v-2.4z"/>`,
  beachBall:
    `<circle cx="12" cy="12" r="8" fill="#eee"/><path fill="#e85d4c" d="M12 4a8 8 0 0 0-7.5 5.3L12 12V4z"/><path fill="#3b82f6" d="M12 4a8 8 0 0 1 7.5 5.3L12 12V4z"/><path fill="#22c55e" d="M4.5 9.3A8 8 0 0 0 12 20V12L4.5 9.3z"/><path fill="#f0c14b" d="M19.5 9.3A8 8 0 0 1 12 20V12l7.5-2.7z"/>`,
  sunRays:
    `<circle cx="12" cy="12" r="3.5" fill="#f5c542"/><g stroke="#f0b429" stroke-width="1.6" stroke-linecap="round"><path d="M12 2.5v2.4M12 19.1v2.4M2.5 12h2.4M19.1 12h2.4M5.1 5.1l1.7 1.7M17.2 17.2l1.7 1.7M18.9 5.1l-1.7 1.7M5.1 18.9l1.7-1.7"/></g>`,
  iceCream:
    `<path fill="#f4a7b9" d="M8 10a4 4 0 0 1 8 0v1H8v-1z"/><path fill="#c47a3a" d="M10 11h4l-1.4 8.2a.8.8 0 0 1-1.6 0L10 11z"/><circle cx="10.5" cy="8.2" r="1.1" fill="#fff" opacity=".5"/>`,
  palm:
    `<path fill="#3d8b4f" d="M12 20V11M12 11c-3-1-6 .5-8 3 3-.2 5.5.2 8-3zm0 0c3-1 6 .5 8 3-3-.2-5.5.2-8-3zm0 0c-1-3 .2-6 2.5-8.5C12.5 8 13 10 12 11zm0 0c1-3-.2-6-2.5-8.5C11.5 8 11 10 12 11z"/>`,
  flipFlop:
    `<path fill="#38bdf8" d="M8 4c2 0 3.5 2 3.5 5.5S11 20 9.5 21.5 6 20.5 6 17.5 6 4 8 4z"/><path fill="#0ea5e9" d="M8.2 7.5c1.2 1.2 1.5 3.2 1.3 5.2"/>`,
  fireworks:
    `<g stroke="#f0c14b" stroke-width="1.4" stroke-linecap="round"><path d="M12 12l-4-6M12 12l4-6M12 12l-6 1M12 12l6 1M12 12l-3 5M12 12l3 5"/></g><circle cx="8" cy="6" r="1.1" fill="#e85d4c"/><circle cx="16" cy="6" r="1.1" fill="#60a5fa"/><circle cx="6" cy="13" r="1" fill="#a78bfa"/>`,
  bbq:
    `<ellipse cx="12" cy="10" rx="8" ry="3" fill="#555"/><path fill="#333" d="M5 10h14v2.5c0 1.5-3 2.5-7 2.5s-7-1-7-2.5V10z"/><path stroke="#f0c14b" stroke-width="1.2" d="M8 7.5c.5-1.5 1-2 1.5-3M12 7c.3-1.2.8-2 1.2-3M15.5 7.5c.4-1.2.9-2 1.3-2.8"/><path stroke="#888" stroke-width="1.3" d="M8 15v4M16 15v4M7 19h10"/>`,
  seagull:
    `<path fill="none" stroke="#cbd5e1" stroke-width="1.6" stroke-linecap="round" d="M4 13c2.5-3 4.5-3.5 6-1 1.5-2.5 3.5-2 6-1"/>`,
  suitcase:
    `<rect x="5" y="8" width="14" height="11" rx="1.5" fill="#64748b"/><path fill="#94a3b8" d="M9 8V6.5A1.5 1.5 0 0 1 10.5 5h3A1.5 1.5 0 0 1 15 6.5V8"/><path stroke="#e2e8f0" stroke-width="1.2" d="M12 10v7"/>`,
  sunflower:
    `<circle cx="12" cy="12" r="3" fill="#5c3d1e"/><g fill="#f0c14b"><circle cx="12" cy="5.5" r="2"/><circle cx="12" cy="18.5" r="2"/><circle cx="5.5" cy="12" r="2"/><circle cx="18.5" cy="12" r="2"/><circle cx="7.3" cy="7.3" r="2"/><circle cx="16.7" cy="7.3" r="2"/><circle cx="7.3" cy="16.7" r="2"/><circle cx="16.7" cy="16.7" r="2"/></g>`,
  trophy:
    `<path fill="#f0c14b" d="M8 4h8v2c0 2.5-1.5 4.5-4 5.2V14h2v1.5H10V14h2v-2.8C9.5 10.5 8 8.5 8 6V4z"/><path fill="#d4a017" d="M8 5H5.5C5.5 8 7 9.5 8 10M16 5h2.5C18.5 8 17 9.5 16 10"/><rect x="9" y="15.5" width="6" height="1.5" fill="#c9a227"/><rect x="8" y="17.5" width="8" height="1.8" rx=".4" fill="#f0c14b"/>`,
  sandcastle:
    `<path fill="#e8c07a" d="M5 18h14l-2-6H7l-2 6z"/><path fill="#d4a85a" d="M9 12V8l3-3 3 3v4"/><rect x="10.5" y="10" width="3" height="2.5" fill="#c4924a"/>`,
  sunset:
    `<circle cx="12" cy="14" r="4" fill="#f97316"/><path fill="#fb923c" opacity=".5" d="M4 16c2-3 5-4 8-4s6 1 8 4v2H4v-2z"/>`,
  leaf:
    `<path fill="#c45c26" d="M12 3c5 3 7 8 5 13-4-1-7-4-8-8 2 1 4 1 3-5z"/><path stroke="#8b3a12" stroke-width="1" fill="none" d="M12 4c0 5-1 9-3 12"/>`,
  leafGreen:
    `<path fill="#4ade80" d="M12 4c5 2 7 7 5 12-4-1-7-4-8-8 2 1 4 1 3-4z"/>`,
  acorn:
    `<path fill="#8b5a2b" d="M9 10h6c0 5-1.5 8-3 8s-3-3-3-8z"/><path fill="#5c3d1e" d="M8.5 8.5c0-1.5 1.5-2.5 3.5-2.5s3.5 1 3.5 2.5H8.5z"/><path stroke="#5c3d1e" stroke-width="1.2" d="M12 6V4"/>`,
  wheat:
    `<g stroke="#d4a017" stroke-width="1.3" stroke-linecap="round" fill="none"><path d="M12 20V6"/><path d="M12 8c-2-.5-3.5-2-3.5-2M12 8c2-.5 3.5-2 3.5-2M12 11c-2-.5-3.5-2-3.5-2M12 11c2-.5 3.5-2 3.5-2M12 14c-2-.5-3-1.8-3-1.8M12 14c2-.5 3-1.8 3-1.8"/></g>`,
  rainCloud:
    `<path fill="#94a3b8" d="M7 11a3.2 3.2 0 0 1 6-.8 2.5 2.5 0 1 1 .6 4.8H7.5A2.5 2.5 0 0 1 7 11z"/><g stroke="#60a5fa" stroke-width="1.4" stroke-linecap="round"><path d="M9 17.5l-.6 2M12 17.5l-.6 2M15 17.5l-.6 2"/></g>`,
  schoolBell:
    `<path fill="#f0c14b" d="M12 4c3.5 0 6 2.8 6 6.5V14l2 2H4l2-2v-3.5C6 6.8 8.5 4 12 4z"/><circle cx="12" cy="19" r="1.5" fill="#f0c14b"/><path fill="#d4a017" d="M11 3h2v2h-2z"/>`,
  pumpkin:
    `<ellipse cx="12" cy="13" rx="7" ry="6" fill="#e67e22"/><path fill="#d35400" d="M12 7c-2 2-3 4-3 6s1 4 3 6c2-2 3-4 3-6s-1-4-3-6z"/><path fill="#27ae60" d="M11 5.5c0-1.5 1-2.5 1-2.5s1.2 1.2 1 2.5c-1 .3-1.5.3-2 0z"/>`,
  bat:
    `<path fill="#9ca3af" d="M12 14c-1-3-4-5-7-5 2 2 3 4 3 6 0 0 2-1 4-1s4 1 4 1c0-2 1-4 3-6-3 0-6 2-7 5z"/>`,
  ghost:
    `<path fill="#e5e7eb" d="M12 4c3.5 0 6 2.8 6 6.5V19l-2-1.5-2 1.5-2-1.5-2 1.5-2-1.5-2 1.5v-8.5C6 6.8 8.5 4 12 4z"/><circle cx="9.5" cy="11" r="1.1" fill="#333"/><circle cx="14.5" cy="11" r="1.1" fill="#333"/>`,
  fog:
    `<g stroke="#94a3b8" stroke-width="1.5" stroke-linecap="round" opacity=".85"><path d="M4 9h12M7 12h13M5 15h11"/></g>`,
  hauntedPosts:
    `<path stroke="#a8a29e" stroke-width="1.6" fill="none" d="M5 18V8h14v10M5 8h14"/><circle cx="12" cy="12" r="1.2" fill="#ef4444" opacity=".7"/>`,
  poppy:
    `<circle cx="12" cy="12" r="2" fill="#3f1a1a"/><g fill="#c0392b"><circle cx="12" cy="7.5" r="3"/><circle cx="12" cy="16.5" r="3"/><circle cx="7.5" cy="12" r="3"/><circle cx="16.5" cy="12" r="3"/></g>`,
  umbrella:
    `<path fill="#6366f1" d="M4 12c0-4.4 3.6-8 8-8s8 3.6 8 8H4z"/><path stroke="#94a3b8" stroke-width="1.5" stroke-linecap="round" d="M12 12v7a1.5 1.5 0 0 0 2.5 1"/>`,
  spark:
    `<g fill="#f97316"><circle cx="12" cy="12" r="1.2"/><circle cx="8" cy="8" r=".8"/><circle cx="16" cy="9" r=".7"/><circle cx="10" cy="16" r=".7"/><circle cx="15" cy="15" r=".6"/></g>`,
  bareTree:
    `<path stroke="#a8a29e" stroke-width="1.5" stroke-linecap="round" fill="none" d="M12 20V10M12 14l-4-4M12 12l4-3M12 10l-3-4M12 9l3-3"/>`,
  snowflake:
    `<g stroke="#e0f2fe" stroke-width="1.4" stroke-linecap="round"><path d="M12 3v18M4.5 7.5l15 9M19.5 7.5l-15 9"/></g><circle cx="12" cy="12" r="1.3" fill="#fff"/>`,
  lights:
    `<path stroke="#64748b" stroke-width="1.2" fill="none" d="M3 8c3 3 5 3 8 0s5-3 8 0"/><g><circle cx="5" cy="9.5" r="1.3" fill="#ef4444"/><circle cx="9" cy="7.8" r="1.3" fill="#22c55e"/><circle cx="13" cy="9.5" r="1.3" fill="#3b82f6"/><circle cx="17" cy="7.8" r="1.3" fill="#f0c14b"/></g>`,
  santaHatBall:
    `<circle cx="12" cy="14" r="5" fill="#eee"/><path fill="#e11d48" d="M8 10c0-4 2.5-6 4-7 2 2 4 4 4 7H8z"/><circle cx="12" cy="3.5" r="1.5" fill="#fff"/><path fill="#fff" d="M7.5 10h9v1.5h-9z"/>`,
  antlers:
    `<g stroke="#a16207" stroke-width="1.6" stroke-linecap="round" fill="none"><path d="M12 18V10M8 6c0 3 2 4 4 4M16 6c0 3-2 4-4 4M7 4v3M17 4v3M6 8h2M16 8h2"/></g>`,
  present:
    `<rect x="6" y="10" width="12" height="9" rx="1" fill="#dc2626"/><path fill="#f0c14b" d="M11.2 10h1.6v9h-1.6zM6 13.2h12v1.6H6z"/><path fill="#ef4444" d="M9 7c1.5 0 2.5 1.5 3 3-1.5 0-3-1-3-3zm6 0c-1.5 0-2.5 1.5-3 3 1.5 0 3-1 3-3z"/>`,
  clock:
    `<circle cx="12" cy="12" r="8" fill="#1e293b" stroke="#f0c14b" stroke-width="1.5"/><path stroke="#f8fafc" stroke-width="1.5" stroke-linecap="round" d="M12 7v5l3.5 2"/>`,
  frostCrystal:
    `<g stroke="#7dd3fc" stroke-width="1.3" stroke-linecap="round"><path d="M12 4v16M6 8l12 8M18 8L6 16"/><path d="M12 7l-2-1M12 7l2-1M12 17l-2 1M12 17l2 1"/></g>`,
  mountain:
    `<path fill="#64748b" d="M3 18L9 7l3 5 3-4 6 10H3z"/><path fill="#e2e8f0" d="M9 7l2.2 3.5L9.8 12 9 7zm6 1l1.5 2.5-.9 1L15 8z"/>`,
  heart:
    `<path fill="#e11d48" d="M12 19S4 13.5 4 9.5C4 7 6 5.5 8 5.5c1.3 0 2.5.7 4 2.2 1.5-1.5 2.7-2.2 4-2.2 2 0 4 1.5 4 4C20 13.5 12 19 12 19z"/>`,
  cupidArrow:
    `<path stroke="#fca5a5" stroke-width="1.5" stroke-linecap="round" d="M4 16L16 4"/><path fill="#e11d48" d="M16 4l4 1-3 3-1-4z"/><path fill="#eee" d="M5 13l-2 4 4-2"/>`,
  rose:
    `<circle cx="12" cy="10" r="4" fill="#e11d48"/><circle cx="10" cy="9" r="2" fill="#be123c"/><path fill="#16a34a" d="M12 14v6M12 16c-2 1-3 2-3 2M12 18c2 1 3 2 3 2"/>`,
  loveLetter:
    `<rect x="4" y="7" width="16" height="11" rx="1" fill="#fef3c7"/><path fill="none" stroke="#d97706" stroke-width="1.3" d="M4 7l8 6 8-6"/>`,
  clover:
    `<g fill="#16a34a"><circle cx="12" cy="7.5" r="3"/><circle cx="7.5" cy="12" r="3"/><circle cx="16.5" cy="12" r="3"/><circle cx="12" cy="16.5" r="3"/></g><circle cx="12" cy="12" r="1.5" fill="#15803d"/>`,
  springFlower:
    `<circle cx="12" cy="12" r="2" fill="#f0c14b"/><g fill="#f9a8d4"><circle cx="12" cy="6.5" r="2.5"/><circle cx="12" cy="17.5" r="2.5"/><circle cx="6.5" cy="12" r="2.5"/><circle cx="17.5" cy="12" r="2.5"/></g>`,
  rainbow:
    `<path fill="none" stroke="#ef4444" stroke-width="1.4" d="M4 16a8 8 0 0 1 16 0"/><path fill="none" stroke="#f0c14b" stroke-width="1.4" d="M5.5 16a6.5 6.5 0 0 1 13 0"/><path fill="none" stroke="#22c55e" stroke-width="1.4" d="M7 16a5 5 0 0 1 10 0"/><path fill="none" stroke="#3b82f6" stroke-width="1.4" d="M8.5 16a3.5 3.5 0 0 1 7 0"/>`,
  kite:
    `<path fill="#38bdf8" d="M12 3l6 9-6 4-6-4 6-9z"/><path stroke="#94a3b8" stroke-width="1.2" fill="none" d="M12 16c-1 2-1 3.5 1 5"/>`,
  daffodil:
    `<circle cx="12" cy="12" r="2.5" fill="#f59e0b"/><g fill="#fde047"><circle cx="12" cy="6" r="2.2"/><circle cx="12" cy="18" r="2.2"/><circle cx="6" cy="12" r="2.2"/><circle cx="18" cy="12" r="2.2"/><circle cx="7.8" cy="7.8" r="2"/><circle cx="16.2" cy="7.8" r="2"/><circle cx="7.8" cy="16.2" r="2"/><circle cx="16.2" cy="16.2" r="2"/></g>`,
  easterEgg:
    `<ellipse cx="12" cy="13" rx="5" ry="7" fill="#f9a8d4"/><path fill="none" stroke="#fff" stroke-width="1.3" d="M7.5 11h9M8 14.5h8"/><circle cx="10" cy="9" r="1" fill="#fff"/><circle cx="14" cy="16" r="1" fill="#fff"/>`,
  rabbit:
    `<ellipse cx="12" cy="15" rx="5" ry="4.5" fill="#e7e5e4"/><ellipse cx="9" cy="7" rx="1.6" ry="4" fill="#e7e5e4"/><ellipse cx="15" cy="7" rx="1.6" ry="4" fill="#e7e5e4"/><circle cx="10" cy="14.5" r=".8" fill="#333"/><circle cx="14" cy="14.5" r=".8" fill="#333"/>`,
  blossom:
    `<g fill="#fda4af"><circle cx="12" cy="8" r="2.5"/><circle cx="8.5" cy="12" r="2.5"/><circle cx="15.5" cy="12" r="2.5"/><circle cx="10" cy="15.5" r="2.5"/><circle cx="14" cy="15.5" r="2.5"/></g><circle cx="12" cy="12" r="1.8" fill="#fef3c7"/>`,
  confetti:
    `<g><rect x="5" y="5" width="2" height="4" rx=".5" fill="#ef4444" transform="rotate(20 6 7)"/><rect x="16" y="6" width="2" height="4" rx=".5" fill="#3b82f6" transform="rotate(-25 17 8)"/><rect x="10" y="4" width="2" height="3.5" rx=".5" fill="#f0c14b" transform="rotate(10 11 6)"/><circle cx="8" cy="14" r="1.2" fill="#22c55e"/><circle cx="15" cy="15" r="1.2" fill="#e11d48"/><circle cx="12" cy="17" r="1" fill="#a78bfa"/></g>`,
  ribbons:
    `<path fill="#f0c14b" d="M6 8c3 2 5 2 6 0 1 2 3 2 6 0v3c-3 2-5 2-6 0-1 2-3 2-6 0V8z"/><path fill="#e11d48" d="M11 11h2v9h-2z"/>`,
  goldenBall:
    `<circle cx="12" cy="12" r="7" fill="#f0c14b"/><path fill="none" stroke="#d4a017" stroke-width="1.2" d="M12 5v14M5 12h14M7.5 7.5c2 2 7 2 9 0M7.5 16.5c2-2 7-2 9 0"/>`,
  football:
    `<circle cx="12" cy="12" r="7.5" fill="#f8fafc"/><path fill="#1e293b" d="M12 8.2l2.2 1.6-.8 2.6h-2.8l-.8-2.6L12 8.2z"/><path fill="none" stroke="#1e293b" stroke-width="1.1" d="M12 8.2L9.2 5.5M12 8.2l2.8-2.7M14.2 9.8l4-.6M9.8 9.8l-4-.6M13.4 12.4l2.8 3.1M10.6 12.4l-2.8 3.1"/>`,
};

/** Positions across the header mid-gap (avoid far left/right text). */
const SLOTS = [
  { x: "22%", y: "55%", size: 20 },
  { x: "34%", y: "38%", size: 18 },
  { x: "46%", y: "62%", size: 22 },
  { x: "58%", y: "36%", size: 19 },
  { x: "70%", y: "58%", size: 20 },
  { x: "80%", y: "42%", size: 17 },
];

const MONTH_MOTIFS = {
  june: ["sunglasses", "beachBall", "sunRays", "iceCream", "palm", "flipFlop"],
  july: ["fireworks", "bbq", "sunRays", "beachBall", "seagull", "suitcase"],
  august: ["sunflower", "trophy", "sunRays", "football", "sandcastle", "sunset"],
  september: ["leaf", "schoolBell", "leafGreen", "acorn", "wheat", "rainCloud"],
  october: ["pumpkin", "bat", "ghost", "leaf", "fog", "hauntedPosts"],
  november: ["poppy", "leaf", "rainCloud", "umbrella", "spark", "bareTree"],
  december: ["snowflake", "lights", "santaHatBall", "antlers", "frostCrystal", "present"],
  january: ["fireworks", "clock", "football", "frostCrystal", "mountain", "snowflake"],
  february: ["heart", "cupidArrow", "rose", "loveLetter", "heart", "snowflake"],
  march: ["clover", "springFlower", "leafGreen", "rainbow", "kite", "daffodil"],
  april: ["easterEgg", "rabbit", "blossom", "rainCloud", "umbrella", "leafGreen"],
  may: ["trophy", "confetti", "ribbons", "goldenBall", "springFlower", "confetti"],
};

/**
 * @param {string|null|undefined} gpslMonth
 * @returns {string} HTML for absolute decoration layer (or "")
 */
export function matchdaySeasonDecorHtml(gpslMonth) {
  const key = String(gpslMonth || "")
    .trim()
    .toLowerCase();
  const motifs = MONTH_MOTIFS[key];
  if (!motifs?.length) return "";

  const icons = motifs
    .map((name, i) => {
      const svg = M[name];
      if (!svg) return "";
      const slot = SLOTS[i % SLOTS.length];
      const rotate = ((i * 17) % 50) - 25;
      const opacity = 0.55 + (i % 3) * 0.08;
      return icon(svg, { ...slot, rotate, opacity, size: slot.size });
    })
    .join("");

  return `<div class="matchday-season-decor" data-season="${key}" aria-hidden="true">${icons}</div>`;
}
