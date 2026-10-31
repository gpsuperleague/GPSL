SELECT discord_user_id, display_name, dm_channel_id, hall_channel_id, hall_message_id, sent_at, error
FROM public.gpsl_discord_welcome_sent
WHERE lower(coalesce(display_name,'')) LIKE '%anon%'
   OR lower(coalesce(display_name,'')) LIKE '%mouse%'
ORDER BY sent_at DESC NULLS LAST
LIMIT 10;
