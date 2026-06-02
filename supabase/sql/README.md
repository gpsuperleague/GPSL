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

Next: Phase 1 fixtures (`competition_fixtures` — not yet in repo).

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

GPDB and `club.html` show **Offer under review** while `Player_Transfer_Bids` has `is_direct`, `listing_id` null, `status = active`, and a `player_id`.

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
