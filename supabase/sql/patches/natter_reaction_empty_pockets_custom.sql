-- =============================================================================
-- Natter — custom empty-pockets reaction (trousers, pockets out)
-- Run after natter_reaction_finance_emojis.sql (or natter_reactions.sql)
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
    -- Finances & banter (gpsl:empty-pockets = custom SVG in natter.js)
    'gpsl:empty-pockets', '💯', '💵', '🤷‍♂️',
    -- Social & Natter
    '💬', '🗣️', '📣', '🧍‍♂️💬', '🕺', '🎤', '🧃', '🪩', '🧱', '🧩'
  ]::text[];
$$;

-- Migrate interim 👖💸 reactions if finance emoji patch was applied
UPDATE public.natter_reactions
SET emoji = 'gpsl:empty-pockets'
WHERE emoji = '👖💸';

NOTIFY pgrst, 'reload schema';
