# Discord translation — setup to follow

Status (2026-10-15): code pushed; function deployed (4); commands registered (6, app id
1527242431995580558). Step 3 no longer needed — the function reads the public key with the bot token.
Translation key set and tested (Microsoft, 2026-10-15: test action returned Spanish OK).
Still to do: Interactions Endpoint URL (5).
Test any time: `SELECT public.gpsl_discord_translate_request('test');` then read `net._http_response`.

Translation provider: Microsoft Translator free tier (F0, 2M characters every month).
Secrets `AZURE_TRANSLATOR_KEY` and `AZURE_TRANSLATOR_REGION` (e.g. `uksouth`; leave unset for a
"Global" resource). DeepL / Google keys, if also set, are used only when Microsoft fails.

## What it does

- **Language choice** — Owner Details → "Discord translation" (about 30 languages, plus a tick box
  "DM me league announcements, translated"). In Discord: `/language`.
- **Right-click Translate** — right-click any message → **Apps → Translate** → private reply in the
  owner's language (only they see it). Works on normal messages and GPSL feed embeds.
- **`/english`** — owner types in their own language, gets English back privately to paste in the channel.
- **Translated announcement DMs** — every Natter league post (GPSL Admin / SuperLeague / Championship)
  is DM'd translated to owners with a language set. Channels stay English.
  Any other feed item can opt in with `translate_dm: true` in its metadata.

## Files

- `supabase/sql/patches/discord_translation_20261012.sql`
- `supabase/functions/discord-translate/index.ts`, `translate.ts`
- `supabase/config.toml` (discord-translate, `verify_jwt = false`)
- `owner_details.html`, `owner_details.js` (script tag `?v=20261012-language`) — push both

## Setup steps (in order)

1. **Run** `discord_translation_20261012.sql` in the Supabase SQL Editor.
   Last result row: `translate_function_url` should end in `/discord-translate`.
   Blank = the discord-sky-feed URL isn't stored in `gpsl_discord_feed_settings`.
2. **Translation key** — DeepL recommended (free plan: 500,000 characters/month).
   Edge Functions → Secrets: `DEEPL_API_KEY`.
   (Alternative: `GOOGLE_TRANSLATE_API_KEY`.)
3. **Secret `DISCORD_PUBLIC_KEY`** — Discord Developer Portal → the bot's application → General
   Information → Public Key. (`DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID` already exist.)
4. **Deploy**: `supabase functions deploy discord-translate --no-verify-jwt`
5. **Discord Developer Portal** → General Information → **Interactions Endpoint URL**:
   `https://<project>.supabase.co/functions/v1/discord-translate`
   (Discord tests the URL on save — deploy first. Does not affect the match-videos bot.)
6. **Register commands** — SQL Editor:
   ```sql
   SELECT public.admin_discord_translate_register_commands();
   ```
   A few seconds later:
   ```sql
   SELECT status_code, content FROM net._http_response ORDER BY id DESC LIMIT 1;
   ```
   403 "Missing Access" → re-invite the bot with the `applications.commands` scope ticked, then run
   the register line again.

## Checking

- DM results: `SELECT * FROM gpsl_discord_translate_dm_queue ORDER BY id DESC;`
  (`delivered` / `failed` per announcement; failures are usually owners with server DMs off.)
- Secrets check: POST `{"action":"diagnose"}` to the function with the feed invoke key as Bearer.
