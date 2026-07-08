import { supabase, initGlobal, getAuthUserFast } from "./global.js";

const MAX_CHARS = 1000;
const MAX_IMAGE_BYTES = 3 * 1024 * 1024;
const MAX_IMAGE_EDGE = 1600;
const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

let composeState = null;
let selectedFile = null;
let selectedObjectUrl = null;
let viewSeasonId = null;
let viewMonth = null;

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function clubBadgeUrl(short) {
  const code = String(short || "").trim();
  return code ? `images/club_badges/${code}.png` : null;
}

function publicImageUrl(path) {
  if (!path) return null;
  const { data } = supabase.storage.from("natter-media").getPublicUrl(path);
  return data?.publicUrl || null;
}

function formatWhen(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("en-GB", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function showPageError(msg) {
  const el = document.getElementById("natterError");
  if (!el) return;
  if (!msg) {
    el.hidden = true;
    el.textContent = "";
    return;
  }
  el.hidden = false;
  el.textContent = msg;
}

function setComposeHint(msg, isError = false) {
  const el = document.getElementById("natterComposeHint");
  if (!el) return;
  el.textContent = msg || "";
  el.classList.toggle("is-error", Boolean(isError && msg));
}

function updateCharCount() {
  const input = document.getElementById("natterBody");
  const countEl = document.getElementById("natterCharCount");
  if (!input || !countEl) return;
  const n = String(input.value || "").length;
  countEl.textContent = `${n} / ${MAX_CHARS}`;
  countEl.classList.toggle("is-warn", n >= MAX_CHARS - 80 && n <= MAX_CHARS);
  countEl.classList.toggle("is-over", n > MAX_CHARS);
  syncPostButton();
}

function syncPostButton() {
  const btn = document.getElementById("natterPostBtn");
  const input = document.getElementById("natterBody");
  if (!btn || !input) return;
  const body = String(input.value || "").trim();
  const ok =
    Boolean(composeState?.can_compose) &&
    body.length >= 1 &&
    body.length <= MAX_CHARS;
  btn.disabled = !ok;
}

function clearSelectedImage() {
  selectedFile = null;
  const input = document.getElementById("natterImage");
  if (input) input.value = "";
  const nameEl = document.getElementById("natterImageName");
  if (nameEl) nameEl.textContent = "";
  const wrap = document.getElementById("natterImagePreviewWrap");
  if (wrap) wrap.hidden = true;
  if (selectedObjectUrl) {
    URL.revokeObjectURL(selectedObjectUrl);
    selectedObjectUrl = null;
  }
}

async function resizeImageFile(file) {
  if (!file || !ALLOWED_TYPES.has(file.type)) {
    throw new Error("Use JPEG, PNG, or WebP.");
  }
  if (file.size > MAX_IMAGE_BYTES * 2) {
    throw new Error("Image is too large (max ~3 MB after resize).");
  }

  const bitmap = await createImageBitmap(file);
  const longest = Math.max(bitmap.width, bitmap.height);
  const scale = longest > MAX_IMAGE_EDGE ? MAX_IMAGE_EDGE / longest : 1;
  const w = Math.max(1, Math.round(bitmap.width * scale));
  const h = Math.max(1, Math.round(bitmap.height * scale));

  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0, w, h);
  bitmap.close?.();

  const mime = file.type === "image/png" ? "image/png" : "image/jpeg";
  const quality = mime === "image/jpeg" ? 0.85 : undefined;
  const blob = await new Promise((resolve, reject) => {
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("Could not process image."))),
      mime,
      quality
    );
  });

  if (blob.size > MAX_IMAGE_BYTES) {
    throw new Error("Image still over 3 MB after resize — try a smaller file.");
  }

  const ext = mime === "image/png" ? "png" : "jpg";
  return new File([blob], `natter.${ext}`, { type: mime });
}

async function onImagePicked(file) {
  clearSelectedImage();
  if (!file) return;
  try {
    selectedFile = await resizeImageFile(file);
    selectedObjectUrl = URL.createObjectURL(selectedFile);
    const preview = document.getElementById("natterImagePreview");
    const wrap = document.getElementById("natterImagePreviewWrap");
    const nameEl = document.getElementById("natterImageName");
    if (preview) preview.src = selectedObjectUrl;
    if (wrap) wrap.hidden = false;
    if (nameEl) {
      const kb = Math.round(selectedFile.size / 1024);
      nameEl.textContent = `${selectedFile.name} · ${kb} KB`;
    }
    setComposeHint("");
  } catch (err) {
    setComposeHint(err?.message || "Could not use that image.", true);
  }
}

function renderComposeUi(state) {
  composeState = state;
  const compose = document.getElementById("natterCompose");
  const banner = document.getElementById("natterAlreadyPosted");
  const ctxEl = document.getElementById("natterContext");
  const ctx = state?.context || {};

  if (ctxEl) {
    const parts = [
      ctx.season_label || "",
      ctx.month_label ? `${ctx.month_label} GPSL` : "",
    ].filter(Boolean);
    ctxEl.textContent = parts.join(" · ") || "—";
  }

  const clubName = state?.club_name || state?.club_short_name || "Your club";
  const clubShort = state?.club_short_name || "";
  const composeClub = document.getElementById("composeClub");
  const composeMeta = document.getElementById("composeMeta");
  if (composeClub) composeClub.textContent = clubName;
  if (composeMeta) {
    composeMeta.textContent = state?.can_compose
      ? `One post for ${ctx.month_label || "this"} GPSL month`
      : state?.already_posted
        ? `Posted for ${ctx.month_label || "this"} GPSL month`
        : "Compose window closed";
  }

  const badge = document.getElementById("composeBadge");
  const fallback = document.getElementById("composeFallback");
  const badgeSrc = clubBadgeUrl(clubShort);
  if (badge && badgeSrc) {
    badge.src = badgeSrc;
    badge.alt = clubName;
    badge.hidden = false;
    if (fallback) fallback.hidden = true;
  } else if (fallback) {
    fallback.hidden = false;
    fallback.textContent = (clubName || "?").slice(0, 1).toUpperCase();
    if (badge) badge.hidden = true;
  }

  if (compose) compose.hidden = !state?.can_compose;
  if (banner) banner.hidden = !state?.already_posted;

  if (state?.can_compose) {
    updateCharCount();
  }
}

function renderMonthTabs(months, activeMonth) {
  const nav = document.getElementById("natterMonthTabs");
  if (!nav) return;
  const tabs = Array.isArray(months) ? months : [];
  if (!tabs.length) {
    nav.innerHTML = "";
    return;
  }

  nav.innerHTML = tabs
    .map((m) => {
      const key = m.gpsl_month;
      const active = key === activeMonth ? " is-active" : "";
      const count = Number(m.post_count) || 0;
      return `<button type="button" class="natter-month-tab${active}" data-month="${escapeHtml(key)}">${escapeHtml(m.month_label || key)} · ${count}</button>`;
    })
    .join("");

  nav.querySelectorAll("[data-month]").forEach((btn) => {
    btn.addEventListener("click", () => {
      viewMonth = btn.getAttribute("data-month");
      void loadFeed();
    });
  });
}

function renderFeed(posts) {
  const feed = document.getElementById("natterFeed");
  if (!feed) return;
  const rows = Array.isArray(posts) ? posts : [];
  if (!rows.length) {
    feed.innerHTML = `<p class="natter-empty">No Natters for this month yet.</p>`;
    return;
  }

  feed.innerHTML = rows
    .map((p) => {
      const club = p.club_name || p.club_short || "Club";
      const badge = clubBadgeUrl(p.club_short);
      const avatar = badge
        ? `<img class="natter-avatar" src="${escapeHtml(badge)}" alt="" loading="lazy">`
        : `<div class="natter-avatar-fallback">${escapeHtml(String(club).slice(0, 1).toUpperCase())}</div>`;
      const imgUrl = publicImageUrl(p.image_path);
      const img = imgUrl
        ? `<img class="natter-card-image" src="${escapeHtml(imgUrl)}" alt="" loading="lazy">`
        : "";
      const meta = [p.owner_tag, p.month_label, formatWhen(p.created_at)]
        .filter(Boolean)
        .join(" · ");
      return `
        <article class="natter-card">
          ${avatar}
          <div>
            <div class="natter-card-head">
              <span class="natter-card-club">${escapeHtml(club)}</span>
              <span class="natter-card-meta">${escapeHtml(meta)}</span>
            </div>
            <div class="natter-card-body">${escapeHtml(p.body)}</div>
            ${img}
          </div>
        </article>`;
    })
    .join("");
}

async function loadComposeState() {
  const { data, error } = await supabase.rpc("natter_get_compose_state");
  if (error) {
    const msg = String(error.message || "");
    if (msg.includes("natter_get_compose_state") || msg.includes("function")) {
      showPageError("Run supabase/sql/patches/natter_platform.sql in Supabase.");
    } else {
      showPageError(msg || "Could not load Natter compose state.");
    }
    return null;
  }
  if (!data?.ok) {
    showPageError("Could not load Natter.");
    return null;
  }
  showPageError("");
  renderComposeUi(data);
  viewSeasonId = data.context?.season_id ?? null;
  if (!viewMonth && data.context?.gpsl_month) {
    viewMonth = data.context.gpsl_month;
  }
  return data;
}

async function loadMonths() {
  const { data, error } = await supabase.rpc("natter_list_months", {
    p_season_id: viewSeasonId || null,
  });
  if (error || !data?.ok) return [];
  let months = Array.isArray(data.months) ? data.months : [];

  const ctxMonth = composeState?.context?.gpsl_month;
  const ctxLabel = composeState?.context?.month_label;
  if (ctxMonth && !months.some((m) => m.gpsl_month === ctxMonth)) {
    months = [
      {
        gpsl_month: ctxMonth,
        month_label: ctxLabel || ctxMonth,
        post_count: 0,
      },
      ...months,
    ];
  }

  if (!viewMonth && months[0]?.gpsl_month) {
    viewMonth = months[0].gpsl_month;
  } else if (!viewMonth && ctxMonth) {
    viewMonth = ctxMonth;
  }
  renderMonthTabs(months, viewMonth);
  return months;
}

async function loadFeed() {
  const feed = document.getElementById("natterFeed");
  if (feed) feed.innerHTML = `<p class="natter-empty">Loading Natter…</p>`;

  const { data, error } = await supabase.rpc("natter_list_posts", {
    p_season_id: viewSeasonId || null,
    p_gpsl_month: viewMonth || null,
    p_limit: 100,
  });

  if (error) {
    if (feed) {
      feed.innerHTML = `<p class="natter-empty">Could not load posts.</p>`;
    }
    return;
  }

  // Refresh tab active state
  document.querySelectorAll("#natterMonthTabs [data-month]").forEach((btn) => {
    btn.classList.toggle("is-active", btn.getAttribute("data-month") === viewMonth);
  });

  renderFeed(data?.posts || []);
}

async function uploadImage(clubShort) {
  if (!selectedFile || !clubShort) return null;
  const ext = selectedFile.type === "image/png" ? "png" : "jpg";
  const path = `${clubShort}/${Date.now()}.${ext}`;
  const { error } = await supabase.storage
    .from("natter-media")
    .upload(path, selectedFile, {
      cacheControl: "3600",
      upsert: false,
      contentType: selectedFile.type,
    });
  if (error) {
    throw new Error(error.message || "Image upload failed.");
  }
  return path;
}

async function submitPost() {
  const input = document.getElementById("natterBody");
  const btn = document.getElementById("natterPostBtn");
  if (!input || !composeState?.can_compose) return;

  const body = String(input.value || "").trim();
  if (!body) {
    setComposeHint("Write something before posting.", true);
    return;
  }
  if (body.length > MAX_CHARS) {
    setComposeHint(`Too long — max ${MAX_CHARS} characters.`, true);
    return;
  }

  if (btn) btn.disabled = true;
  setComposeHint("Posting…");

  try {
    let imagePath = null;
    if (selectedFile) {
      imagePath = await uploadImage(composeState.club_short_name);
    }

    const { data, error } = await supabase.rpc("natter_create_post", {
      p_body: body,
      p_image_path: imagePath,
    });

    if (error) {
      throw new Error(error.message || "Post failed.");
    }
    if (!data?.ok) {
      const reasons = {
        already_posted: "You’ve already posted this GPSL month.",
        window_closed: "Compose window is closed.",
        empty: "Write something before posting.",
        too_long: `Too long — max ${MAX_CHARS} characters.`,
        invalid_image_path: "Image path was rejected.",
        no_club: "No club found for your account.",
      };
      throw new Error(reasons[data?.reason] || "Could not post.");
    }

    input.value = "";
    clearSelectedImage();
    setComposeHint("Posted — appears in next month’s GPSL Sport Club news.");
    await loadComposeState();
    await loadMonths();
    await loadFeed();
  } catch (err) {
    setComposeHint(err?.message || "Could not post.", true);
    syncPostButton();
  }
}

function wireCompose() {
  const input = document.getElementById("natterBody");
  const file = document.getElementById("natterImage");
  const clearBtn = document.getElementById("natterClearImage");
  const postBtn = document.getElementById("natterPostBtn");

  input?.addEventListener("input", updateCharCount);
  file?.addEventListener("change", () => {
    void onImagePicked(file.files?.[0] || null);
  });
  clearBtn?.addEventListener("click", () => clearSelectedImage());
  postBtn?.addEventListener("click", () => void submitPost());
}

async function boot() {
  await initGlobal();
  const user = await getAuthUserFast();
  if (!user) {
    showPageError("Sign in to use Natter.");
    return;
  }

  wireCompose();
  const state = await loadComposeState();
  if (!state) return;
  await loadMonths();
  await loadFeed();
}

boot().catch((err) => {
  console.error(err);
  showPageError(err?.message || "Natter failed to load.");
});
