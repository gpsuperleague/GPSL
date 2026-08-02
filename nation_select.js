import { supabase, initGlobal } from "./global.js";
import {
  loadInternationalNations,
  loadOwnerDraftOrder,
  loadSelectionWindow,
  loadMyNation,
  loadNationPlayerPoolReport,
  loadAvailableNationManagers,
  claimNation,
  renderNationFlag,
  nationPoolIsFaint,
  nationPoolIsSelectable,
  nationPoolFaintTitle,
  nationLink,
} from "./international.js";

let availableManagers = [];
let pendingNationCode = null;

function setStatus(msg, ok = true) {
  const el = document.getElementById("statusMsg");
  if (!el) return;
  el.textContent = msg;
  el.className = ok ? "ok" : "err";
}

function closeManagerModal() {
  pendingNationCode = null;
  const modal = document.getElementById("managerModal");
  if (modal) modal.classList.remove("open");
  const err = document.getElementById("managerModalError");
  if (err) err.textContent = "";
}

function openManagerModal(nationCode, nationName) {
  pendingNationCode = nationCode;
  const modal = document.getElementById("managerModal");
  const title = document.getElementById("managerModalTitle");
  const select = document.getElementById("managerSelect");
  const err = document.getElementById("managerModalError");
  if (!modal || !select) return;

  if (title) {
    title.textContent = `Appoint manager — ${nationName || nationCode}`;
  }
  if (err) err.textContent = "";

  if (!availableManagers.length) {
    select.innerHTML =
      '<option value="">No free national managers available</option>';
  } else {
    select.innerHTML =
      '<option value="">Select a manager…</option>' +
      availableManagers
        .map(
          (m) =>
            `<option value="${m.id}">${m.name} · rating ${m.rating}${
              m.nation ? ` · ${m.nation}` : ""
            }</option>`
        )
        .join("");
  }

  modal.classList.add("open");
  select.focus();
}

async function confirmClaimWithManager() {
  const err = document.getElementById("managerModalError");
  const select = document.getElementById("managerSelect");
  const submitBtn = document.getElementById("managerModalSubmit");
  if (!pendingNationCode || !select) return;

  const managerId = Number(select.value);
  if (!Number.isFinite(managerId) || managerId <= 0) {
    if (err) err.textContent = "Choose a national team manager.";
    return;
  }

  if (submitBtn) submitBtn.disabled = true;
  setStatus("Claiming nation and appointing manager…");
  const res = await claimNation(pendingNationCode, managerId, supabase);
  if (submitBtn) submitBtn.disabled = false;

  if (res.error) {
    if (err) err.textContent = res.error;
    setStatus(res.error, false);
    return;
  }

  const mgrName = res.data?.manager_name || "manager";
  const nationName = res.data?.nation_name || pendingNationCode;
  closeManagerModal();
  setStatus(`${nationName} claimed — ${mgrName} appointed (no fee).`, true);
  setTimeout(() => location.reload(), 700);
}

function renderWindow(windowState, myPick, draft, nations) {
  const el = document.getElementById("windowInfo");
  if (!el) return;
  if (!windowState?.is_open) {
    el.innerHTML =
      '<span class="empty">Nation selection is closed. Admin can open the window when ready.</span>';
    return;
  }
  const isFfa = windowState.pick_mode === "free_for_all";
  const nationCount = windowState.nations_total || nations.length;
  const waiting = windowState.waiting_count ?? draft.filter((d) => !d.nation_code).length;
  if (isFfa) {
    el.innerHTML = `
      <b>Nation selection</b> is open · <b style="color:#ff9900;">Free-for-all</b>
      · any club without a nation can claim now
      · appoint a <b>national manager</b> when you claim (no fee; cannot be shared across nations)
      · ${nationCount} nations available · ${windowState.nations_assigned || 0} assigned · ${waiting} still to pick
    `;
    return;
  }
  const mine =
    myPick && windowState.current_pick_rank === myPick
      ? ' <b style="color:#ff9900;">— your pick!</b>'
      : "";
  const draftSize =
    windowState.draft_order_size || draft.length || windowState.nations_total || nations.length || 60;
  el.innerHTML = `
    <b>Nation selection</b> is open · Pick #${windowState.current_pick_rank} of ${draftSize}
    · ${nationCount} nations available · ${windowState.nations_assigned || 0} assigned${mine}
    <br><span style="color:#aaa;font-size:12px;">Claiming a nation also appoints a national manager (free, exclusive across nations, until after the next World Cup finals).</span>
  `;
}

function renderDraftBoard(draft, myClub, currentPick, nationsByCode) {
  const el = document.getElementById("draftBoard");
  if (!el) return;
  if (!draft.length) {
    el.innerHTML = '<p class="empty">No owners in draft order yet.</p>';
    return;
  }
  const rows = draft
    .map((d) => {
      const cls = [
        d.pick_order === currentPick ? "current-pick" : "",
        d.club_short_name === myClub ? "me" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const nationRow = d.nation_code ? nationsByCode?.get(d.nation_code) : null;
      const nat = d.nation_code
        ? `${renderNationFlag({ code: d.nation_code, flag_emoji: d.flag_emoji, name: d.nation_name }, "sm")} ${nationLink(
            d.nation_code,
            d.nation_name,
            { isTaken: true }
          )}${
            nationRow?.manager_name
              ? ` <span class="empty" style="font-size:11px;">· ${nationRow.manager_name}</span>`
              : ""
          }`
        : '<span class="empty">—</span>';
      const ownerLabel = d.owner_tag || d.owner_name || "—";
      const clubLabel = d.club_name || d.club_short_name;
      return `
        <tr class="${cls}">
          <td>${d.pick_order}</td>
          <td>${ownerLabel}</td>
          <td>${clubLabel}</td>
          <td>${Number(d.rank_points).toLocaleString("en-GB", { maximumFractionDigits: 2 })}</td>
          <td>${nat}</td>
        </tr>`;
    })
    .join("");
  el.innerHTML = `
    <table class="draft-board">
      <thead><tr><th>#</th><th>Owner</th><th>Club</th><th>Rank pts</th><th>Nation</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
}

function renderNationGrid(nations, windowState, myPick, myClub, draft, poolByCode) {
  const el = document.getElementById("nationGrid");
  const hint = document.getElementById("pickHint");
  if (!el) return;

  const open = windowState?.is_open;
  const isFfa = windowState?.pick_mode === "free_for_all";
  const alreadyPicked = draft.find(
    (d) => d.club_short_name === myClub && d.nation_code
  );
  const myTurn = open && !alreadyPicked && (
    isFfa
      ? !!myClub
      : !!(myPick && windowState.current_pick_rank === myPick)
  );

  if (hint) {
    if (!open) hint.textContent = "Selection is closed.";
    else if (alreadyPicked)
      hint.textContent = isFfa
        ? `You selected ${alreadyPicked.nation_name}. Free-for-all continues for clubs still without a nation.`
        : `You selected ${alreadyPicked.nation_name}. Waiting for other owners…`;
    else if (myTurn)
      hint.textContent = isFfa
        ? "Free-for-all: click an available nation, then appoint a national manager (no fee)."
        : "Click an available nation, then appoint a national manager (no fee). Greyed-out nations cannot be selected.";
    else hint.textContent = `Waiting for pick #${windowState?.current_pick_rank || "—"}.`;
  }

  el.innerHTML = nations
    .map((n) => {
      const taken = n.is_taken;
      const poolRow = poolByCode?.get(n.code);
      const unselectable = poolRow ? !nationPoolIsSelectable(poolRow) : false;
      const faint = poolRow ? nationPoolIsFaint(poolRow) : false;
      const faintTitle = poolRow ? nationPoolFaintTitle(poolRow) : "";
      const disabled = !open || !myTurn || taken || unselectable;
      const cls = [
        "nat-pick-card",
        taken ? "taken" : "",
        disabled ? "disabled" : "",
        myTurn && !taken && !unselectable ? "my-turn" : "",
        faint ? "nat-pool-weak" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const titleParts = [];
      if (taken) titleParts.push("Taken — open squad");
      else if (unselectable) titleParts.push("Not selectable");
      titleParts.push(n.name);
      if (n.manager_name) titleParts.push(`Manager: ${n.manager_name}`);
      if (faintTitle) titleParts.push(faintTitle);
      const title = titleParts.join(" — ");
      const nameHtml = taken
        ? nationLink(n.code, n.name, { isTaken: true, className: "nat-card-link" })
        : n.name;
      const mgrHtml = n.manager_name
        ? `<span class="nat-mgr">${n.manager_name}</span>`
        : "";
      return `
        <div class="${cls}" data-code="${n.code}" data-taken="${taken ? "1" : "0"}" title="${title.replace(/"/g, "&quot;")}">
          <span class="flag">${renderNationFlag(n, "lg")}</span>
          <span class="name">${nameHtml}</span>
          ${mgrHtml}
        </div>`;
    })
    .join("");

  el.querySelectorAll(".nat-pick-card").forEach((card) => {
    card.addEventListener("click", (ev) => {
      if (ev.target.closest("a")) return;
      const code = card.dataset.code;
      if (!code) return;
      if (card.dataset.taken === "1") {
        window.location.href = `national_team.html?nation=${encodeURIComponent(code)}`;
        return;
      }
      if (card.classList.contains("disabled")) return;
      const nation = nations.find((n) => n.code === code);
      openManagerModal(code, nation?.name || code);
    });
  });
}

document.addEventListener("DOMContentLoaded", async () => {
  await initGlobal();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: clubRow } = await supabase
    .from("Clubs")
    .select("ShortName")
    .eq("owner_id", user?.id)
    .maybeSingle();
  const myClub = clubRow?.ShortName || null;

  const [nations, draft, windowState, myNation, poolRows, managers] =
    await Promise.all([
      loadInternationalNations(supabase),
      loadOwnerDraftOrder(supabase),
      loadSelectionWindow(supabase),
      loadMyNation(supabase),
      loadNationPlayerPoolReport(supabase).catch((err) => {
        console.warn("nation_select pool report:", err);
        return [];
      }),
      loadAvailableNationManagers(supabase).catch((err) => {
        console.warn("nation_select managers:", err);
        return [];
      }),
    ]);

  availableManagers = managers || [];
  const poolByCode = new Map((poolRows || []).map((r) => [r.nation_code, r]));
  const nationsByCode = new Map((nations || []).map((n) => [n.code, n]));

  const myPickRow = draft.find((d) => d.club_short_name === myClub);
  const myPick = myPickRow?.pick_order ?? null;

  if (myNation?.code) {
    const btn = document.getElementById("myTeamBtn");
    if (btn) {
      btn.href = `national_team.html?nation=${encodeURIComponent(myNation.code)}`;
      btn.hidden = false;
    }
  }

  document.getElementById("managerModalCancel")?.addEventListener("click", closeManagerModal);
  document.getElementById("managerModalSubmit")?.addEventListener("click", () => {
    void confirmClaimWithManager();
  });
  document.getElementById("managerModal")?.addEventListener("click", (ev) => {
    if (ev.target?.id === "managerModal") closeManagerModal();
  });

  renderWindow(windowState, myPick, draft, nations);
  renderDraftBoard(draft, myClub, windowState?.current_pick_rank, nationsByCode);
  renderNationGrid(nations, windowState, myPick, myClub, draft, poolByCode);
});
