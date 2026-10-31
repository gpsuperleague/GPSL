SELECT discord_user_id, sent_at, ok, via,
  dm_channel_id IS NOT NULL AS has_dm,
  hall_channel_id, hall_message_id,
  left(coalesce(error,''), 160) AS err
FROM public.gpsl_discord_welcome_sent
ORDER BY sent_at DESC NULLS LAST
LIMIT 15;
