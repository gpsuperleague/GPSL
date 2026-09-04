-- =============================================================================
-- Transfer ticker idle fillers: expand fun rumour pool (~20 new lines)
-- Safe re-run. Existing active idle rows keep old headlines until they expire.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_rumour_idle_templates()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    -- Original set
    'RUMOUR: Auditors query {club} over mystery consultancy fees — board calls it "analytics"',
    'RUMOUR: {club} paid an agent''s cousin for "scouting" — cousin has never watched a match',
    'RUMOUR: {club} accused of creative wage accounting via a "wellness programme"',
    'RUMOUR: {club} owner storms training demanding "more direct football"; manager hands him the tactics board',
    'RUMOUR: {club} owner tries to pick the XI; manager refuses the favourite',
    'RUMOUR: {club} owner wants nephew "who''s good at Excel" as lead analyst; manager threatens to walk',
    'RUMOUR: {club} striker claims unpaid goal bonuses; owner says only for "important goals"',
    'RUMOUR: {club} squad groan at owner''s 45-minute dressing-room PowerPoints',
    'RUMOUR: Contract talks at {club} stall over docking wages for looking "disinterested"',
    'RUMOUR: Agent claims {club} wanted fines for misplaced passes; club won''t show the paperwork',
    'RUMOUR: Backup keeper at {club} earns more than the top scorer — dressing room erupts',
    'RUMOUR: {club} sign shirt sponsor with a one-page site that just says "Coming Soon"',
    'RUMOUR: Training-ground reno budget at {club} doubles amid private-lounge whispers',
    'RUMOUR: {club} owner bans ketchup in the canteen; manager quietly puts it back',
    'RUMOUR: Fans spot burner accounts defending {club}''s owner — all created the same day',
    'RUMOUR: {club} unveil a giant pineapple mascot; players refuse the walkout',
    'RUMOUR: {player} linked with a quiet contract tweak at {club} before the window shuts',
    'RUMOUR: {club} manager and board "not aligned" on whether to cash in on {player}',
    'RUMOUR: Agents circle {player} as {club} go quiet on renewal talks',

    -- New batch
    'RUMOUR: {club} install a motivational quote wall; first line is just the owner''s name in Comic Sans',
    'RUMOUR: {club} kit launch delayed after the sponsor logo was printed upside down on every shirt',
    'RUMOUR: {club} analytics team "prove" long throws are a secret weapon; manager quietly bins the report',
    'RUMOUR: {club} owner demands a press conference about the press conference schedule',
    'RUMOUR: {club} warm-up playlist is exclusively the owner''s karaoke favourites — squad revolt brewing',
    'RUMOUR: Physios at {club} ban foam rollers after three players tried to "race" them down the corridor',
    'RUMOUR: {club} claim their new recovery room is "elite"; it''s two beanbags and a broken fan',
    'RUMOUR: {club} board meeting overrun debating whether half-time oranges are "brand aligned"',
    'RUMOUR: Scout report on {player} at {club} is three pages of emoji and one "looks quick"',
    'RUMOUR: {club} owner turns up to training in full kit "just to feel involved"; nobody passes to him',
    'RUMOUR: {club} try a silent dressing room for "focus"; lasts four minutes before someone sneezes',
    'RUMOUR: {club} unveil a "data dashboard" that is Excel with the gridlines turned off',
    'RUMOUR: {player} spotted studying {club}''s last five highlights — all of them own goals',
    'RUMOUR: {club} order new training cones; delivery is 400 garden gnomes and a note saying "close enough"',
    'RUMOUR: {club} captain''s armband goes missing; found on the owner''s office coat hook',
    'RUMOUR: {club} announce a "culture reset" then serve the same pre-match lasagne as last season',
    'RUMOUR: Social media intern at {club} scheduled a transfer tease for the wrong player — still live',
    'RUMOUR: {club} want {player} to take set pieces because "he has nice hair for the cameras"',
    'RUMOUR: {club} install biometric turnstiles at the training ground; they only open for the kit man',
    'RUMOUR: {club} manager asks for a transfer shortlist; board sends a mood board and a vibe',
    'RUMOUR: {player} "open to a new challenge" according to sources who are definitely his mate in the group chat',
    'RUMOUR: {club} deny interest in {player} so loudly that rival clubs start asking questions'
  ];
$$;

COMMENT ON FUNCTION public.gpsl_rumour_idle_templates() IS
  'Idle transfer-ticker rumour lines ({club}/{player} placeholders). Mild club satire only.';

GRANT EXECUTE ON FUNCTION public.gpsl_rumour_idle_templates() TO authenticated, service_role;
