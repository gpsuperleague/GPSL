# Supabase SQL (manual apply)

## Owner dashboard layout

Run once (after auth is in use):

[`owner_dashboard_layout.sql`](./owner_dashboard_layout.sql)

Stores each owner’s chosen dashboard shortcuts (`panel_ids` matching `dashboard_registry.js`). Without this table, the app falls back to the default tile set and “Add to Dashboard” is disabled.

## Competition system (Phase 0+)

Full rules: [`docs/competition-spec.md`](../docs/competition-spec.md).

### Phase 0 — seasons & divisions (apply first)

Run once in SQL Editor:

[`competition_phase0.sql`](./competition_phase0.sql)

Creates `competition_seasons`, `competition_club_seasons`, public views, and admin RPCs:

- `competition_create_season(label)` — seeds all **60** clubs as unassigned
- Assign **20 SuperLeague** + **40 championship pool** in **GPSL Admin → Competition Season**
- `competition_draw_championship_ab` — random A/B split
- `competition_activate_season` — sets current active season

Owners see divisions on **Competition Progress** (`progress.html`) and **Club Details**.

### Phase 1 — league fixtures (after Phase 0 + active season)

Run once:

[`competition_phase1_fixtures.sql`](./competition_phase1_fixtures.sql)

Creates `competition_fixtures`, calendar helpers, and admin RPCs:

- **GPSL Admin → League Fixtures** — table slots 1–20 per division (dropdown), shuffle, save
- `competition_generate_league_fixtures` — double round-robin, **380 fixtures** per division (38 matchdays × 10)
- Calendar: August **3**, Sep–Apr **4** each, May **3**; weather tag per GPSL month

Owners view **`fixtures.html`** by division and matchday.

### Real-world calendar (GPSL month = UK week)

Run once (after phase 1, before owners play on schedule):

[`competition_real_world_calendar.sql`](./competition_real_world_calendar.sql)

- **GPSL Admin → GPSL season calendar** — set first **Friday 19:00 UK** = **GPSL August** unlock; Sep–May auto-advance every 7 days (lock at next Friday 7pm).
- Only fixtures whose **`gpsl_month`** matches the live month accept **new** result submissions (DB trigger + UI). Pending inbox confirms still work after lock.
- **Insert 1-week break** — shifts all future unlock/lock times forward; current month stays open.
- If calendar is **not configured**, behaviour is unchanged (all scheduled fixtures open).

### Phase 2 — standings & form (after Phase 1)

Run once:

[`competition_phase2_standings.sql`](./competition_phase2_standings.sql)

Creates view **`competition_standings_public`** (MP, W, D, L, GF, GA, GD, Pts, form last 10 by **matchday order**) and admin helper `competition_admin_record_result` until Match Day (Phase 3).

Owners see full tables with **zones** on **`progress.html`**.

### Phase 3 — matchday & inbox (after Phase 2)

Run once:

[`competition_phase3_matchday.sql`](./competition_phase3_matchday.sql)

- Owner submits score on **`matchday.html`** → opponent gets inbox message
- Opponent **Confirm** (updates table) or **Reject** (submitter can resubmit)
- Top nav: grouped menus + **Inbox** icon with unread badge + **Dashboard** shortcut (`inbox.html`, `nav_config.js`)

If owners see **other clubs’ inbox messages** or **pending scores** on fixtures they are not in, run once:

[`competition_inbox_owner_scope.sql`](./competition_inbox_owner_scope.sql)

**Transfer deal notifications** (buyer + seller inbox when a deal completes):

[`transfer_inbox_notifications.sql`](./transfer_inbox_notifications.sql)

Covers transfer list, direct offer, draft auction, foreign sale, squad overflow release, and special auction player wins. Requires `competition_inbox` from phase 3.

### Phase 4 — player stats (after Phase 3)

Run once:

[`competition_phase4_player_stats.sql`](./competition_phase4_player_stats.sql)

- **`competition_match_player_stats`** — goals, assists, rating, POTM per fixture (applied on confirm)
- Submit optional squad lines on **`matchday.html`** (`p_player_stats` on `competition_submit_result`)
- Leaderboards on **`league_stats.html`** (`competition_player_season_stats_public`)
- Season **Apps / G / A / Avg** on **`squad.html`**
- **Started / Subbed on** on Match Day: run [`competition_match_stats_started_sub.sql`](./competition_match_stats_started_sub.sql) once (adds columns + updates stats apply)
- **Ratings 0.1–10:** run [`competition_rating_min_0_1.sql`](./competition_rating_min_0_1.sql) once (DB was minimum 1.0)

**Default 23-man matchday squad** (pitch drag-and-drop, auto-starters on stats):

[`club_matchday_squad.sql`](./club_matchday_squad.sql) — owners set 11 + 12 on **Match Day → Match squad** tab (draggable pitch layout, 5 named saved formations per club); saved squad filters the stats table and auto-ticks **Started** for the pitch XI.

### Phase 5 — gate receipts & ledger (after Phase 4)

Run once:

[`competition_phase5_finances.sql`](./competition_phase5_finances.sql)

- **League home** gates → **100%** home club; **cup** (when added) → **50% / 50%**
- Formula: `capacity × fill_rate × ₿20/seat` — fill from **table position** + **5-season archive** (`competition_club_season_archive`)
- Credits **`Club_Finances`** + **`competition_finance_ledger`** on result **confirm** (and admin record/backfill)
- Owners: **`finances.html`** (balance + ledger), **`stadium.html`** (estimate + upcoming home games)
- Admin: **Backfill gate receipts**; RPC `competition_admin_archive_club_season` for history rows

If gates were calculated at the old **₿250/seat** rate, run once:

[`competition_gate_seat_price_20.sql`](./competition_gate_seat_price_20.sql)

That updates `competition_compute_gate_total` only — **already posted** ledger rows are unchanged; new confirms and backfills use **₿20/seat**.

### Phase 6 — cups & brackets (after Phase 5)

Run once:

[`competition_phase6_cups.sql`](./competition_phase6_cups.sql)

- **Prestige:** Super8, Plate, Shield, Spoon — qualify from standings (+ manual CH 16v17 playoff slots)
- **League cup:** 60 clubs, random draw, **4 byes** (configurable)
- Knockout brackets, **Match Day** submit/confirm (no draws), **50/50** gates, **instant prizes** (admin config)
- **`cups.html`** brackets · **GPSL Admin → Cup competitions**

### Cup prize fix (after Phase 6)

Run once:

[`competition_cup_prizes_fix.sql`](./competition_cup_prizes_fix.sql)

- Round fee paid to **both** clubs on confirm (not winner-only)
- Ledger type **`prize_cup`** (reclassifies old generic `prize` cup lines)
- Admin stages: `appearance`, `r1`, `r2`, `qf`, `sf`, `final` on **Cup fixtures**
- **Award round prize** override for walkover / no-show (fixture ID + club)

### League prize money (after Phase 5)

Run once:

[`competition_league_prizes.sql`](./competition_league_prizes.sql)

- Admin sets **₿ per table position (1–20)** per division on **GPSL Admin → Money management**
- **`progress.html`** league tables show a **Prize** column from config
- **`finances.html`** pending column projects prize for **current table position** until paid
- **Auto-pay** when all **38** league matches in a division are played (on result confirm), or admin **Pay league prizes**

### Government subsidies (after league prizes)

Run once:

[`government_subsidies.sql`](./government_subsidies.sql)

- **HG** — Quota (≤5) / Flying the flag (6–8) / National pride (9+); band rates on **GPSL Admin → Money management**; status on **Club Details**
- **Youth** — Grassroots / Youth Development / Academy / Centre of excellence by under-21 count
- **Built not bought** — qualifying players at or below admin max rating (minimum count)
- **EOS payout** when all **3** league divisions are **38/38** (idempotent per club/type); also via admin **Pay government subsidies**
- **`finances.html`** pending column projects subsidies until paid

### TV revenue (after government subsidies)

Run once:

[`competition_tv_revenue.sql`](./competition_tv_revenue.sql)

- Admin sets **₿ per match**, **matches per month/division**, **club min/max** on **GPSL Admin → Money management**
- **Select TV for month** or **Select TV for season** — scores fixtures (top-8 clashes, promotion/relegation, dry spell, etc.)
- Both clubs paid **`tv_revenue`** on result confirm; **Backfill TV payouts** for played fixtures
- **`finances.html`** pending column shows selected TV matches not yet played

### Season challenges (after TV revenue)

Run once:

[`competition_challenges.sql`](./competition_challenges.sql)

- Admin sets **stat targets** (goals, wins, clean sheets, POTM, etc.) on **GPSL Admin → Season challenges**
- **Start window** Aug–Dec, **mid window** Jan–May; default ₿1M per challenge, ₿5M period bonus
- **Instant `prize_challenge`** credit when a club hits the target (on result confirm)
- **Recheck all clubs** for retroactive awards after seeding mid-season
- Owners: **League → Challenges** or **Finances → Season challenges**

### Wage bill & taxes (after challenges)

Run once:

[`competition_wages_taxes.sql`](./competition_wages_taxes.sql)

- **Post season wage bills** — `wage_squad` + 34+ fee + star tax (idempotent per club/season)
- Admin: 34+ min rating & fee, star tax min rating & fee, emergency TAC % & threshold
- **Apply emergency TAC** — `gov_emergency_tax` on balance above threshold
- **`finances.html`** pending column forecasts unposted upkeep charges

### Fines & compensation (after wages/taxes)

Run once:

[`competition_fines.sql`](./competition_fines.sql)

- Excel tariff list seeded via **Admin → Fines & compensation → Seed Excel tariffs**
- **Apply to club** posts instant `gov_fine_compensation` (fine = debit, compensation = credit)
- SACK MGR / RLS MGR use **manual** amount at apply time

### Draft Auction vanished from nav?

Finance SQL patches (`competition_wages_taxes.sql`, `government_subsidies.sql`, etc.) recreate `global_settings_public` **without** `draft_bidding_open`. That breaks `loadGlobalSettings()` and hides Draft Auction.

Run once:

[`repair_global_settings_public.sql`](./repair_global_settings_public.sql)

Then confirm **Admin → Transfer window & engine** still has **Draft auction enabled** (re-enable if needed).

To inspect the secret finish time in SQL Editor: [`check_draft_random_finish.sql`](./check_draft_random_finish.sql)

### Club history, player career & Ballon d'Or

Run once after cup/match-stats SQL:

[`competition_history.sql`](./competition_history.sql)

- **Admin → Season management → Archive season stats** — snapshots league tables, cup winners, player season rows & awards
- **`history.html`** — honours, positions by season, club records (incl. record signing & sale from `Transfer_History`), Ballon winners at your club
- **`player_career.html?id=…`** — GPSL stint history (linked from squad player names)
- Ballon points: role-weighted (GK/DEF clean sheets, goals, assists, POTM, avg rating)

### Transfer polish (below-reserve UI + ledger for all deal types)

Run once after `central_bank_phase1.sql`:

[`transfer_ledger_polish.sql`](./transfer_ledger_polish.sql)

- **Transfer Centre → Seller Review:** accept/reject below-reserve auctions (`club_accept_below_reserve_sale` / `club_reject_below_reserve_sale`)
- **Ledger** for foreign sales, contract expiry MV, squad overflow releases, and special auctions (`special_auction_fee` / `special_auction_prize`)
- Backfill missing ledger lines (safe in SQL Editor — does not change balances): `SELECT backfill_transfer_finance_ledger();`

### Owner onboarding — club auction (new owners, no club yet)

Run once after `owner_detach_archive.sql`:

[`patches/owner_onboarding_club_auction.sql`](./patches/owner_onboarding_club_auction.sql)

- Status `awaiting_club_auction` on `gpsl_owner_registry`
- **£600m** `pending_starting_balance` until club auction win
- Owners without a club: **`awaiting_club.html`** — set **owner tag** before full site access
- Admin: **Owner administration → Register for club auction** or `admin_owner_register_for_club_auction(email)`
- **Phase 2 (not built yet):** club auction bidding + settlement → `Clubs.owner_id` + `Club_Finances.balance`, then `status = active`

### Club owner linking (admin)

Run once:

[`admin_assign_club_owner.sql`](./admin_assign_club_owner.sql)

Then in **GPSL Admin → Owner Administration → Link existing login to club**, enter the user’s **email** and club **ShortName** (e.g. `HUR`). The RPC resolves `auth.users.id` and sets `Clubs.owner_id` (no manual UUID).

**Add Owner** (edge function `create-owner`) still creates a **new** auth user and links the club in one step.

**Remove / archive owner** (short break vs left GPSL): [`patches/owner_detach_archive.sql`](./patches/owner_detach_archive.sql) — **GPSL Admin → Owner administration**. Detaches club + nation; keeps `competition_owner_season_ranking` history. Archived owners must be **unarchived** before **Link existing login to club**.

**Change owner club**: [`patches/owner_change_club.sql`](./patches/owner_change_club.sql) (after detach patch) — move an active owner to another club; vacates old club + releases its nation.

**All-time WC points** (national team performance): [`patches/owner_ranking_wc_points.sql`](./patches/owner_ranking_wc_points.sql) — adds World Cup tiers to `competition_owner_ranking_alltime_public` (not the rolling 4-season draft ranking).

## Wage % of market value (admin)

Run once:

[`player_wage_settings.sql`](./player_wage_settings.sql)

- **SuperLeague** and **Championship** wage as **% of `market_value`** on `global_settings`
- **GPSL Admin → Transfer Management → Save wage %**
- Functions: `calculate_standard_player_wage`, `calculate_player_wage_for_club`

## Sell to foreign club (Squad)

Run the **entire** script once (STEP 1 seed + STEP 2 functions):

[`sell_to_foreign_club.sql`](./sell_to_foreign_club.sql)

- Confirm final `SELECT` returns `FOREIGN`. Adds `Clubs.foreign_interest_remaining` (default **3**, −1 per foreign sale).
- Squad header badge + **Sell to foreign club** blocked at 0.
- Already sold before the counter existed? Run [`repair_foreign_interest_urd.sql`](./repair_foreign_interest_urd.sql) (syncs from `Transfer_History`; sets **URD** to **2** if no FOREIGN row yet). Edit the backdate timestamp in step 4 if needed.
- Requires `my_club_shortname()` (`special_auctions.sql`)

Then run [`foreign_interest_teams.sql`](./foreign_interest_teams.sql):

- Seeds **Foreign_Interest_Teams** pool (**25** real-world clubs, not GPSL `Clubs` rows — Bayern, Napoli, Sevilla, etc.).
- Already ran an older pool? Run [`foreign_interest_teams_reseed.sql`](./foreign_interest_teams_reseed.sql) to replace the list and refresh trackers.
- Per club: `foreign_tracking_teams` (up to 3 names) shown in the squad header — e.g. *"Club A, Club B and Club C are tracking your players"* with hint to use **Action**.
- Squad **Action** menu: **Sell to {each tracking club}**; chosen club drops off the list and badge.
- `Transfer_History.foreign_buyer_name` stores the fictional buyer name (FK buyer stays `FOREIGN`).

## Player economics columns (Potential / Calc_Potential)

Run once (no data import; formulas in `player_value_calcs.js`):

[`players_economics_columns.sql`](./players_economics_columns.sql)

- Adds nullable `Potential`, `Calc_Potential` on `Players`
- GPDB shows **Pot.** (calc potential); squad shows **Rating (Pot.)** e.g. `85 (95)`
- Stored `market_value` is unchanged until you run a future bulk update

See [`docs/pesdb-player-values.md`](../../docs/pesdb-player-values.md).

## Managers (MGDB)

Run in order in SQL Editor:

1. [`patches/managers_system.sql`](./patches/managers_system.sql) — `Managers` table, transfer listings, contract targets, club linkage, RPCs (`manager_sack`, `manager_place_bid`, `manager_process_season_end`, etc.)
2. [`repair_global_settings_public.sql`](./repair_global_settings_public.sql) — restores full `global_settings_public` (wages/TV + `draft_bidding_open` + manager draft columns). **Run after step 1** so player draft (`draftauction.html`) and admin finance settings keep working.
3. [`patches/managers_seed_data.sql`](./patches/managers_seed_data.sql) — 100 managers from `data/Managers.xlsx`

Re-seed after spreadsheet changes:

```bash
python scripts/generate_managers_seed.py
```

Then re-run `managers_seed_data.sql`.

**UI:** Transfers → **Manager Database** (`MGDB.html`), **Manager Market** (`manager_listings.html`), **Manager Draft Auction** (`manager_draftauction.html`). Admin → **Manager contract targets**, **Transfer window** (manager draft toggle). Manager draft shares the **Day 1 7pm UK start** with player draft but has **no 6pm cutoff** — bidding runs until the **Day 2 6:50pm random window**. No draft credits; each club may hold the highest bid on **one** manager auction at a time. Run [`patches/managers_draft_schedule.sql`](./patches/managers_draft_schedule.sql), [`patches/managers_draft_auction.sql`](./patches/managers_draft_auction.sql) (bid guard incl. one-lead rule), and **re-run [`transferengine_draft.sql`](./transferengine_draft.sql)** so `transferengine_settle_draft_auctions` settles **manager** draft threads (not only player draft). Manager draft settlement mirrors player draft: `transferengine_accept_manager_draft_sale` debits `Club_Finances`, sets `Managers.contracted_club`, then `manager_sync_club_rating` (updates `Clubs.manager_id` for Club Details). Run [`patches/manager_draft_settlement_fix.sql`](./patches/manager_draft_settlement_fix.sql) or full [`transferengine_draft.sql`](./transferengine_draft.sql). Manager draft is **not** blocked by player 7pm transfer-list extensions. Diagnostic: [`check_manager_draft_settlement.sql`](./check_manager_draft_settlement.sql). Stuck auctions: Admin → **Settle manager drafts now** or `SELECT admin_settle_manager_drafts_now();`. Winning club must **not** already have a manager (`Clubs.manager_id` / `Managers.contracted_club`).

**Season end:** After final league positions are set, run `SELECT manager_process_season_end();` (admin) to evaluate targets — hit → 2-year renewal; miss → release at market value.

**Rating / MV:** Rating = max playstyle proficiency. MV = **sum** of tier value for each of the five playstyles (0–60 ₿0; 61–65 ₿1m; 66–70 ₿2m; 71–73 ₿5m; 74–76 ₿8m; 77–79 ₿16m; 80–83 ₿25m; 84–85 ₿40m; 86–90 ₿60m). Wages = **50% of MV per year** (weekly ÷52). After deploy or formula change, run [`patches/managers_playstyle_mv.sql`](./patches/managers_playstyle_mv.sql).

Requires `post_club_ledger` ([`central_bank_phase1.sql`](./central_bank_phase1.sql)) and `my_club_shortname()`.

## Squad composition (home-grown / under-21)

Run once:

[`squad_composition_rules.sql`](./squad_composition_rules.sql)

**Squad overflow (29th player)** — run after phase 3 + foreign interest:

[`squad_overflow_enforcement.sql`](./squad_overflow_enforcement.sql)

- `player_assign_to_club` returns jsonb; if squad &gt; 28 after sign, releases highest rated (excluding same-season signings).
- Uses a **foreign club** tracking slot when `foreign_interest_remaining` &gt; 0; otherwise **MV** release.
- GPDB / transfer engine show a confirm dialog when already at **28** players.
- Retrospective / URD test: [`test_squad_overflow_urd.sql`](./test_squad_overflow_urd.sql) — preview release, `admin_enforce_squad_overflow('URD')` to fix 29→28 without a new signing.
- **MV overflow fine + paid-up lock:** [`patches/squad_overflow_paid_up_fine.sql`](./patches/squad_overflow_paid_up_fine.sql) — £10m fine per forced MV release (ledger `gov_fine_compensation`); player unavailable until next season. Foreign overflow unchanged (no fine).
- **Backfill historical MV fines:** [`patches/squad_overflow_mv_fines_backfill.sql`](./patches/squad_overflow_mv_fines_backfill.sql) — `SELECT squad_overflow_mv_fines_club_status('URD');` then `SELECT backfill_squad_overflow_mv_fines(true);`
- **Finances blank but fines in DB:** [`patches/fix_finance_ledger_public_current_season.sql`](./patches/fix_finance_ledger_public_current_season.sql) — public ledger view required `status = 'active'`; setup/preseason seasons hid all lines.
- **Voluntary contract release:** [`patches/voluntary_contract_release.sql`](./patches/voluntary_contract_release.sql) — squad action, 3/season, buy-out = wage × seasons left, `contract_release_comp` ledger.

- **Home-grown** = `Players.Nation` matches `Clubs.Nation` — **at least 8** (no cap; more allowed)
- **Under-21** = age **≤ 21** — **at least 5** (no cap)
- **Squad** — **max 28** players
- JS: `squad_rules.js` · Squad page compliance banner

## Player contracts (phase 1 — signing hooks)

Run once (after `player_wage_settings.sql` and an active `competition_seasons` row):

[`player_contract_hooks.sql`](./player_contract_hooks.sql)

- **`Season_Signed`** → current season `competition_seasons.label` on every club assignment (transfer accept, draft win, special-auction player prize).
- **Cleared** on foreign sale / `player_release_from_club`.
- **Same-season lock** — if `Season_Signed` equals the current season, the player cannot be transfer-listed, sold abroad, or receive market bids until the next season (DB triggers + `assert_player_transferable`).
- **`contract_seasons_remaining`** = 3 and **`contract_wage`** = standard wage (`calculate_player_wage_for_club`) on signing.
- Re-run [`transferengine_standard_bigint.sql`](./transferengine_standard_bigint.sql), [`transferengine_draft.sql`](./transferengine_draft.sql), [`sell_to_foreign_club.sql`](./sell_to_foreign_club.sql), [`special_auctions.sql`](./special_auctions.sql) if those RPCs were deployed before hooks (they call `player_assign_to_club` / `player_release_from_club`).

**Phase 2** — run [`player_contracts_phase2.sql`](./player_contracts_phase2.sql) after phase 1:

- Final year (`contract_seasons_remaining = 1`): cannot list/sell; Squad **Renew** / **Expire** (HG ≤23 renew at same wage; standard renew wage ≥ current).
- Admin **Start New Season** also runs `contract_tick_season_rollover` (decrements years for all contracted players).

**Phase 3 (C4–C5)** — run [`player_contracts_phase3_expiry.sql`](./player_contracts_phase3_expiry.sql):

- **Expiring Contracts** page (`expiring_contracts.html`) — hidden wage bids (one per club per player).
- GPDB **Wage bid** link for final-year standard players.
- **Start New Season** resolves highest bids (tie → current club), then decrements years, then releases players at 0 years (MV credit).

## Two separate systems

| Players | How they move | Engine |
|--------|----------------|--------|
| **Contracted** (has a club) | Transfer list auctions (`listing_type` standard), direct offers to seller → seller review → optional listing | **`transferengine_*`** (extensions, reserve, `accept_sale` with buyer + seller finances) |
| **Free agents** (no club) | Draft only when admin enables draft — GPDB “Draft Offer”, draft auction page | **`transferengine_settle_draft_auctions`** at `draft_random_finish_time` (not the standard expiry loop) |

Free agents must **not** use the standard listed-player transfer path. Contracted players must **not** use draft settlement.

The site triggers SQL every minute via Edge Function `transferengine_run` → `public.transferengine_run()`.

**Listings vanished from Transfer Market but no deals?** The market only shows `Active` rows with `end_time > now()`. After 7pm the row is hidden but still `Active` until the engine runs. Check GitHub Actions workflow `Transfer Engine Runner` (needs repo secret `SUPABASE_SERVICE_ROLE_KEY`), or run [`repair_stuck_evening_transfers.sql`](./repair_stuck_evening_transfers.sql) then `SELECT transferengine_run();` or Admin → **Run Transfer Engine Now** (after [`admin_transferengine_run.sql`](./admin_transferengine_run.sql)). Re-apply [`transferengine_standard_bigint.sql`](./transferengine_standard_bigint.sql) so expired listings sync high bids from `Player_Transfer_Bids` before closing.

**Processing order (each tick):** transfer list auctions first (standard listings whose `end_time` has passed, including **extensions** past 7pm). Draft settlement runs only when **both** are true: `now() >= draft_random_finish_time` (e.g. 6:57:53pm), and **no** `Active` transfer-**list** auction remains that was **scheduled for 7pm UK on the same evening** as `draft_random_finish_time` (extensions to 9pm still block; seller review / direct offers / next day’s listings do **not** block).

## Apply draft + run updates

1. Open [Supabase Dashboard](https://supabase.com/dashboard) → project **omyyogfumrjoaweuawjn**.
2. **SQL Editor** → New query.
3. Paste the full contents of [`transferengine_draft.sql`](./transferengine_draft.sql).
4. **Run** once.
5. Paste the full contents of [`transferengine_standard_bigint.sql`](./transferengine_standard_bigint.sql).
6. **Run** once. (Fixes `bigint` vs `integer` errors on contracted-player listings.)

This adds:

- `transferengine_accept_draft_sale` — free-agent winner, debit buyer, assign club
- `transferengine_settle_draft_auctions` — after random finish, only if `transferengine_standard_listings_block_draft_settlement()` is false
- `transferengine_process_standard_listings` — 7pm / extension expiry loop for standard listings
- Updates `transferengine_run` — process standard, then settle draft when the evening transfer list is clear

## Verify

```sql
SELECT transferengine_run();
```

Check **Logs** on Edge Function or `raise notice` output if enabled.

## `player_id` on bids + direct-offer guard

Run once (includes backfill, auto-fill trigger, and updated duplicate-offer guard):

[`player_transfer_bids_player_id.sql`](./player_transfer_bids_player_id.sql)

Adds `Player_Transfer_Bids.player_id` (Konami ID). Seller Review and pending-offer UI use this column; legacy rows are filled from `direct_bid_id` or the listing’s `player_id`.

GPDB and `club.html` show **Offer under review** while `Player_Transfer_Bids` has `is_direct`, `listing_id` null, `status = active`, and a `player_id`. **`seller_club_id` must be `Clubs.ShortName`** (not full name like `Urawa Reds`) or Transfer Centre Seller Review will be empty — run [`repair_direct_offer_seller_club_id.sql`](./repair_direct_offer_seller_club_id.sql) once if needed.

After accepting a direct offer, the transfer listing must have **`current_highest_bid`** / **`current_highest_bidder`** set to the accepted offer (Transfer Market reads those columns).

1. Run [`sync_listing_high_from_bid.sql`](./sync_listing_high_from_bid.sql) once (re-run if you applied an older version that referenced `updated_at` — that broke bid inserts).
2. Run [`accept_direct_offer.sql`](./accept_direct_offer.sql) once — seller **Accept** uses this RPC (sets high bid server-side).
3. If older listings still show no bids, run [`repair_direct_listing_high_bid.sql`](./repair_direct_listing_high_bid.sql) once.
4. Deploy latest `transfer_center.js` and `all_listings.js` (`?v=7` on the market page).

Older installs: [`direct_offer_guard.sql`](./direct_offer_guard.sql) is superseded by the script above.

## Hide secret random finish from club owners

Run once in SQL Editor:

[`global_settings_public.sql`](./global_settings_public.sql)

This creates view `global_settings_public` (no `draft_random_finish_time`, but includes computed `draft_bidding_open` so the UI ends when the secret random finish passes — not at a fixed 6:59:59 countdown). Restricts direct `SELECT` on `global_settings` to the admin email, and adds a trigger so draft bids are rejected after the secret finish server-side.

If a draft ran without `draft_random_finish_time` set, run [`repair_draft_random_finish.sql`](./repair_draft_random_finish.sql) once, then re-deploy admin `computeNextDraftTimesFromNow` for future enables.

The view uses `security_invoker = false` so owners can read window/draft flags without seeing `draft_random_finish_time` on the base table.

After bidding closes, the UI can show **when** the random window ended (without exposing the time beforehand). Run once:

[`patches/draft_random_finish_revealed.sql`](./patches/draft_random_finish_revealed.sql)

Adds `draft_random_finish_revealed` to `global_settings_public` (populated only when `now() >= draft_random_finish_time`). Re-run [`repair_global_settings_public.sql`](./repair_global_settings_public.sql) if finance patches recreated the view without this column.

After applying, owners must use the view in the app (already wired in `draft_engine.js`, `global.js`, GPDB, MGDB, draft pages). **Admin** (`admin.html`) still reads/writes the full `global_settings` row via RLS + Edge Function.

If admin shows the transfer window **open** but GPDB/club pages show **Window Closed** for everyone, re-run this script in the SQL Editor (view was missing `security_invoker = false`).

## Special auctions (lowest unique + snap)

Run once:

[`special_auctions.sql`](./special_auctions.sql)

Then use **GPSL Admin → Special auction** (`admin_special-auctions.html`) to create (tick **Show to owners immediately**), or **Set as active / scheduled**. Status `scheduled` = visible in nav before start time (e.g. 7pm tonight). After the window **Reveal** (lowest unique) / **Settle**.

## Modular admin UI + season lifecycle

Run once (after `competition_phase0.sql` and `competition_real_world_calendar.sql`):

[`admin_season_lifecycle.sql`](./admin_season_lifecycle.sql)

- New seasons use status **`preseason`** (legacy `setup` rows are migrated).
- **`competition_end_season()`** — ends the live year and sets nav **Summer Break** via `global_settings.league_phase`.
- **`competition_activate_season`** — requires a real-world calendar before going live.

Front-end: sub-pages (`admin_season.html`, `admin_fixtures-*.html`, `admin_money.html`, etc.) share `admin.css`, `admin_nav.js`, and `admin_common.js`. Top bar **Admin** is a normal nav group (like Transfers / League) for admins only; optional hub at `admin.html`.

If you already ran the first script, also run [`special_auctions_scheduled_status.sql`](./special_auctions_scheduled_status.sql).

## Finances & central bank (planning)

Design memory for `finances.html` overhaul, ledger line types, and **GPSL Central Bank** (club ↔ bank flows, loans + interest):

[`docs/finances-central-bank-spec.md`](../../docs/finances-central-bank-spec.md)

**Phase 1 SQL (run once):** [`central_bank_phase1.sql`](./central_bank_phase1.sql) — `gpsl_bank_account`, `post_club_ledger`, transfer settlement writes ledger lines, admin `backfill_transfer_finance_ledger()` for past deals (ledger only, no balance change).

**Loans (run after phase 1):** [`central_bank_loans.sql`](./central_bank_loans.sql) — `club_loans`, `club_take_loan` / `club_repay_loan`, extended `gpsl_bank_public` (limits + `loans_enabled`).

**Public bank views:** [`central_bank_public_views.sql`](./central_bank_public_views.sql) — `bank_ledger_public`, `club_loans_league_public` for [`central_bank.html`](../central_bank.html). EOS interest posting still TBD.

## Fix active listing end times (24h + 7pm UK)

After changing listing duration in the app, run once to update **existing** active standard/direct rows (e.g. an accepted direct offer still on a flat 24h timer):

[`recalc_standard_listing_end_times.sql`](./recalc_standard_listing_end_times.sql)

Uses each listing’s `start_time` (same anchor as new listings). Non-extended rows set **`end_time` = `initial_end_time`** from the same compute (avoids GMT/BST 1h drift). Engine-extended rows still use `GREATEST` on `end_time` and preserve `initial_end_time`.

**One-off repair** if `end_time` is exactly 1h after `initial_end_time` with no extension flags (e.g. listing 170):

[`repair_listing_end_time_gmt_drift.sql`](./repair_listing_end_time_gmt_drift.sql)

## International football & World Cup (v1)

Run once after `competition_phase0.sql`:

[`competition_international.sql`](./competition_international.sql)

Creates 60 core nations (expandable via GPDB sync), owner nation draft, World Cup cycle/group tables, international squads, and lifetime player caps (`international_player_career`).

**GPDB nation sync:** Run [`patches/international_sync_gpdb_nations.sql`](./patches/international_sync_gpdb_nations.sql), [`patches/international_nations_seed_rank_expand.sql`](./patches/international_nations_seed_rank_expand.sql) (required before sync — old schema capped seed rank at 99), then `SELECT public.international_sync_gpdb_nations();`, then re-run [`patches/international_nation_player_pool.sql`](./patches/international_nation_player_pool.sql). Admin → **Sync GPDB nations** on `admin_international.html`.

**Admin:** GPSL Admin → **World Cup & nations** (`admin_international.html`) — seed nations, open nation selection, assign teams, **skip current pick** if an owner is slow (run [`patches/international_admin_skip_pick.sql`](./patches/international_admin_skip_pick.sql)).

**Call-ups:** National team managers use **GPDB** → **My nation** filter → **Call up** on eligible players (matching `Players.Nation`, any club). Squad limit **23** (minimum **2 GKs** — cannot release a GK if that would drop below 2). Squad displays on `national_team.html` (squad-style layout). Run [`patches/international_callup_gpdb.sql`](./patches/international_callup_gpdb.sql) after `competition_international.sql`.

**Owners:** Cups → **World Cup** / **Nation selection**; national team page with flag and call-ups from club squad.

Qualifying fixtures, finals draws, and matchday integration are **schema-ready** — detail in a later pass.

Run after `competition_history.sql` and `competition_international.sql`:

[`competition_owner_ranking.sql`](./competition_owner_ranking.sql)

Season-by-season owner points (league + cups), **rolling last-4** leaderboard (World Cup nation draft order), and **all-time** hall of fame. Points recompute when admin archives a season; backfill via **Recompute all seasons** on World Cup & nations admin.

**Owners:** Cups → **Owner rankings** (`owner_rankings.html`).

## Draft auction favourites (saved threads)

Run once (requires `my_club_shortname()` from `special_auctions.sql`):

[`draft_auction_favourites.sql`](./draft_auction_favourites.sql)

Owners star players on **Draft Auction** (pinned to top of the list) and manage them under **Transfer Centre → Saved Draft Auctions**.

## Admin: Reset draft schedule

[`admin_reset_draft_auction.sql`](./admin_reset_draft_auction.sql) — `admin_reset_draft_auction()` clears **times only** (does not delete history). Emergency full wipe: `admin_purge_draft_auction_data()`.

If draft **Transfer_History** was lost by an old reset, run once: [`repair_draft_transfer_history.sql`](./repair_draft_transfer_history.sql) then `SELECT repair_draft_transfer_history_from_ledger();` (needs ledger `transfer_purchase` rows from central bank phase).

## One-time fix for old draft rows

If any draft listings were saved with lowercase status:

```sql
UPDATE "Player_Transfer_Listings"
SET status = 'Active'
WHERE listing_type = 'draft' AND lower(status) = 'active';
```
