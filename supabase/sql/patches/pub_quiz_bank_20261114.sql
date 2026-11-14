-- Twenty draft pub quizzes for later use.
-- Round 2 is the picture round. Round 4 is the song round.
-- Picture and song answers are filled in. The file is left empty on purpose:
-- a commercial clip or an official photo cannot be stored here.
-- The correct option is the clip or the crop to attach.
-- Safe re-run: stops if Bank 01 is already there.

DO $quiz$
DECLARE
  v_meta record;
  v_round_id bigint;
  v_quiz_id bigint;
  v_bad text;
  v_n int;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.gpsl_pub_quiz WHERE title = 'Bank 01 — World Cup'
  ) THEN
    RAISE EXCEPTION 'Quiz bank already loaded';
  END IF;

  CREATE TEMP TABLE qmeta (
    quiz_no int PRIMARY KEY,
    title text NOT NULL,
    r1 text NOT NULL,
    r3 text NOT NULL,
    r5 text NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO qmeta (quiz_no, title, r1, r3, r5) VALUES
    (1,  'Bank 01 — World Cup', 'World Cup', 'Around the world', 'World Cup nights'),
    (2,  'Bank 02 — Premier League', 'Premier League', 'Science', 'Premier League clubs'),
    (3,  'Bank 03 — Champions League', 'Champions League', 'History', 'European clubs'),
    (4,  'Bank 04 — England', 'England', 'Film and TV', 'Home nations'),
    (5,  'Bank 05 — Euros', 'European Championship', 'Nature', 'Goalscorers'),
    (6,  'Bank 06 — South America', 'South America', 'Music on paper', 'Brazil and Argentina'),
    (7,  'Bank 07 — Records', 'Records to 2022', 'Space', 'Famous goals'),
    (8,  'Bank 08 — Managers', 'Managers', 'Food and drink', 'Words of the game'),
    (9,  'Bank 09 — Stadiums', 'Stadiums and cities', 'Art and books', 'Nicknames'),
    (10, 'Bank 10 — Finals', 'Finals', 'Inventions', 'World Cup hosts'),
    (11, 'Bank 11 — The 1990s', '1990s football', 'Capital cities', '1990s Premier League'),
    (12, 'Bank 12 — The 2000s', '2000s football', 'Languages', '2000s Europe'),
    (13, 'Bank 13 — Legends', 'Legends', 'The human body', 'Shirt numbers'),
    (14, 'Bank 14 — The laws', 'Laws of the game', 'Earth', 'The pitch'),
    (15, 'Bank 15 — Africa', 'African football', 'Animals', 'Africa'),
    (16, 'Bank 16 — Derbies', 'Derbies', 'British life', 'Rival clubs'),
    (17, 'Bank 17 — Asia', 'Asian football', 'Mountains and seas', 'Japan and South Korea'),
    (18, 'Bank 18 — Internationals', 'Internationals', 'Countries', 'Tournament finals'),
    (19, 'Bank 19 — Mixed football', 'Mixed football', 'Mixed knowledge', 'More football'),
    (20, 'Bank 20 — Names and numbers', 'Who did it', 'Numbers', 'Name the club');

  CREATE TEMP TABLE qseed (
    quiz_no int NOT NULL,
    round_no int NOT NULL,
    q_no int NOT NULL,
    prompt text NOT NULL,
    a text NOT NULL,
    b text NOT NULL,
    c text NOT NULL,
    correct char(1) NOT NULL,
    PRIMARY KEY (quiz_no, round_no, q_no)
  ) ON COMMIT DROP;

  INSERT INTO qseed (quiz_no, round_no, q_no, prompt, a, b, c, correct) VALUES
    (1,1,1,'Which country won the 2022 World Cup?','France','Argentina','Brazil','b'),
    (1,1,2,'Who scored a hat-trick in the 1966 World Cup final?','Bobby Charlton','Geoff Hurst','Bobby Moore','b'),
    (1,1,3,'How many World Cups had Brazil won by the end of 2022?','4','5','6','b'),
    (1,1,4,'Which country hosted the 2014 World Cup?','Brazil','South Africa','Russia','a'),
    (1,1,5,'Which country won the 2018 World Cup?','Croatia','France','Belgium','b'),
    (1,1,6,'Which country won the first World Cup in 1930?','Uruguay','Brazil','Italy','a'),
    (1,1,7,'Who was sent off for a headbutt in the 2006 final?','Marco Materazzi','Zinedine Zidane','Patrick Vieira','b'),
    (1,1,8,'Which country won the 2010 World Cup?','Spain','Netherlands','Germany','a'),
    (1,1,9,'Who captained Argentina to the 1986 World Cup?','Diego Maradona','Lionel Messi','Daniel Passarella','a'),
    (1,1,10,'Which country won the 2014 World Cup?','Argentina','Germany','Brazil','b'),
    (1,2,1,'Which club''s badge is this?','Liverpool','Everton','Chelsea','a'),
    (1,2,2,'Whose face is this?','Cristiano Ronaldo','Lionel Messi','Neymar','b'),
    (1,2,3,'Which stadium is this?','Old Trafford','Anfield','Wembley','c'),
    (1,2,4,'Which match is this?','1966 World Cup final','2014 World Cup final','Euro 2020 final','a'),
    (1,2,5,'Which club''s badge is this?','Real Madrid','Barcelona','Atletico Madrid','b'),
    (1,2,6,'Whose face is this?','Maradona','Zidane','Pele','c'),
    (1,2,7,'Which stadium is this?','Camp Nou','Bernabeu','San Siro','a'),
    (1,2,8,'Which match is this?','Baggio miss, 1994','Hand of God, 1986','Gotze final, 2014','b'),
    (1,2,9,'Which club''s badge is this?','Arsenal','Chelsea','Manchester United','c'),
    (1,2,10,'Whose face is this?','David Beckham','Steven Gerrard','Frank Lampard','a'),
    (1,3,1,'What is the capital of Australia?','Sydney','Canberra','Melbourne','b'),
    (1,3,2,'Which is the largest ocean?','Atlantic','Indian','Pacific','c'),
    (1,3,3,'How many continents are there in the usual count?','5','6','7','c'),
    (1,3,4,'Which country has the maple leaf on its flag?','Canada','Switzerland','Japan','a'),
    (1,3,5,'What is the capital of Canada?','Toronto','Ottawa','Vancouver','b'),
    (1,3,6,'Which currency is used in Japan?','Won','Yuan','Yen','c'),
    (1,3,7,'What is the capital of Spain?','Barcelona','Madrid','Seville','b'),
    (1,3,8,'Which desert is the largest hot desert?','Gobi','Kalahari','Sahara','c'),
    (1,3,9,'What is the capital of Italy?','Milan','Rome','Naples','b'),
    (1,3,10,'Which country is Paris the capital of?','Belgium','France','Switzerland','b'),
    (1,4,1,'Name this song.','We Will Rock You','We Are the Champions','Bohemian Rhapsody','b'),
    (1,4,2,'Name this song.','Sweet Caroline','Sweet Home Alabama','Sweet Child O'' Mine','a'),
    (1,4,3,'Name this song.','Yellow','Clocks','Seven Nation Army','c'),
    (1,4,4,'Name this song.','Don''t Look Back in Anger','Wonderwall','Champagne Supernova','b'),
    (1,4,5,'Name this song.','Hey Jude','Let It Be','Yesterday','a'),
    (1,4,6,'Name this song.','Somebody Told Me','When You Were Young','Mr. Brightside','c'),
    (1,4,7,'Name this song.','Any Way You Want It','Don''t Stop Believin''','Separate Ways','b'),
    (1,4,8,'Name this song.','Livin'' on a Prayer','Bad Name','Wanted Dead or Alive','a'),
    (1,4,9,'Name this song.','We Are the Champions','Bohemian Rhapsody','We Will Rock You','c'),
    (1,4,10,'Name this song.','World in Motion','Three Lions','Vindaloo','b'),
    (1,5,1,'Who won the Golden Boot at the 2022 World Cup?','Messi','Mbappe','Kane','b'),
    (1,5,2,'Which country hosted the 2018 World Cup?','Qatar','Russia','Brazil','b'),
    (1,5,3,'Who scored the only goal of the 2014 World Cup final?','Mario Gotze','Miroslav Klose','Thomas Muller','a'),
    (1,5,4,'Which country did England beat in the 1966 final?','Portugal','Argentina','West Germany','c'),
    (1,5,5,'Who won the 1998 World Cup?','Brazil','France','Germany','b'),
    (1,5,6,'Which country hosted the 2002 World Cup with Japan?','China','South Korea','Australia','b'),
    (1,5,7,'Who missed a penalty in the 1994 World Cup final shootout?','Baresi','Baggio','Maldini','b'),
    (1,5,8,'Which country won the 2006 World Cup?','France','Italy','Germany','b'),
    (1,5,9,'How many World Cups had Italy won by the end of 2022?','3','4','5','b'),
    (1,5,10,'Which country won the 1958 World Cup?','Sweden','Brazil','West Germany','b'),
    (2,1,1,'Who won the first Premier League, in 1992-93?','Manchester United','Leeds','Blackburn','a'),
    (2,1,2,'Who went unbeaten through the 2003-04 Premier League?','Arsenal','Chelsea','Manchester United','a'),
    (2,1,3,'Who won the Premier League in 2015-16?','Tottenham','Leicester','Arsenal','b'),
    (2,1,4,'How many clubs are in the Premier League?','18','20','22','b'),
    (2,1,5,'Who had scored the most Premier League goals by the end of 2024-25?','Alan Shearer','Harry Kane','Wayne Rooney','a'),
    (2,1,6,'Whose last-day goal won Manchester City the 2011-12 title?','Yaya Toure','Sergio Aguero','Edin Dzeko','b'),
    (2,1,7,'Who won the 2023-24 Premier League?','Arsenal','Manchester City','Liverpool','b'),
    (2,1,8,'Who managed Manchester United to the 1999 treble?','Alex Ferguson','David Moyes','Jose Mourinho','a'),
    (2,1,9,'Who won the 2019-20 Premier League?','Manchester City','Liverpool','Chelsea','b'),
    (2,1,10,'Who won the 1994-95 Premier League?','Blackburn','Manchester United','Newcastle','a'),
    (2,2,1,'Which club''s badge is this?','Tottenham','Arsenal','West Ham','a'),
    (2,2,2,'Whose face is this?','Patrick Vieira','Thierry Henry','Dennis Bergkamp','b'),
    (2,2,3,'Which stadium is this?','Emirates Stadium','Etihad Stadium','Stamford Bridge','a'),
    (2,2,4,'Which match is this?','Aguero winner, 2012','Gerrard slip, 2014','Drogba header, 2012','a'),
    (2,2,5,'Which club''s badge is this?','Newcastle','Chelsea','Everton','b'),
    (2,2,6,'Whose face is this?','Paul Scholes','Wayne Rooney','Ryan Giggs','c'),
    (2,2,7,'Which stadium is this?','Anfield','Goodison Park','Old Trafford','a'),
    (2,2,8,'Which match is this?','Invincibles parade','Gerrard slip, 2014','Kompany goal, 2012','b'),
    (2,2,9,'Which club''s badge is this?','Manchester City','Leeds','Aston Villa','a'),
    (2,2,10,'Whose face is this?','Jose Mourinho','Jurgen Klopp','Pep Guardiola','b'),
    (2,3,1,'How many planets are in the solar system?','7','8','9','b'),
    (2,3,2,'What is H on the periodic table?','Helium','Hydrogen','Hafnium','b'),
    (2,3,3,'At sea level, water boils at how many degrees Celsius?','90','100','110','b'),
    (2,3,4,'Which gas do plants mainly take in to photosynthesise?','Oxygen','Nitrogen','Carbon dioxide','c'),
    (2,3,5,'How many bones are in a typical adult human body?','106','206','306','b'),
    (2,3,6,'Which star is closest to Earth?','Proxima Centauri','The Sun','Sirius','b'),
    (2,3,7,'What is the hardest natural substance?','Steel','Diamond','Quartz','b'),
    (2,3,8,'Which blood cells mainly fight infection?','Red cells','White cells','Platelets','b'),
    (2,3,9,'Which force pulls objects towards Earth?','Magnetism','Gravity','Friction','b'),
    (2,3,10,'How many chambers does the human heart have?','2','3','4','c'),
    (2,4,1,'Name this song.','Bohemian Rhapsody','Don''t Stop Me Now','Somebody to Love','a'),
    (2,4,2,'Name this song.','Thriller','Billie Jean','Beat It','b'),
    (2,4,3,'Name this song.','Smells Like Teen Spirit','Come as You Are','Lithium','a'),
    (2,4,4,'Name this song.','Rolling in the Deep','Someone Like You','Set Fire to the Rain','c'),
    (2,4,5,'Name this song.','Shape of You','Perfect','Thinking Out Loud','a'),
    (2,4,6,'Name this song.','Starboy','Blinding Lights','Save Your Tears','b'),
    (2,4,7,'Name this song.','Uptown Funk','24K Magic','Treasure','a'),
    (2,4,8,'Name this song.','Can''t Stop the Feeling','Get Lucky','Happy','c'),
    (2,4,9,'Name this song.','Blank Space','Shake It Off','Bad Blood','b'),
    (2,4,10,'Name this song.','Bad Guy','Therefore I Am','bury a friend','a'),
    (2,5,1,'Which club plays at Anfield?','Everton','Liverpool','Tranmere','b'),
    (2,5,2,'Which club plays at Old Trafford?','Manchester City','Manchester United','Bolton','b'),
    (2,5,3,'Which club is nicknamed the Toffees?','Everton','Liverpool','Burnley','a'),
    (2,5,4,'Who managed Leicester to the 2015-16 title?','Jose Mourinho','Claudio Ranieri','Nigel Pearson','b'),
    (2,5,5,'Which London club plays at Stamford Bridge?','Chelsea','Fulham','QPR','a'),
    (2,5,6,'Which club is nicknamed the Red Devils?','Manchester United','Liverpool','Arsenal','a'),
    (2,5,7,'Which club plays at the Etihad Stadium?','Manchester City','Manchester United','Burnley','a'),
    (2,5,8,'Who is Arsenal''s record Premier League goalscorer?','Thierry Henry','Ian Wright','Dennis Bergkamp','a'),
    (2,5,9,'Who beat Manchester City in the 2013 FA Cup final?','Wigan','Chelsea','Hull','a'),
    (2,5,10,'Which club is nicknamed the Gunners?','Arsenal','Tottenham','West Ham','a');
  -- END SEED

  SELECT s.prompt INTO v_bad
  FROM qseed s
  WHERE length(s.prompt) > 180
     OR length(s.a) > 40
     OR length(s.b) > 40
     OR length(s.c) > 40
     OR s.correct NOT IN ('a', 'b', 'c')
     OR s.round_no NOT BETWEEN 1 AND 5
     OR s.q_no NOT BETWEEN 1 AND 10
  LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Bad question: %', v_bad;
  END IF;

  SELECT count(*) INTO v_n FROM qseed;
  IF v_n <> 1000 THEN
    RAISE EXCEPTION 'Expected 1000 questions, got %', v_n;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM qseed
    GROUP BY quiz_no, round_no
    HAVING count(*) <> 10
  ) THEN
    RAISE EXCEPTION 'A round does not have 10 questions';
  END IF;

  FOR v_meta IN SELECT * FROM qmeta ORDER BY quiz_no LOOP
    INSERT INTO public.gpsl_pub_quiz (title)
    VALUES (v_meta.title)
    RETURNING id INTO v_quiz_id;

    INSERT INTO public.gpsl_pub_quiz_round (quiz_id, round_no, title, kind, answer_seconds)
    VALUES (v_quiz_id, 1, v_meta.r1, 'text', 12)
    RETURNING id INTO v_round_id;
    INSERT INTO public.gpsl_pub_quiz_question (round_id, q_no, prompt, option_a, option_b, option_c, correct)
    SELECT v_round_id, s.q_no, s.prompt, s.a, s.b, s.c, s.correct
    FROM qseed s
    WHERE s.quiz_no = v_meta.quiz_no AND s.round_no = 1;

    INSERT INTO public.gpsl_pub_quiz_round (quiz_id, round_no, title, kind, answer_seconds)
    VALUES (v_quiz_id, 2, 'Picture round', 'picture', 14)
    RETURNING id INTO v_round_id;
    INSERT INTO public.gpsl_pub_quiz_question (round_id, q_no, prompt, option_a, option_b, option_c, correct)
    SELECT v_round_id, s.q_no, s.prompt, s.a, s.b, s.c, s.correct
    FROM qseed s
    WHERE s.quiz_no = v_meta.quiz_no AND s.round_no = 2;

    INSERT INTO public.gpsl_pub_quiz_round (quiz_id, round_no, title, kind, answer_seconds)
    VALUES (v_quiz_id, 3, v_meta.r3, 'text', 12)
    RETURNING id INTO v_round_id;
    INSERT INTO public.gpsl_pub_quiz_question (round_id, q_no, prompt, option_a, option_b, option_c, correct)
    SELECT v_round_id, s.q_no, s.prompt, s.a, s.b, s.c, s.correct
    FROM qseed s
    WHERE s.quiz_no = v_meta.quiz_no AND s.round_no = 3;

    INSERT INTO public.gpsl_pub_quiz_round (quiz_id, round_no, title, kind, answer_seconds)
    VALUES (v_quiz_id, 4, 'Songs', 'song', 14)
    RETURNING id INTO v_round_id;
    INSERT INTO public.gpsl_pub_quiz_question (round_id, q_no, prompt, option_a, option_b, option_c, correct)
    SELECT v_round_id, s.q_no, s.prompt, s.a, s.b, s.c, s.correct
    FROM qseed s
    WHERE s.quiz_no = v_meta.quiz_no AND s.round_no = 4;

    INSERT INTO public.gpsl_pub_quiz_round (quiz_id, round_no, title, kind, answer_seconds)
    VALUES (v_quiz_id, 5, v_meta.r5, 'text', 12)
    RETURNING id INTO v_round_id;
    INSERT INTO public.gpsl_pub_quiz_question (round_id, q_no, prompt, option_a, option_b, option_c, correct)
    SELECT v_round_id, s.q_no, s.prompt, s.a, s.b, s.c, s.correct
    FROM qseed s
    WHERE s.quiz_no = v_meta.quiz_no AND s.round_no = 5;
  END LOOP;
END;
$quiz$;

SELECT title,
  (SELECT count(*) FROM public.gpsl_pub_quiz_round r WHERE r.quiz_id = q.id) AS rounds,
  (SELECT count(*) FROM public.gpsl_pub_quiz_question qq
     JOIN public.gpsl_pub_quiz_round r ON r.id = qq.round_id
    WHERE r.quiz_id = q.id AND btrim(qq.prompt) <> '') AS questions
FROM public.gpsl_pub_quiz q
WHERE q.title LIKE 'Bank %'
ORDER BY q.title;
