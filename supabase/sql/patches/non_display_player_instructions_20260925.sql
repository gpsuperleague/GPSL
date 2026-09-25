-- Player instructions (separate from Show Subtactic):
-- Owners must show individual player instructions on the HUD during the match
-- recording. Missing display is reportable via Fixtures R and fined ₿10m.
-- Also restores non_display_sub_tactic label (subtactic ≠ individual tactics).

BEGIN;

UPDATE public.competition_fine_tariff
SET
  label = 'Non Display Sub Tactic',
  updated_at = now()
WHERE code = 'non_display_sub_tactic';

INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES (
  'non_display_player_instructions',
  'Non Display Player Instructions',
  'matchday',
  'fine',
  10000000,
  'fixed',
  76,
  true
)
ON CONFLICT (code) DO UPDATE
SET
  label = EXCLUDED.label,
  category = EXCLUDED.category,
  direction = EXCLUDED.direction,
  amount = EXCLUDED.amount,
  amount_mode = EXCLUDED.amount_mode,
  sort_order = EXCLUDED.sort_order,
  is_active = true,
  updated_at = now();

COMMIT;
