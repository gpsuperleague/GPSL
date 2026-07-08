-- =============================================================================
-- Natter reactions — finances & banter emojis (empty pockets, 💯, 💵, 🤷‍♂️)
-- Run after natter_reactions.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.natter_allowed_reaction_emojis()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    -- Classic
    '👍', '😂', '🔥', '⚽', '👏', '❤️',
    -- Match moments
    '🥅', '🧤', '🥇', '🥈', '🏆', '🏟️', '🚩', '🟥', '🟨',
    '💥', '💨', '🧊', '🕶️', '🧠', '🪄', '🕰️', '⏱️', '🧨',
    -- Reactions
    '😍', '🤯', '😤', '😎', '😱', '🤩', '😡', '🤔', '🥳', '😭',
    -- Team & league
    '🧢', '👕', '🧣', '🎽', '🧭', '🏴', '🗺️', '🧾', '💼',
    '🧍‍♂️🧍‍♀️',
    -- Finances & banter
    '👖💸', '💯', '💵', '🤷‍♂️',
    -- Social & Natter
    '💬', '🗣️', '📣', '🧍‍♂️💬', '🕺', '🎤', '🧃', '🪩', '🧱', '🧩'
  ]::text[];
$$;

NOTIFY pgrst, 'reload schema';
