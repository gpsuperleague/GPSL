SELECT discord_user_id, sent_at, ok, via,
  dm_channel_id IS NOT NULL AS has_dm,
  hall_channel_id IS NOT NULL AS has_hall,
  hall_channel_id, hall_message_id,
  left(coalesce(error,''), 200) AS err
FROM public.gpsl_discord_welcome_sent
WHERE dm_channel_id IS NOT NULL OR hall_channel_id IS NOT NULL OR via IS DISTINCT FROM 'seed_existing'
ORDER BY sent_at DESC NULLS LAST
LIMIT 20;
