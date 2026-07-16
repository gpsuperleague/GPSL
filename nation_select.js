import { supabase, initGlobal } from "./global.js";
import {
  loadInternationalNations,
  loadOwnerDraftOrder,
  loadSelectionWindow,
  loadMyNation,
  loadNationPlayerPoolReport,
  claimNation,
  renderNationFlag,
  nationPoolIsFaint,
  nationPoolIsSelectable,
  nationPoolFaintTitle,
} from "./international.js";

function setStatus(msg, ok = true) {
  const el = document.getElementById("statusMsg");
  if (!el) return;
  el.textContent = msg;
  el.className = ok ? "ok" : "err";
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
  `;
}

function renderDraftBoard(draft, myClub, currentPick) {
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
      const nat = d.nation_code
        ? `${renderNationFlag({ code: d.nation_code, flag_emoji: d.flag_emoji, name: d.nation_name }, "sm")} ${d.nation_name}`
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
        ? "Free-for-all: click an available nation to claim it now. Greyed-out nations cannot be selected."
        : "Click an available nation to claim it. Greyed-out nations cannot be selected — GPDB pool too small for a squad or GPSL club.";
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
      if (taken) titleParts.push("Taken");
      else if (unselectable) titleParts.push("Not selectable");
      titleParts.push(n.name);
      if (faintTitle) titleParts.push(faintTitle);
      const title = titleParts.join(" — ");
      return `
        <div class="${cls}" data-code="${n.code}" title="${title.replace(/"/g, "&quot;")}">
          <span class="flag">${renderNationFlag(n, "lg")}</span>
          <span class="name">${n.name}</span>
        </div>`;
    })
    .join("");

  el.querySelectorAll(".nat-pick-card:not(.taken):not(.disabled)").forEach((card) => {
    card.addEventListener("click", async () => {
      const code = card.dataset.code;
      if (!code || !confirm(`Claim ${code} as your national team?`)) return;
      setStatus("Claiming…");
      const res = await claimNation(code, supabase);
      if (res.error) {
        setStatus(res.error, false);
        return;
      }
      setStatus(`Nation ${code} claimed!`, true);
      setTimeout(() => location.reload(), 600);
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

  const [nations, draft, windowState, myNation, poolRows] = await Promise.all([
    loadInternationalNations(supabase),
    loadOwnerDraftOrder(supabase),
    loadSelectionWindow(supabase),
    loadMyNation(supabase),
    loadNationPlayerPoolReport(supabase).catch((err) => {
      console.warn("nation_select pool report:", err);
      return [];
    }),
  ]);

  const poolByCode = new Map((poolRows || []).map((r) => [r.nation_code, r]));

  const myPickRow = draft.find((d) => d.club_short_name === myClub);
  const myPick = myPickRow?.pick_order ?? null;

  if (myNation?.code) {
    const btn = document.getElementById("myTeamBtn");
    if (btn) {
      btn.href = `national_team.html?nation=${encodeURIComponent(myNation.code)}`;
      btn.hidden = false;
    }
  }

  renderWindow(windowState, myPick, draft, nations);
  renderDraftBoard(draft, myClub, windowState?.current_pick_rank);
  renderNationGrid(nations, windowState, myPick, myClub, draft, poolByCode);
});
