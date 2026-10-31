# GPSL Discord welcome (optional bot)

**You do not need this folder for normal GPSL hosting.**

Welcome DMs run from **Supabase only**:

1. Edge function `discord-welcome-pack`
2. SQL cron `gpsl-discord-welcome-newcomers` (every 2 minutes)
3. Patch `discord_welcome_pack_cron_20261031.sql`

That polls Discord for new server members, assigns **Visitor**, and DMs the welcome pack — no VPS.

**Backfill Members (not Owners):** after deploy, invoke the edge function with
`{"action":"welcome_members","limit":12}` (repeat until `remaining` is 0).
Uses Discord **Member** role and skips anyone with the **Owner** role.

This Node bot is only if you want **instant** DMs on join (gateway event) instead of ~2 minute polling.
