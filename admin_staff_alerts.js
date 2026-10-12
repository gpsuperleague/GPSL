import { initAdminPage, primeAdminPageChrome, setStatus, supabase } from "./admin_common.js";

primeAdminPageChrome();

function escapeHtml(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

function formatWhen(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

async function loadAlerts() {
  setStatus("status", "Loading…");
  const { data, error } = await supabase.rpc("gpsl_staff_alerts_list", { p_limit: 80 });
  const wrap = document.getElementById("alertList");
  if (error) {
    setStatus(
      "status",
      error.message + " — run gpsl_staff_alerts.sql",
      false
    );
    if (wrap) wrap.innerHTML = "";
    return;
  }
  const rows = Array.isArray(data) ? data : [];
  const unread = rows.filter((r) => !r.is_read).length;
  setStatus(
    "status",
    rows.length
      ? `${rows.length} alert(s)${unread ? ` · ${unread} unread` : ""}.`
      : "No staff alerts yet.",
    true
  );
  if (!wrap) return;
  if (!rows.length) {
    wrap.innerHTML = `<p class="note">When someone joins via Join GPSL, an alert appears here for admins and mods.</p>`;
    return;
  }
  wrap.innerHTML = rows
    .map((r) => {
      const unreadBadge = r.is_read ? "" : `<span class="badge-new">NEW</span>`;
      const href = r.action_href
        ? `<a class="button secondary" href="${escapeHtml(r.action_href)}">Open</a>`
        : "";
      const mark = r.is_read
        ? ""
        : `<button type="button" class="button secondary" data-mark="${r.id}">Mark read</button>`;
      return `
        <article class="alert-card${r.is_read ? "" : " unread"}" data-id="${r.id}">
          <h3>${escapeHtml(r.title)}${unreadBadge}</h3>
          <div class="alert-meta">${escapeHtml(r.alert_type)} · ${escapeHtml(formatWhen(r.created_at))}</div>
          <div class="alert-body">${escapeHtml(r.body || "")}</div>
          <div class="alert-actions">${href}${mark}</div>
        </article>`;
    })
    .join("");

  wrap.querySelectorAll("[data-mark]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = Number(btn.getAttribute("data-mark"));
      const { error: err } = await supabase.rpc("gpsl_staff_alert_mark_read", {
        p_alert_id: id,
      });
      if (err) {
        setStatus("status", err.message, false);
        return;
      }
      await loadAlerts();
    });
  });
}

const SITE_BASE = "https://gpsuperleague.github.io/GPSL/";
const DISCORD_DM_LIMIT = 2000;

/** Whole lines into chunks that each fit one Discord message. */
function splitForDiscord(lines) {
  const parts = [];
  let current = "";
  for (const line of lines) {
    const next = current ? `${current}\n${line}` : line;
    if (next.length > DISCORD_DM_LIMIT && current) {
      parts.push(current.trimEnd());
      current = line;
    } else {
      current = next;
    }
  }
  if (current.trim()) parts.push(current.trimEnd());
  return parts;
}

async function vacantClubsLines() {
  const { data, error } = await supabase.rpc("staff_vacant_clubs_list");
  if (error || data?.ok === false) {
    throw new Error(
      `${error?.message || data?.reason || "Could not load"} — run staff_vacant_clubs_list_20261012.sql`
    );
  }
  const clubs = Array.isArray(data?.clubs) ? data.clubs : [];
  if (!clubs.length) return { count: 0, lines: [] };
  const lines = [
    `**GPSL — clubs looking for an owner${data.season_label ? ` (${data.season_label})` : ""}**`,
  ];
  let division = null;
  for (const c of clubs) {
    if (c.division_label !== division) {
      division = c.division_label;
      lines.push("", `**${division}**`);
    }
    lines.push(`• ${c.club_name} (${c.short_name})`);
  }
  lines.push(
    "",
    `Browse them: ${SITE_BASE}club_database.html (Owner filter → Vacant)`,
    "Interested in one? Reply here and let us know which."
  );
  return { count: clubs.length, lines };
}

async function faManagersLines() {
  const { data, error } = await supabase
    .from("managers_gpdb_public")
    .select("name, nation, rating, contracted_club")
    .order("rating", { ascending: false })
    .order("name", { ascending: true });
  if (error) throw new Error(error.message);
  const managers = (data || []).filter((m) => !String(m.contracted_club || "").trim());
  if (!managers.length) return { count: 0, lines: [] };
  const lines = ["**GPSL — managers available to sign**", ""];
  for (const m of managers) {
    lines.push(`• ${m.name}${m.nation ? ` (${m.nation})` : ""} · ${m.rating ?? "—"}`);
  }
  lines.push("", `Full details: ${SITE_BASE}MGDB.html`);
  return { count: managers.length, lines };
}

function wireShareList({ prefix, noun, emptyText, loadLines }) {
  const textEl = document.getElementById(`${prefix}Text`);
  const copyWrap = document.getElementById(`${prefix}Copy`);
  const countEl = document.getElementById(`${prefix}Count`);
  const statusId = `${prefix}Status`;
  let parts = [];

  const copyPart = async (i) => {
    try {
      await navigator.clipboard.writeText(parts[i]);
      setStatus(
        statusId,
        parts.length > 1
          ? `Copied part ${i + 1} of ${parts.length} — paste it into the Discord DM, then copy the next.`
          : "Copied — paste it into the member's Discord DM.",
        true
      );
    } catch {
      textEl.value = parts[i];
      textEl.select();
      setStatus(statusId, "Copy blocked by the browser — text selected, press Ctrl+C.", false);
    }
  };

  const load = async () => {
    setStatus(statusId, "Loading…");
    copyWrap.innerHTML = "";
    try {
      const { count, lines } = await loadLines();
      parts = splitForDiscord(lines);
      textEl.value = parts.join("\n\n— next message —\n\n");
      countEl.textContent = `${count} ${noun}`;
      if (!count) {
        setStatus(statusId, emptyText, true);
        return;
      }
      copyWrap.innerHTML = parts
        .map(
          (_, i) =>
            `<button type="button" class="button" data-part="${i}">${
              parts.length > 1 ? `Copy part ${i + 1}/${parts.length}` : "Copy"
            }</button>`
        )
        .join("");
      copyWrap.querySelectorAll("[data-part]").forEach((btn) => {
        btn.addEventListener("click", () => copyPart(Number(btn.dataset.part)));
      });
      setStatus(
        statusId,
        parts.length > 1
          ? `${count} ${noun} · too long for one Discord message, so split into ${parts.length} parts.`
          : `${count} ${noun}.`,
        true
      );
    } catch (err) {
      parts = [];
      textEl.value = "";
      countEl.textContent = "unavailable";
      setStatus(statusId, err?.message || String(err), false);
    }
  };

  document.getElementById(`${prefix}Refresh`)?.addEventListener("click", load);
  load();
}

document.addEventListener("DOMContentLoaded", async () => {
  if (!(await initAdminPage({ allowMod: true }))) return;
  wireShareList({
    prefix: "vacantClubs",
    noun: "vacant club(s)",
    emptyText: "No vacant clubs this season.",
    loadLines: vacantClubsLines,
  });
  wireShareList({
    prefix: "faManagers",
    noun: "available manager(s)",
    emptyText: "No unsigned managers.",
    loadLines: faManagersLines,
  });
  document.getElementById("refreshBtn")?.addEventListener("click", loadAlerts);
  document.getElementById("markAllBtn")?.addEventListener("click", async () => {
    const { data, error } = await supabase.rpc("gpsl_staff_alerts_mark_all_read");
    if (error) {
      setStatus("status", error.message, false);
      return;
    }
    setStatus("status", `Marked ${data ?? 0} alert(s) read.`, true);
    await loadAlerts();
  });
  await loadAlerts();
});
