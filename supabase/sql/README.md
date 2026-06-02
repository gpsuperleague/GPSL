# Supabase SQL (manual apply)

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

## One direct offer per player (pending review)

Run once to block duplicate direct offers in the database:

[`direct_offer_guard.sql`](./direct_offer_guard.sql)

GPDB and `club.html` show **Offer under review** while `Player_Transfer_Bids` has `is_direct`, `listing_id` null, `status = active`, and a `direct_bid_id`.

## Hide secret random finish from club owners

Run once in SQL Editor:

[`global_settings_public.sql`](./global_settings_public.sql)

This creates view `global_settings_public` (no `draft_random_finish_time`), restricts direct `SELECT` on `global_settings` to the admin email, and adds a trigger so draft bids are rejected after the secret finish server-side.

The view uses `security_invoker = false` so owners can read window/draft flags without seeing `draft_random_finish_time` on the base table.

After applying, owners must use the view in the app (already wired in `draft_engine.js`, `global.js`, GPDB, draft pages). **Admin** (`admin.html`) still reads/writes the full `global_settings` row via RLS + Edge Function.

If admin shows the transfer window **open** but GPDB/club pages show **Window Closed** for everyone, re-run this script in the SQL Editor (view was missing `security_invoker = false`).

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
