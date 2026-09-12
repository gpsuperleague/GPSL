# GPSL Match videos Discord bot

Always-on bot for **Matchday videos** channels. On each video upload it calls the
`discord-match-videos-ingest` Edge Function, which matches the filename to a
fixture and credits **₿200,000** Matchday revenue once per club.

## Filename

```
HomeShort 2-0 AwayShort [SL-MD5].mp4
HomeShort 1-0 AwayShort [S8-QF].mkv
```

| COMP | Meaning |
|------|---------|
| SL | SuperLeague |
| CH | Championship |
| S8 / CA / CL | Super8 |
| PL | Plate |
| SH | Shield |
| BW | Bowl |
| LC | League Cup |

League refs: `MD1`…`MD38`. Cup refs: `R16`, `QF`, `SF`, `F`, or `R1`…

## Discord setup

1. Category **Matchday videos** with child channels named by GPSL month (`January`, `august`, …).
2. Bot needs **Message Content Intent**, read/send reactions in those channels.
3. Deploy Edge Function: `supabase functions deploy discord-match-videos-ingest`
4. Secrets: `DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID`, `DISCORD_MATCH_VIDEOS_INVOKE_KEY` (optional if using service role from bot).

## Run

```bash
cd discord-bots/match-videos
cp .env.example .env   # fill values
npm install
npm start
```

Host anywhere that stays online (Fly, Railway, VPS, etc.).
