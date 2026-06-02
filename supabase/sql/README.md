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
