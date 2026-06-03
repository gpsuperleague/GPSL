# Supabase SQL (manual apply)

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
- Dashboard **Inbox** count links to matchday inbox

### Phase 4 — player stats (after Phase 3)

Run once:

[`competition_phase4_player_stats.sql`](./competition_phase4_player_stats.sql)

- **`competition_match_player_stats`** — goals, assists, rating, POTM per fixture (applied on confirm)
- Submit optional squad lines on **`matchday.html`** (`p_player_stats` on `competition_submit_result`)
- Leaderboards on **`league_stats.html`** (`competition_player_season_stats_public`)
- Season **Apps / G / A / Avg** on **`squad.html`**

### Phase 5 — gate receipts & ledger (after Phase 4)

Run once:

[`competition_phase5_finances.sql`](./competition_phase5_finances.sql)

- **League home** gates → **100%** home club; **cup** (when added) → **50% / 50%**
- Formula: `capacity × fill_rate × £250/seat` — fill from **table position** + **5-season archive** (`competition_club_season_archive`)
- Credits **`Club_Finances`** + **`competition_finance_ledger`** on result **confirm** (and admin record/backfill)
- Owners: **`finances.html`** (balance + ledger), **`stadium.html`** (estimate + upcoming home games)
- Admin: **Backfill gate receipts**; RPC `competition_admin_archive_club_season` for history rows

### Phase 6 — cups & brackets (after Phase 5)

Run once:

[`competition_phase6_cups.sql`](./competition_phase6_cups.sql)

- **Prestige:** Super8, Plate, Shield, Spoon — qualify from standings (+ manual CH 16v17 playoff slots)
- **League cup:** 60 clubs, random draw, **4 byes** (configurable)
- Knockout brackets, **Match Day** submit/confirm (no draws), **50/50** gates, **instant prizes** (admin config)
- **`cups.html`** brackets · **GPSL Admin → Cup competitions**

### Club owner linking (admin)

Run once:

[`admin_assign_club_owner.sql`](./admin_assign_club_owner.sql)

Then in **GPSL Admin → Owner Administration → Link existing login to club**, enter the user’s **email** and club **ShortName** (e.g. `HUR`). The RPC resolves `auth.users.id` and sets `Clubs.owner_id` (no manual UUID).

**Add Owner** (edge function `create-owner`) still creates a **new** auth user and links the club in one step.

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

## Squad composition (home-grown / under-21)

Run once:

[`squad_composition_rules.sql`](./squad_composition_rules.sql)

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

## Apply draft + run updates

1. Open [Supabase Dashboard](https://supabase.com/dashboard) → project **omyyogfumrjoaweuawjn**.
2. **SQL Editor** → New query.
3. Paste the full contents of [`transferengine_draft.sql`](./transferengine_draft.sql).
4. **Run** once.
5. Paste the full contents of [`transferengine_standard_bigint.sql`](./transferengine_standard_bigint.sql).
6. **Run** once. (Fixes `bigint` vs `integer` errors on contracted-player listings.)

This adds:

- `transferengine_accept_draft_sale` — free-agent winner, debit buyer, assign club
- `transferengine_settle_draft_auctions` — runs when `now() >= draft_random_finish_time`
- Updates `transferengine_run` — settles draft first, then standard auctions (excludes `listing_type = 'draft'` from extension/expiry loop)

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

This creates view `global_settings_public` (no `draft_random_finish_time`), restricts direct `SELECT` on `global_settings` to the admin email, and adds a trigger so draft bids are rejected after the secret finish server-side.

The view uses `security_invoker = false` so owners can read window/draft flags without seeing `draft_random_finish_time` on the base table.

After applying, owners must use the view in the app (already wired in `draft_engine.js`, `global.js`, GPDB, draft pages). **Admin** (`admin.html`) still reads/writes the full `global_settings` row via RLS + Edge Function.

If admin shows the transfer window **open** but GPDB/club pages show **Window Closed** for everyone, re-run this script in the SQL Editor (view was missing `security_invoker = false`).

## Special auctions (lowest unique + snap)

Run once:

[`special_auctions.sql`](./special_auctions.sql)

Then use **GPSL Admin → Special Auctions** to create (tick **Show to owners immediately**), or **Set as active / scheduled**. Status `scheduled` = visible in nav before start time (e.g. 7pm tonight). After the window **Reveal** (lowest unique) / **Settle**.

If you already ran the first script, also run [`special_auctions_scheduled_status.sql`](./special_auctions_scheduled_status.sql).

## Fix active listing end times (24h + 7pm UK)

After changing listing duration in the app, run once to update **existing** active standard/direct rows (e.g. an accepted direct offer still on a flat 24h timer):

[`recalc_standard_listing_end_times.sql`](./recalc_standard_listing_end_times.sql)

Uses each listing’s `start_time` (same anchor as new listings). Never shortens `end_time`; listings already extended by the engine keep their `initial_end_time`.

## Draft auction favourites (saved threads)

Run once (requires `my_club_shortname()` from `special_auctions.sql`):

[`draft_auction_favourites.sql`](./draft_auction_favourites.sql)

Owners star players on **Draft Auction** (pinned to top of the list) and manage them under **Transfer Centre → Saved Draft Auctions**.

## Admin: Reset Draft Auction button

If **Reset Draft Auction** in `admin.html` fails (RLS / permission errors), run once:

[`admin_reset_draft_auction.sql`](./admin_reset_draft_auction.sql)

Then deploy updated `admin.html` (calls `admin_reset_draft_auction()` RPC).

## One-time fix for old draft rows

If any draft listings were saved with lowercase status:

```sql
UPDATE "Player_Transfer_Listings"
SET status = 'Active'
WHERE listing_type = 'draft' AND lower(status) = 'active';
```
