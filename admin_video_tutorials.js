import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";
import {
  clearVideoTutorialMenuCache,
  loadVideoTutorials,
  slugify,
  sortVt,
  youtubeId,
} from "./video_tutorials_data.js?v=20261005-vt-admin";

primeAdminPageChrome();

let folders = [];
let links = [];
let selectedId = null;

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const childrenOf = (id) => sortVt(folders.filter((f) => (f.parent_id ?? null) === id));
const linksOf = (id) => sortVt(links.filter((l) => l.folder_id === id));
const folderById = (id) => folders.find((f) => f.id === id);

function descendantIds(id) {
  const out = new Set();
  const walk = (pid) => {
    for (const c of folders.filter((f) => f.parent_id === pid)) {
      out.add(c.id);
      walk(c.id);
    }
  };
  walk(id);
  return out;
}

function folderPath(f) {
  const parts = [];
  let cur = f;
  while (cur) {
    parts.unshift(cur.title);
    cur = folderById(cur.parent_id);
  }
  return parts.join(" › ");
}

function folderOptions(selected, excludeIds = new Set()) {
  const opts = [`<option value="">(Top level)</option>`];
  const walk = (pid, depth) => {
    for (const f of childrenOf(pid)) {
      if (excludeIds.has(f.id)) continue;
      opts.push(
        `<option value="${f.id}"${f.id === selected ? " selected" : ""}>${"— ".repeat(depth)}${escapeHtml(f.title)}</option>`
      );
      walk(f.id, depth + 1);
    }
  };
  walk(null, 0);
  return opts.join("");
}

function uniqueSlug(title, ignoreId = null) {
  const base = slugify(title);
  const taken = new Set(folders.filter((f) => f.id !== ignoreId).map((f) => f.slug));
  if (!taken.has(base)) return base;
  let n = 2;
  while (taken.has(`${base}-${n}`)) n++;
  return `${base}-${n}`;
}

function nextSort(list) {
  return list.reduce((m, x) => Math.max(m, x.sort_order ?? 0), 0) + 10;
}

async function reload(keepSelection = true) {
  const res = await loadVideoTutorials(supabase);
  if (res.error) {
    setStatus(
      "pageStatus",
      `❌ ${res.error.message} — run supabase/sql/patches/video_tutorials_admin_20261005.sql`,
      false
    );
    return;
  }
  folders = res.folders;
  links = res.links;
  if (!keepSelection || !folderById(selectedId)) selectedId = childrenOf(null)[0]?.id ?? null;
  renderTree();
  renderPanel();
}

function renderTree() {
  const tree = document.getElementById("folderTree");
  const walk = (pid) =>
    childrenOf(pid)
      .map((f) => {
        const kids = childrenOf(f.id);
        const n = linksOf(f.id).length;
        return `<li>
          <div class="vta-node${f.id === selectedId ? " sel" : ""}" data-id="${f.id}">
            📁 ${escapeHtml(f.title)}
            ${!f.parent_id && f.show_in_menu ? `<span class="menu">menu</span>` : ""}
            <span class="cnt">${n} video${n === 1 ? "" : "s"}</span>
          </div>
          ${kids.length ? `<ul>${walk(f.id)}</ul>` : ""}
        </li>`;
      })
      .join("");
  tree.innerHTML = folders.length ? walk(null) : `<li class="vta-muted">No folders yet — add one below.</li>`;
  tree.querySelectorAll(".vta-node").forEach((el) => {
    el.onclick = () => {
      selectedId = Number(el.dataset.id);
      renderTree();
      renderPanel();
    };
  });
  document.getElementById("newFolderParent").innerHTML = folderOptions(selectedId);
}

function videoRow(v, i, total) {
  const yt = youtubeId(v.url);
  return `<div class="vta-video" data-id="${v.id}">
    <div class="vta-row">
      <input type="text" class="v-title" value="${escapeHtml(v.title)}" placeholder="Title">
      <input type="url" class="v-url" value="${escapeHtml(v.url)}" placeholder="https://…">
    </div>
    <div class="vta-row" style="margin-top:6px;">
      <input type="text" class="v-desc" value="${escapeHtml(v.description || "")}" placeholder="Description (optional)" style="flex:1 1 300px;">
    </div>
    <div class="vta-row" style="margin-top:6px;">
      <span class="vta-muted">${yt ? "▶ YouTube — plays on page" : "🔗 Link card"}</span>
      <a class="vta-link" href="${escapeHtml(v.url)}" target="_blank" rel="noopener noreferrer">Test link ↗</a>
      <span style="flex:1"></span>
      <span class="order">
        <button type="button" class="button vta-btn-sm v-up"${i === 0 ? " disabled" : ""}>↑</button>
        <button type="button" class="button vta-btn-sm v-down"${i === total - 1 ? " disabled" : ""}>↓</button>
      </span>
      <select class="v-move" title="Move to folder">${folderOptions(v.folder_id).replace(
        `<option value="">(Top level)</option>`,
        ""
      )}</select>
      <button type="button" class="button vta-btn-sm vta-ok v-save">Save</button>
      <button type="button" class="button vta-btn-sm vta-danger v-del">Delete</button>
    </div>
  </div>`;
}

function renderPanel() {
  const panel = document.getElementById("folderPanel");
  const f = folderById(selectedId);
  if (!f) {
    panel.innerHTML = `<p class="vta-muted">Select a folder on the left, or create one.</p>`;
    return;
  }
  const vids = linksOf(f.id);
  const exclude = descendantIds(f.id);
  exclude.add(f.id);
  panel.innerHTML = `
    <h2>📁 ${escapeHtml(folderPath(f))}</h2>
    <p class="vta-muted">Page link: <a class="vta-link" href="video_tutorials.html#${escapeHtml(f.slug)}" target="_blank">video_tutorials.html#${escapeHtml(f.slug)}</a></p>
    <div class="vta-form">
      <div class="vta-row">
        <label style="flex:2 1 220px;">Name <input type="text" id="fTitle" value="${escapeHtml(f.title)}"></label>
        <label style="flex:2 1 200px;">Inside <select id="fParent">${folderOptions(f.parent_id, exclude)}</select></label>
      </div>
      <label>Folder description (optional) <input type="text" id="fDesc" value="${escapeHtml(f.description || "")}"></label>
      <div class="vta-row">
        <label class="vta-check"><input type="checkbox" id="fMenu"${f.show_in_menu ? " checked" : ""}> Show in menu (top-level only)</label>
        <span style="flex:1"></span>
        <button type="button" class="button vta-btn-sm" id="fUp">↑ Move up</button>
        <button type="button" class="button vta-btn-sm" id="fDown">↓ Move down</button>
        <button type="button" class="button vta-btn-sm vta-ok" id="fSave">Save folder</button>
        <button type="button" class="button vta-btn-sm vta-danger" id="fDel">Delete folder</button>
      </div>
    </div>

    <h3>Add video to this folder</h3>
    <div class="vta-form">
      <div class="vta-row">
        <input type="text" id="nvTitle" placeholder="Title / header, e.g. How to list a player" style="flex:1 1 240px;">
        <input type="url" id="nvUrl" placeholder="Link, e.g. https://www.youtube.com/watch?v=…" style="flex:1 1 280px;">
      </div>
      <input type="text" id="nvDesc" placeholder="Description (optional)">
      <div class="vta-row"><button type="button" class="button vta-ok" id="nvAdd">Add video</button></div>
    </div>

    <h3>Videos (${vids.length})</h3>
    <div id="videoList">${
      vids.length
        ? vids.map((v, i) => videoRow(v, i, vids.length)).join("")
        : `<p class="vta-muted">No videos in this folder yet.</p>`
    }</div>`;

  document.getElementById("fSave").onclick = () => saveFolder(f);
  document.getElementById("fDel").onclick = () => deleteFolder(f);
  document.getElementById("fUp").onclick = () => moveFolder(f, -1);
  document.getElementById("fDown").onclick = () => moveFolder(f, 1);
  document.getElementById("nvAdd").onclick = () => addVideo(f);

  panel.querySelectorAll(".vta-video").forEach((row) => {
    const v = links.find((l) => l.id === Number(row.dataset.id));
    row.querySelector(".v-save").onclick = () => saveVideo(v, row);
    row.querySelector(".v-del").onclick = () => deleteVideo(v);
    row.querySelector(".v-up").onclick = () => moveVideo(v, -1);
    row.querySelector(".v-down").onclick = () => moveVideo(v, 1);
  });
}

function validUrl(url) {
  return /^https?:\/\/\S+$/i.test(url);
}

async function addFolder() {
  const title = document.getElementById("newFolderTitle").value.trim();
  if (!title) return setStatus("pageStatus", "Enter a folder name.", false);
  const parentVal = document.getElementById("newFolderParent").value;
  const parent_id = parentVal ? Number(parentVal) : null;
  const { data, error } = await supabase
    .from("video_tutorial_folders")
    .insert({
      title,
      parent_id,
      slug: uniqueSlug(title),
      sort_order: nextSort(childrenOf(parent_id)),
      show_in_menu: document.getElementById("newFolderMenu").checked,
    })
    .select("id")
    .single();
  if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
  document.getElementById("newFolderTitle").value = "";
  clearVideoTutorialMenuCache();
  selectedId = data.id;
  setStatus("pageStatus", `✅ Folder "${title}" added.`);
  await reload();
}

async function saveFolder(f) {
  const title = document.getElementById("fTitle").value.trim();
  if (!title) return setStatus("pageStatus", "Folder name can't be empty.", false);
  const parentVal = document.getElementById("fParent").value;
  const parent_id = parentVal ? Number(parentVal) : null;
  const patch = {
    title,
    parent_id,
    description: document.getElementById("fDesc").value.trim() || null,
    show_in_menu: document.getElementById("fMenu").checked,
  };
  if (parent_id !== (f.parent_id ?? null)) patch.sort_order = nextSort(childrenOf(parent_id));
  const { error } = await supabase.from("video_tutorial_folders").update(patch).eq("id", f.id);
  if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
  clearVideoTutorialMenuCache();
  setStatus("pageStatus", `✅ Folder saved.`);
  await reload();
}

async function deleteFolder(f) {
  const subCount = descendantIds(f.id).size;
  const allIds = new Set([f.id, ...descendantIds(f.id)]);
  const vidCount = links.filter((l) => allIds.has(l.folder_id)).length;
  const msg =
    `Delete folder "${f.title}"` +
    (subCount || vidCount ? ` and everything inside it (${subCount} sub-folder(s), ${vidCount} video(s))` : "") +
    "? This can't be undone.";
  if (!confirm(msg)) return;
  const { error } = await supabase.from("video_tutorial_folders").delete().eq("id", f.id);
  if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
  clearVideoTutorialMenuCache();
  selectedId = f.parent_id ?? null;
  setStatus("pageStatus", `✅ Folder deleted.`);
  await reload(selectedId != null);
}

async function renumber(table, ordered) {
  const updates = ordered
    .map((row, i) => ({ id: row.id, sort_order: (i + 1) * 10, old: row.sort_order }))
    .filter((u) => u.sort_order !== u.old);
  for (const u of updates) {
    const { error } = await supabase.from(table).update({ sort_order: u.sort_order }).eq("id", u.id);
    if (error) throw error;
  }
}

async function moveFolder(f, dir) {
  const sibs = childrenOf(f.parent_id ?? null);
  const i = sibs.findIndex((s) => s.id === f.id);
  const j = i + dir;
  if (j < 0 || j >= sibs.length) return;
  [sibs[i], sibs[j]] = [sibs[j], sibs[i]];
  try {
    await renumber("video_tutorial_folders", sibs);
  } catch (err) {
    return setStatus("pageStatus", `❌ ${err.message}`, false);
  }
  clearVideoTutorialMenuCache();
  await reload();
}

async function addVideo(f) {
  const title = document.getElementById("nvTitle").value.trim();
  const url = document.getElementById("nvUrl").value.trim();
  if (!title) return setStatus("pageStatus", "Enter a title for the video.", false);
  if (!validUrl(url)) return setStatus("pageStatus", "Enter a full link starting with https://", false);
  const { error } = await supabase.from("video_tutorial_links").insert({
    folder_id: f.id,
    title,
    url,
    description: document.getElementById("nvDesc").value.trim() || null,
    sort_order: nextSort(linksOf(f.id)),
  });
  if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
  setStatus("pageStatus", `✅ Added "${title}".`);
  await reload();
}

async function saveVideo(v, row) {
  const title = row.querySelector(".v-title").value.trim();
  const url = row.querySelector(".v-url").value.trim();
  if (!title) return setStatus("pageStatus", "Title can't be empty.", false);
  if (!validUrl(url)) return setStatus("pageStatus", "Enter a full link starting with https://", false);
  const folder_id = Number(row.querySelector(".v-move").value) || v.folder_id;
  const patch = {
    title,
    url,
    description: row.querySelector(".v-desc").value.trim() || null,
    folder_id,
  };
  if (folder_id !== v.folder_id) patch.sort_order = nextSort(linksOf(folder_id));
  const { error } = await supabase.from("video_tutorial_links").update(patch).eq("id", v.id);
  if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
  setStatus(
    "pageStatus",
    folder_id !== v.folder_id ? `✅ Saved and moved to ${folderPath(folderById(folder_id))}.` : `✅ Saved.`
  );
  await reload();
}

async function deleteVideo(v) {
  if (!confirm(`Delete video "${v.title}"?`)) return;
  const { error } = await supabase.from("video_tutorial_links").delete().eq("id", v.id);
  if (error) return setStatus("pageStatus", `❌ ${error.message}`, false);
  setStatus("pageStatus", `✅ Video deleted.`);
  await reload();
}

async function moveVideo(v, dir) {
  const sibs = linksOf(v.folder_id);
  const i = sibs.findIndex((s) => s.id === v.id);
  const j = i + dir;
  if (j < 0 || j >= sibs.length) return;
  [sibs[i], sibs[j]] = [sibs[j], sibs[i]];
  try {
    await renumber("video_tutorial_links", sibs);
  } catch (err) {
    return setStatus("pageStatus", `❌ ${err.message}`, false);
  }
  await reload();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage())) return;
  document.getElementById("addFolderBtn").onclick = addFolder;
  await reload(false);
});
