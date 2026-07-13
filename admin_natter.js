import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;

  document.getElementById("natterAdminRefresh")?.addEventListener("click", () => void loadPosts());
  document.getElementById("natterAdminMonth")?.addEventListener("change", () => void loadPosts());
  document.getElementById("natterAdminList")?.addEventListener("click", (e) => {
    const btn = e.target.closest?.("[data-delete-post]");
    if (!btn) return;
    void deletePost(Number(btn.getAttribute("data-delete-post")), btn);
  });

  await loadPosts();
});

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso) {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleString("en-GB", {
      day: "numeric",
      month: "short",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return String(iso);
  }
}

async function loadPosts() {
  const list = document.getElementById("natterAdminList");
  const month = document.getElementById("natterAdminMonth")?.value || null;
  setStatus("natterAdminStatus", "Loading…");
  if (list) list.innerHTML = "";

  const { data, error } = await supabase.rpc("natter_admin_list_posts", {
    p_season_id: null,
    p_gpsl_month: month || null,
    p_limit: 300,
  });

  if (error) {
    setStatus("natterAdminStatus", "❌ " + error.message, false);
    return;
  }
  if (!data?.ok) {
    setStatus(
      "natterAdminStatus",
      `❌ ${data?.reason === "admin_only" ? "Admin only." : data?.reason || "Failed."}`,
      false
    );
    return;
  }

  const posts = Array.isArray(data.posts) ? data.posts : [];
  setStatus(
    "natterAdminStatus",
    posts.length ? `${posts.length} post(s)` : "No posts for this filter.",
    true
  );

  if (!list) return;
  if (!posts.length) {
    list.innerHTML = `<p class="note">Nothing to show.</p>`;
    return;
  }

  list.innerHTML = posts
    .map((p) => {
      const preview = String(p.body || "").slice(0, 180);
      const more = String(p.body || "").length > 180 ? "…" : "";
      return `
        <article class="admin-natter-card">
          <div class="admin-natter-card-head">
            <strong>${escapeHtml(p.club_name || p.club_short || "Club")}</strong>
            <span>${escapeHtml([p.owner_tag, p.month_label || p.gpsl_month, formatWhen(p.created_at)].filter(Boolean).join(" · "))}</span>
          </div>
          <p class="admin-natter-body">${escapeHtml(preview)}${escapeHtml(more)}</p>
          <div class="admin-natter-actions">
            ${p.image_path ? `<span class="note">Has image</span>` : ""}
            <button type="button" class="button button-danger" data-delete-post="${Number(p.id)}">Delete</button>
          </div>
        </article>`;
    })
    .join("");
}

async function deletePost(postId, btn) {
  if (!postId) return;
  if (!confirm(`Delete Natter post #${postId}? This cannot be undone.`)) return;

  if (btn) btn.disabled = true;
  setStatus("natterAdminStatus", `Deleting #${postId}…`);

  const { data, error } = await supabase.rpc("natter_admin_delete_post", {
    p_post_id: postId,
  });

  if (error) {
    setStatus("natterAdminStatus", "❌ " + error.message, false);
    if (btn) btn.disabled = false;
    return;
  }
  if (!data?.ok) {
    setStatus("natterAdminStatus", `❌ ${data?.reason || "Delete failed."}`, false);
    if (btn) btn.disabled = false;
    return;
  }

  setStatus(
    "natterAdminStatus",
    `✅ Deleted post #${postId} (${data.club_short_name || "club"} / ${data.gpsl_month || "month"}).`,
    true
  );
  await loadPosts();
}
