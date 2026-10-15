-- =============================================================================
-- Transfer ticker idle fillers: +50 fun rumour lines (existing 41 unchanged)
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

    -- Second batch
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
    'RUMOUR: {club} deny interest in {player} so loudly that rival clubs start asking questions',

    -- Third batch (Oct 2026): owners and boardroom
    'RUMOUR: {club} owner signs off a transfer budget on the back of a takeaway menu — chips order still visible',
    'RUMOUR: {club} owner asks the manager to "just play 11 strikers and see what happens"',
    'RUMOUR: {club} board vote 4–3 to rename the training ground after the owner''s dog',
    'RUMOUR: {club} owner caught refreshing the transfer page every 30 seconds "just in case"',
    'RUMOUR: {club} owner demands a meeting about why meetings keep running over',
    'RUMOUR: {club} owner insists every new signing must "pass the vibe check" in the car park',
    'RUMOUR: {club} chairman''s "state of the club" email is 2,000 words and ends with "anyway, up the lads"',
    'RUMOUR: {club} owner wants a statue outside the ground — of himself, holding a smaller statue of himself',
    'RUMOUR: {club} owner books a team-building escape room; squad still trapped after the owner lost the clue',
    'RUMOUR: {club} owner insists the club badge is "10% too serious"; adds sunglasses in the redesign',

    -- Third batch: money and finance
    'RUMOUR: {club} finance director found trying to pay a transfer fee in loyalty-card points',
    'RUMOUR: {club} accountant quits after being asked to make the wage bill "look friendlier"',
    'RUMOUR: {club} try to put {player}''s sell-on clause in the owner''s will',
    'RUMOUR: {club} owner haggles a ₿5 discount on a multi-million deal and calls it "a win for the fans"',
    'RUMOUR: {club} budget spreadsheet has a tab titled "DON''T OPEN" — the auditors opened it',
    'RUMOUR: {club} launch a crowdfunder for a new striker; current total is ₿12 and a signed headband',

    -- Third batch: players and agents
    'RUMOUR: {player} turns up to the medical in flip-flops and asks where the buffet is',
    'RUMOUR: {player}''s agent demands a clause guaranteeing a parking space "closer than the keeper''s"',
    'RUMOUR: {player} wants a move to {club} because "their away kit matches my car"',
    'RUMOUR: {player} posts a cryptic emoji; three clubs, two agents and a pundit claim to know what it means',
    'RUMOUR: {player} handed in a transfer request — turned out to be a takeaway order slipped under the wrong door',
    'RUMOUR: {player}''s agent spotted at {club}''s ground — insists he was "just using the toilets"',
    'RUMOUR: {player} seen leaving {club}''s training ground in a fake moustache; fooled absolutely nobody',
    'RUMOUR: {player} demands a goal-celebration budget after his backflip went "slightly wrong"',
    'RUMOUR: {player} learns to say "I''ve always dreamed of playing here" in six languages, just in case',
    'RUMOUR: {player}''s mum reportedly negotiating directly with {club} — "she''s tougher than his agent"',
    'RUMOUR: {player} has a "people close to the player" group chat — it''s just him on three phones',

    -- Third batch: managers and training
    'RUMOUR: {club} manager''s new formation is drawn on a napkin and includes a "vibes midfielder"',
    'RUMOUR: {club} training session called off after the cones were found arranged into a rude word',
    'RUMOUR: {club} manager replaces the tactics board with interpretive dance — results "mixed"',
    'RUMOUR: {club} try penalty practice in the dark "to build character"; three lights broken, zero goals',
    'RUMOUR: {club} manager''s half-time talk lasts 11 seconds and is just a long sigh',
    'RUMOUR: {club} hire a sleep coach; squad now napping through the warm-up "on instruction"',
    'RUMOUR: {club} assistant manager admits the "secret set piece" is just everyone pointing at the sky',

    -- Third batch: club life and fans
    'RUMOUR: {club} kit man holds the whole squad to ransom over a missing left boot',
    'RUMOUR: {club} mascot negotiating a better contract than half the bench',
    'RUMOUR: {club} pie supplier threatens to walk; fans say it''s the biggest exit of the window',
    'RUMOUR: {club} stadium announcer reads out the wrong team sheet — three of the names are from FIFA 98',
    'RUMOUR: {club} new club anthem leaked; it''s mostly kazoo',
    'RUMOUR: {club} supporters'' club AGM descends into chaos over the colour of the minibus',
    'RUMOUR: {club} club shop accidentally sells out of last season''s kit in a "retro" rebrand',
    'RUMOUR: {club} pre-season tour cancelled after the owner booked the coach for the wrong country',

    -- Third batch: GPSL-flavoured
    'RUMOUR: {club} owner forgot to bid in the draft auction because he was "watching the ticker"',
    'RUMOUR: {club} friendlies schedule now so packed the squad sleep on the team bus',
    'RUMOUR: {club} owner sends 40 Discord messages in a minute; 39 are "?" and one is a goat GIF',
    'RUMOUR: {club} spotted reading the GPSL rules for the first time — "there are rules?"',
    'RUMOUR: {club} owner sets a deadline-day alarm, then sleeps through it holding his phone',
    'RUMOUR: {club} claim they "nearly" signed {player} — talks reportedly reached the "Hi" stage',
    'RUMOUR: {club} owner blames the Bookies for his team''s form; the Bookies decline to comment',
    'RUMOUR: {club} hold a crisis meeting after losing a friendly; the result didn''t even count'
  ];
$$;

COMMENT ON FUNCTION public.gpsl_rumour_idle_templates() IS
  'Idle transfer-ticker rumour lines ({club}/{player} placeholders). Mild club satire only.';

GRANT EXECUTE ON FUNCTION public.gpsl_rumour_idle_templates() TO authenticated, service_role;

-- Report: expect 91 lines
SELECT cardinality(public.gpsl_rumour_idle_templates()) AS template_count;
