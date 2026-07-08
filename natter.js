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

/** Active crop session (source image before crop/compress). */
let cropSession = null;
let cropDrag = null;

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

function parseAspect(value) {
  if (!value || value === "free") return null;
  const [a, b] = String(value).split(":").map(Number);
  if (!a || !b) return null;
  return a / b;
}

function loadImageElement(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => resolve({ img, url });
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Could not read that image."));
    };
    img.src = url;
  });
}

function canvasToBlob(canvas, type, quality) {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("Could not encode image."))),
      type,
      quality
    );
  });
}

/** Crop + downscale, then step quality/size until under MAX_IMAGE_BYTES. */
async function encodeCroppedImage(sourceImg, cropPx) {
  const cropW = Math.max(1, Math.round(cropPx.w));
  const cropH = Math.max(1, Math.round(cropPx.h));
  let outW = cropW;
  let outH = cropH;
  const longest = Math.max(outW, outH);
  if (longest > MAX_IMAGE_EDGE) {
    const scale = MAX_IMAGE_EDGE / longest;
    outW = Math.max(1, Math.round(outW * scale));
    outH = Math.max(1, Math.round(outH * scale));
  }

  let work = document.createElement("canvas");
  work.width = outW;
  work.height = outH;
  const ctx = work.getContext("2d");
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(
    sourceImg,
    cropPx.x,
    cropPx.y,
    cropW,
    cropH,
    0,
    0,
    outW,
    outH
  );

  // JPEG compress with quality steps, then downscale further if still too big
  let quality = 0.88;
  let blob = await canvasToBlob(work, "image/jpeg", quality);

  for (let i = 0; i < 8 && blob.size > MAX_IMAGE_BYTES; i++) {
    if (quality > 0.5) {
      quality = Math.max(0.48, quality - 0.1);
      blob = await canvasToBlob(work, "image/jpeg", quality);
      continue;
    }
    const nextW = Math.max(1, Math.round(work.width * 0.85));
    const nextH = Math.max(1, Math.round(work.height * 0.85));
    if (nextW === work.width && nextH === work.height) break;
    const smaller = document.createElement("canvas");
    smaller.width = nextW;
    smaller.height = nextH;
    const sctx = smaller.getContext("2d");
    sctx.imageSmoothingEnabled = true;
    sctx.imageSmoothingQuality = "high";
    sctx.drawImage(work, 0, 0, nextW, nextH);
    work = smaller;
    quality = Math.max(0.42, quality - 0.05);
    blob = await canvasToBlob(work, "image/jpeg", quality);
  }

  if (blob.size > MAX_IMAGE_BYTES) {
    throw new Error("Could not compress under 3 MB — try a smaller crop.");
  }

  return new File([blob], "natter.jpg", { type: "image/jpeg" });
}

function formatBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function closeCropModal(revokeSource = true) {
  const modal = document.getElementById("natterCropModal");
  if (modal) modal.hidden = true;
  if (cropSession) {
    if (revokeSource && cropSession.url) URL.revokeObjectURL(cropSession.url);
    cropSession = null;
  }
  cropDrag = null;
  const fileInput = document.getElementById("natterImage");
  if (fileInput) fileInput.value = "";
}

function applyCropLayout() {
  if (!cropSession) return;
  const viewport = document.getElementById("natterCropViewport");
  const source = document.getElementById("natterCropSource");
  const frame = document.getElementById("natterCropFrame");
  const zoomEl = document.getElementById("natterCropZoom");
  if (!viewport || !source || !frame) return;

  const vw = viewport.clientWidth;
  const vh = viewport.clientHeight;
  if (!vw || !vh) return;

  const { naturalW, naturalH } = cropSession;
  const aspect = cropSession.aspect; // null = free uses natural image aspect for frame
  const frameAspect = aspect || naturalW / naturalH;

  // Frame fills viewport with padding, keeping aspect
  const pad = 24;
  let fw = vw - pad * 2;
  let fh = fw / frameAspect;
  if (fh > vh - pad * 2) {
    fh = vh - pad * 2;
    fw = fh * frameAspect;
  }
  const fx = (vw - fw) / 2;
  const fy = (vh - fh) / 2;
  frame.style.left = `${fx}px`;
  frame.style.top = `${fy}px`;
  frame.style.width = `${fw}px`;
  frame.style.height = `${fh}px`;

  const zoom = Number(zoomEl?.value) || 1;
  // Cover the frame at zoom 1
  const cover = Math.max(fw / naturalW, fh / naturalH) * zoom;
  const dispW = naturalW * cover;
  const dispH = naturalH * cover;

  const minOx = fx + fw - dispW;
  const minOy = fy + fh - dispH;
  const maxOx = fx;
  const maxOy = fy;

  if (cropSession.needsCenter) {
    cropSession.offsetX = fx + (fw - dispW) / 2;
    cropSession.offsetY = fy + (fh - dispH) / 2;
    cropSession.needsCenter = false;
  } else {
    cropSession.offsetX = Math.min(maxOx, Math.max(minOx, cropSession.offsetX));
    cropSession.offsetY = Math.min(maxOy, Math.max(minOy, cropSession.offsetY));
  }

  source.style.width = `${dispW}px`;
  source.style.height = `${dispH}px`;
  source.style.left = `${cropSession.offsetX}px`;
  source.style.top = `${cropSession.offsetY}px`;

  cropSession.frame = { x: fx, y: fy, w: fw, h: fh };
  cropSession.display = { w: dispW, h: dispH, cover };
  updateCropSizeHint();
}

function updateCropSizeHint() {
  const hint = document.getElementById("natterCropSizeHint");
  if (!hint || !cropSession?.frame || !cropSession.display) return;
  const { frame, display, naturalW, naturalH, offsetX, offsetY } = cropSession;
  const scale = naturalW / display.w;
  const cropW = Math.round(frame.w * scale);
  const cropH = Math.round(frame.h * scale);
  const outLong = Math.max(cropW, cropH);
  const outScale = outLong > MAX_IMAGE_EDGE ? MAX_IMAGE_EDGE / outLong : 1;
  const outW = Math.round(cropW * outScale);
  const outH = Math.round(cropH * outScale);
  void offsetX;
  void offsetY;
  void naturalH;
  hint.textContent = `Export ~${outW}×${outH} · under ${formatBytes(MAX_IMAGE_BYTES)}`;
}

function getCropRectInNaturalPixels() {
  const { frame, display, naturalW, naturalH, offsetX, offsetY } = cropSession;
  const scale = naturalW / display.w;
  let x = (frame.x - offsetX) * scale;
  let y = (frame.y - offsetY) * scale;
  let w = frame.w * scale;
  let h = frame.h * scale;
  x = Math.max(0, Math.min(naturalW - 1, x));
  y = Math.max(0, Math.min(naturalH - 1, y));
  w = Math.max(1, Math.min(naturalW - x, w));
  h = Math.max(1, Math.min(naturalH - y, h));
  return { x, y, w, h };
}

async function openCropModal(file) {
  if (!file || !ALLOWED_TYPES.has(file.type)) {
    throw new Error("Use JPEG, PNG, or WebP.");
  }
  if (file.size > 25 * 1024 * 1024) {
    throw new Error("Image file is too large to load (max 25 MB source).");
  }

  const { img, url } = await loadImageElement(file);
  cropSession = {
    file,
    img,
    url,
    naturalW: img.naturalWidth,
    naturalH: img.naturalHeight,
    offsetX: 0,
    offsetY: 0,
    needsCenter: true,
    aspect: parseAspect(document.getElementById("natterCropAspect")?.value),
    frame: null,
    display: null,
  };

  const source = document.getElementById("natterCropSource");
  const modal = document.getElementById("natterCropModal");
  const zoomEl = document.getElementById("natterCropZoom");
  if (source) source.src = url;
  if (zoomEl) zoomEl.value = "1";
  if (modal) modal.hidden = false;

  requestAnimationFrame(() => {
    applyCropLayout();
  });
}

async function applyCropAndSelect() {
  if (!cropSession) return;
  const applyBtn = document.getElementById("natterCropApply");
  if (applyBtn) {
    applyBtn.disabled = true;
    applyBtn.textContent = "Compressing…";
  }
  try {
    const cropPx = getCropRectInNaturalPixels();
    const file = await encodeCroppedImage(cropSession.img, cropPx);
    // Keep source URL until we set preview, then close without revoking late
    const keepUrl = cropSession.url;
    cropSession.url = null;
    closeCropModal(false);
    URL.revokeObjectURL(keepUrl);

    clearSelectedImage();
    selectedFile = file;
    selectedObjectUrl = URL.createObjectURL(file);
    const preview = document.getElementById("natterImagePreview");
    const wrap = document.getElementById("natterImagePreviewWrap");
    const nameEl = document.getElementById("natterImageName");
    if (preview) preview.src = selectedObjectUrl;
    if (wrap) wrap.hidden = false;
    if (nameEl) {
      nameEl.textContent = `Cropped · ${formatBytes(file.size)}`;
    }
    setComposeHint("Image cropped and compressed — ready to post.");
  } catch (err) {
    setComposeHint(err?.message || "Could not process image.", true);
  } finally {
    if (applyBtn) {
      applyBtn.disabled = false;
      applyBtn.textContent = "Use image";
    }
  }
}

async function onImagePicked(file) {
  if (!file) return;
  try {
    setComposeHint("Opening crop tools…");
    await openCropModal(file);
    setComposeHint("");
  } catch (err) {
    setComposeHint(err?.message || "Could not use that image.", true);
    const input = document.getElementById("natterImage");
    if (input) input.value = "";
  }
}

function setComposeAvatar(clubShort, clubName) {
  const badge = document.getElementById("composeBadge");
  const fallback = document.getElementById("composeFallback");
  const badgeSrc = clubBadgeUrl(clubShort);

  if (badge && badgeSrc) {
    badge.alt = clubName || "";
    badge.hidden = false;
    if (fallback) fallback.hidden = true;
    badge.onerror = () => {
      badge.hidden = true;
      if (fallback) {
        fallback.hidden = false;
        fallback.textContent = (clubName || "?").slice(0, 1).toUpperCase();
      }
    };
    badge.src = badgeSrc;
  } else {
    if (badge) badge.hidden = true;
    if (fallback) {
      fallback.hidden = false;
      fallback.textContent = (clubName || "?").slice(0, 1).toUpperCase();
    }
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

  setComposeAvatar(clubShort, clubName);

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
        ? `<img class="natter-avatar" src="${escapeHtml(badge)}" alt="" loading="lazy" onerror="this.style.display='none';this.nextElementSibling&&(this.nextElementSibling.hidden=false)">`
        : "";
      const fallbackLetter = escapeHtml(String(club).slice(0, 1).toUpperCase());
      const fallback = `<div class="natter-avatar-fallback"${badge ? " hidden" : ""}>${fallbackLetter}</div>`;
      const imgUrl = publicImageUrl(p.image_path);
      const img = imgUrl
        ? `<img class="natter-card-image" src="${escapeHtml(imgUrl)}" alt="" loading="lazy">`
        : "";
      const meta = [p.owner_tag, p.month_label, formatWhen(p.created_at)]
        .filter(Boolean)
        .join(" · ");
      return `
        <article class="natter-card">
          <div class="natter-avatar-slot">
            ${avatar}
            ${fallback}
          </div>
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

function wireCropUi() {
  const viewport = document.getElementById("natterCropViewport");
  const zoomEl = document.getElementById("natterCropZoom");
  const aspectEl = document.getElementById("natterCropAspect");
  const cancelBtn = document.getElementById("natterCropCancel");
  const applyBtn = document.getElementById("natterCropApply");

  zoomEl?.addEventListener("input", () => {
    if (!cropSession) return;
    applyCropLayout();
  });

  aspectEl?.addEventListener("change", () => {
    if (!cropSession) return;
    cropSession.aspect = parseAspect(aspectEl.value);
    cropSession.needsCenter = true;
    applyCropLayout();
  });

  cancelBtn?.addEventListener("click", () => closeCropModal(true));
  applyBtn?.addEventListener("click", () => void applyCropAndSelect());

  const onPointerDown = (e) => {
    if (!cropSession || e.button != null && e.button !== 0) return;
    e.preventDefault();
    cropDrag = {
      startX: e.clientX,
      startY: e.clientY,
      origX: cropSession.offsetX,
      origY: cropSession.offsetY,
    };
    viewport?.setPointerCapture?.(e.pointerId);
  };

  const onPointerMove = (e) => {
    if (!cropDrag || !cropSession) return;
    cropSession.offsetX = cropDrag.origX + (e.clientX - cropDrag.startX);
    cropSession.offsetY = cropDrag.origY + (e.clientY - cropDrag.startY);
    applyCropLayout();
  };

  const onPointerUp = () => {
    cropDrag = null;
  };

  viewport?.addEventListener("pointerdown", onPointerDown);
  viewport?.addEventListener("pointermove", onPointerMove);
  viewport?.addEventListener("pointerup", onPointerUp);
  viewport?.addEventListener("pointercancel", onPointerUp);

  window.addEventListener("resize", () => {
    if (cropSession && !document.getElementById("natterCropModal")?.hidden) {
      applyCropLayout();
    }
  });
}

function wireCompose() {
  const input = document.getElementById("natterBody");
  const file = document.getElementById("natterImage");
  const clearBtn = document.getElementById("natterClearImage");
  const recropBtn = document.getElementById("natterRecropImage");
  const postBtn = document.getElementById("natterPostBtn");

  input?.addEventListener("input", updateCharCount);
  file?.addEventListener("change", () => {
    void onImagePicked(file.files?.[0] || null);
  });
  clearBtn?.addEventListener("click", () => clearSelectedImage());
  recropBtn?.addEventListener("click", () => {
    document.getElementById("natterImage")?.click();
  });
  postBtn?.addEventListener("click", () => void submitPost());
  wireCropUi();
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
