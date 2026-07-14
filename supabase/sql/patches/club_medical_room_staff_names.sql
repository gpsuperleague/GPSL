-- =============================================================================
-- Medical staff names — large name pools (hundreds of first + surnames)
-- Safe re-run. Replaces medical_staff_random_name().
-- =============================================================================

CREATE OR REPLACE FUNCTION public.medical_staff_random_name(p_gender text)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_gender text := lower(coalesce(nullif(btrim(p_gender), ''), 'male'));
  v_first text;
  v_last text;
  v_male text[] := ARRAY[
    'James','John','Robert','Michael','William','David','Richard','Joseph','Thomas','Charles',
    'Christopher','Daniel','Matthew','Anthony','Mark','Donald','Steven','Paul','Andrew','Joshua',
    'Kenneth','Kevin','Brian','George','Timothy','Ronald','Edward','Jason','Jeffrey','Ryan',
    'Jacob','Gary','Nicholas','Eric','Jonathan','Stephen','Larry','Justin','Scott','Brandon',
    'Benjamin','Samuel','Raymond','Gregory','Frank','Alexander','Patrick','Jack','Dennis','Jerry',
    'Tyler','Aaron','Jose','Adam','Nathan','Henry','Douglas','Zachary','Peter','Kyle',
    'Noah','Ethan','Jeremy','Walter','Christian','Keith','Roger','Terry','Austin','Sean',
    'Gerald','Carl','Harold','Dylan','Arthur','Lawrence','Jesse','Bryan','Billy','Bruce',
    'Gabriel','Joe','Logan','Alan','Juan','Wayne','Roy','Ralph','Randy','Eugene',
    'Vincent','Russell','Louis','Philip','Bobby','Johnny','Bradley','Albert','Harry','Fred',
    'Wayne','Howard','Oscar','Martin','Victor','Leonard','Norman','Melvin','Clyde','Glen',
    'Oliver','Harry','George','Leo','Arthur','Oscar','Theo','Freddie','Archie','Henry',
    'Alfie','Charlie','Tommy','Finn','Lucas','Mason','Jackson','Aiden','Carter','Owen',
    'Caleb','Hunter','Isaiah','Connor','Eli','Landon','Adrian','Colton','Julian','Levi',
    'Xavier','Dominic','Jaxon','Carson','Chase','Blake','Max','Miles','Asher','Grayson',
    'Ryder','Bentley','Jace','Kayden','Brody','Brayden','Camden','Parker','Sawyer','Tristan',
    'Nolan','Cole','Diego','Ivan','Marcus','Felix','Hugo','Roman','Luca','Enzo',
    'Marco','Antonio','Rafael','Mateo','Santiago','Sebastian','Andre','Pierre','Louis','Emile',
    'Klaus','Stefan','Lukas','Niklas','Jonas','Tobias','Sven','Erik','Anders','Bjorn',
    'Hassan','Omar','Yusuf','Ibrahim','Ahmed','Karim','Samir','Nabil','Rami','Tariq',
    'Kenji','Hiroshi','Takeshi','Ravi','Arjun','Vikram','Anil','Raj','Sanjay','Deepak',
    'Wei','Chen','Jun','Hao','Minh','Duc','Bao','Kofi','Kwame','Jabari',
    'Callum','Rhys','Ewan','Fraser','Hamish','Angus','Duncan','Malcolm','Alastair','Iain',
    'Declan','Cian','Oisin','Padraig','Cormac','Finnian','Liam','Sean','Niall','Eoin',
    'Gareth','Owen','Dafydd','Ieuan','Rhodri','Trystan','Sion','Macsen','Elis','Osian',
    'Paolo','Giovanni','Lorenzo','Francesco','Alessandro','Matteo','Nicolo','Davide','Simone','Andrea',
    'Jorge','Carlos','Miguel','Pedro','Fernando','Ricardo','Eduardo','Manuel','Alvaro','Pablo',
    'Jan','Piotr','Tomasz','Krzysztof','Marek','Adam','Bartosz','Michal','Kamil','Lukasz',
    'Dmitri','Ivan','Alexei','Sergei','Nikolai','Yuri','Boris','Viktor','Oleg','Pavel'
  ];
  v_female text[] := ARRAY[
    'Mary','Patricia','Jennifer','Linda','Elizabeth','Barbara','Susan','Jessica','Sarah','Karen',
    'Nancy','Lisa','Betty','Margaret','Sandra','Ashley','Kimberly','Emily','Donna','Michelle',
    'Dorothy','Carol','Amanda','Melissa','Deborah','Stephanie','Rebecca','Sharon','Laura','Cynthia',
    'Kathleen','Amy','Angela','Shirley','Anna','Brenda','Pamela','Emma','Nicole','Helen',
    'Samantha','Katherine','Christine','Debra','Rachel','Carolyn','Janet','Catherine','Maria','Heather',
    'Diane','Ruth','Julie','Olivia','Joyce','Virginia','Victoria','Kelly','Lauren','Christina',
    'Joan','Evelyn','Judith','Andrea','Hannah','Megan','Cheryl','Jacqueline','Martha','Madison',
    'Teresa','Gloria','Sara','Janice','Ann','Kathryn','Abigail','Sophia','Frances','Jean',
    'Alice','Judy','Isabella','Julia','Grace','Denise','Amber','Doris','Marilyn','Danielle',
    'Beverly','Charlotte','Natalie','Theresa','Diana','Brittany','Marie','Kayla','Alexis','Lori',
    'Olivia','Amelia','Isla','Ava','Mia','Lily','Ella','Freya','Sophie','Grace',
    'Evie','Florence','Poppy','Ivy','Willow','Rosie','Daisy','Elsie','Phoebe','Ruby',
    'Chloe','Zoe','Scarlett','Layla','Penelope','Riley','Aria','Nora','Hazel','Violet',
    'Aurora','Savannah','Audrey','Brooklyn','Bella','Claire','Skylar','Lucy','Paisley','Everly',
    'Stella','Ellie','Maya','Naomi','Elena','Gabriella','Ariana','Allison','Hailey','Gianna',
    'Serenity','Camila','Arianna','Sarah','Madelyn','Cora','Kaylee','Luna','Piper','Quinn',
    'Fatima','Aisha','Layla','Noor','Yasmin','Amira','Leila','Salma','Hana','Zahra',
    'Yuki','Akiko','Mei','Hana','Sakura','Priya','Ananya','Isha','Neha','Kavita',
    'Sofia','Valentina','Isabella','Lucia','Carmen','Rosa','Elena','Marta','Ana','Ines',
    'Giulia','Chiara','Francesca','Alessia','Martina','Sara','Elisa','Valentina','Bianca','Greta',
    'Ingrid','Astrid','Freja','Maja','Ebba','Linnea','Saga','Alva','Elsa','Nora',
    'Siobhan','Aoife','Niamh','Ciara','Orla','Saoirse','Aisling','Maeve','Roisin','Grainne',
    'Ffion','Seren','Lowri','Catrin','Eira','Nia','Rhiannon','Bronwen','Gwen','Aneirin',
    'Amina','Zara','Sana','Imaan','Maryam','Nadia','Rania','Dina','Lina','Maya',
    'Thuy','Lan','Mai','Hoa','Binh','Siti','Putri','Ayu','Dewi','Rina',
    'Olga','Natalia','Irina','Ekaterina','Anastasia','Svetlana','Tatiana','Yelena','Polina','Daria',
    'Agnieszka','Katarzyna','Magdalena','Joanna','Monika','Ewa','Barbara','Aleksandra','Paulina','Karolina',
    'Claire','Louise','Nicola','Joanne','Helen','Fiona','Morag','Kirsty','Shona','Eilidh'
  ];
  v_surnames text[] := ARRAY[
    'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez',
    'Hernandez','Lopez','Gonzalez','Wilson','Anderson','Thomas','Taylor','Moore','Jackson','Martin',
    'Lee','Perez','Thompson','White','Harris','Sanchez','Clark','Ramirez','Lewis','Robinson',
    'Walker','Young','Allen','King','Wright','Scott','Torres','Nguyen','Hill','Flores',
    'Green','Adams','Nelson','Baker','Hall','Rivera','Campbell','Mitchell','Carter','Roberts',
    'Gomez','Phillips','Evans','Turner','Diaz','Parker','Cruz','Edwards','Collins','Reyes',
    'Stewart','Morris','Morales','Murphy','Cook','Rogers','Gutierrez','Ortiz','Morgan','Cooper',
    'Peterson','Bailey','Reed','Kelly','Howard','Ramos','Kim','Cox','Ward','Richardson',
    'Watson','Brooks','Chavez','Wood','James','Bennett','Gray','Mendoza','Ruiz','Hughes',
    'Price','Alvarez','Castillo','Sanders','Patel','Myers','Long','Ross','Foster','Jimenez',
    'Powell','Jenkins','Perry','Russell','Sullivan','Bell','Coleman','Butler','Henderson','Barnes',
    'Gonzales','Fisher','Vasquez','Simmons','Romero','Jordan','Patterson','Alexander','Hamilton','Graham',
    'Reynolds','Griffin','Wallace','Moreno','West','Cole','Hayes','Bryant','Herrera','Gibson',
    'Ellis','Tran','Medina','Aguilar','Stevens','Murray','Ford','Castro','Marshall','Owens',
    'Harrison','Fernandez','McDonald','Woods','Washington','Kennedy','Wells','Vargas','Henry','Chen',
    'Freeman','Webb','Tucker','Guzman','Burns','Crawford','Olson','Simpson','Porter','Hunter',
    'Gordon','Mendez','Silva','Shaw','Snyder','Mason','Dixon','Munoz','Hunt','Hicks',
    'Holmes','Palmer','Wagner','Black','Robertson','Boyd','Rose','Stone','Salazar','Fox',
    'Warren','Mills','Meyer','Rice','Schmidt','Garza','Daniels','Ferguson','Nichols','Stephens',
    'Soto','Weaver','Ryan','Gardner','Payne','Grant','Dunn','Kelley','Spencer','Hawkins',
    'Arnold','Pierce','Vazquez','Hansen','Peters','Santos','Hart','Bradley','Knight','Elliott',
    'Cunningham','Duncan','Armstrong','Hudson','Carroll','Lane','Riley','Andrews','Alvarado','Ray',
    'Delgado','Berry','Perkins','Hoffman','Johnston','Matthews','Contreras','Vargas','Walsh','O''Brien',
    'O''Connor','O''Neill','O''Sullivan','O''Reilly','Fitzgerald','Fitzpatrick','Gallagher','Doherty','Byrne','Doyle',
    'MacLeod','MacDonald','MacKenzie','MacKay','Fraser','Stewart','Cameron','Gordon','Ross','Grant',
    'Hughes','Davies','Evans','Roberts','Griffiths','Lewis','Morgan','Price','Jenkins','Owen',
    'Singh','Kaur','Sharma','Khan','Ahmed','Ali','Hassan','Rahman','Chowdhury','Begum',
    'Wang','Li','Zhang','Liu','Yang','Huang','Zhao','Wu','Zhou','Xu',
    'Kim','Park','Choi','Jung','Kang','Cho','Yoon','Jang','Lim','Han',
    'Tanaka','Suzuki','Yamamoto','Watanabe','Ito','Nakamura','Kobayashi','Saito','Kato','Yoshida',
    'Novak','Horvat','Kowalski','Nowak','Wisniewski','Wojcik','Kamiński','Lewandowski','Zielinski','Szymanski',
    'Ivanov','Petrov','Sidorov','Popov','Volkov','Sokolov','Lebedev','Kozlov','Novikov','Morozov',
    'Berg','Hansen','Johansen','Olsen','Larsen','Andersen','Nilsen','Pedersen','Kristensen','Jensen',
    'Mueller','Schmidt','Schneider','Fischer','Weber','Wagner','Becker','Hoffmann','Schaefer','Koch',
    'Rossi','Russo','Ferrari','Esposito','Bianchi','Romano','Colombo','Ricci','Marino','Greco',
    'Silva','Santos','Ferreira','Pereira','Oliveira','Costa','Rodrigues','Martins','Jesus','Sousa',
    'Dubois','Laurent','Lefebvre','Moreau','Simon','Michel','Garcia','Bernard','Petit','Robert',
    'Baker','Turner','Collins','Reed','Foster','Bennett','Palmer','Hayes','Barrett','Nash',
    'Quinn','Blake','Fox','Hunt','Marsh','Frost','Snow','Shore','Field','Brook',
    'Atkinson','Barker','Baxter','Bolton','Booth','Brennan','Buckley','Burgess','Carr','Chambers',
    'Clayton','Coleman','Connolly','Curtis','Dalton','Daniels','Dawson','Dixon','Duffy','Farrell',
    'Fleming','Flynn','Forster','Gibbs','Gilbert','Gill','Goodwin','Greenwood','Hale','Hancock',
    'Hardy','Hartley','Hewitt','Higgins','Hobbs','Hodgson','Holden','Holland','Holt','Hooper',
    'Hope','Horton','Howell','Humphreys','Hutchinson','Ingram','Jarvis','Jennings','Jordan','Joyce',
    'Kane','Kerr','Kirk','Lamb','Lambert','Lawson','Leach','Lester','Lindsay','Little',
    'Lloyd','Lowe','Lynch','Manning','Marsden','Marshall','May','Mellor','Metcalfe','Middleton',
    'Miles','Millar','Milne','Moon','Morton','Moss','Neal','Nicholson','Nolan','Norman',
    'Norris','North','Norton','Nunn','Oakley','Osborne','Page','Paine','Parsons','Peacock',
    'Pearce','Peck','Pollard','Poole','Potter','Power','Pratt','Pritchard','Proctor','Pugh',
    'Radford','Rae','Randall','Read','Reeves','Rhodes','Richards','Richmond','Riley','Robson',
    'Rowe','Rowley','Sanderson','Savage','Sayers','Sheldon','Shepherd','Short','Simmons','Slater',
    'Smart','Steele','Stephenson','Stevenson','Stokes','Storey','Street','Summers','Sutton','Swift',
    'Sykes','Tait','Tate','Thorpe','Todd','Tomlinson','Townsend','Tucker','Vaughan','Wade',
    'Walker','Wall','Walton','Waters','Watkins','Watts','Weeks','Welch','Weston','Wheeler',
    'Whitaker','Whitehead','Whittaker','Wilkins','Wilkinson','Willis','Winter','Woodward','Worthington','Yates'
  ];
BEGIN
  IF v_gender = 'female' THEN
    v_first := v_female[1 + floor(random() * array_length(v_female, 1))::int];
  ELSE
    v_first := v_male[1 + floor(random() * array_length(v_male, 1))::int];
  END IF;
  v_last := v_surnames[1 + floor(random() * array_length(v_surnames, 1))::int];
  RETURN v_first || ' ' || v_last;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_staff_random_name(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
