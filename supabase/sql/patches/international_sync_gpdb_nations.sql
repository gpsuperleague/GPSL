      -- =============================================================================
      -- Sync GPDB Players.Nation labels into international_nations (nation select / pool)
      -- Run after competition_international.sql + international_callup_gpdb.sql
      -- Safe re-run. Then: SELECT public.international_sync_gpdb_nations();
      -- =============================================================================

      CREATE TABLE IF NOT EXISTS public.international_nation_catalog (
        code text PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
        flag_emoji text NOT NULL DEFAULT '🏳️',
        flagcdn_slug text,
        aliases text[] NOT NULL DEFAULT '{}'::text[]
      );

      TRUNCATE public.international_nation_catalog;

      INSERT INTO public.international_nation_catalog (code, flag_emoji, flagcdn_slug, aliases)
      VALUES
        ('ABW', '🇦🇼', 'aw', ARRAY['ABW', 'Aruba']::text[]),
('AFG', '🇦🇫', 'af', ARRAY['AFG', 'Afghanistan', 'Islamic Republic of Afghanistan']::text[]),
('AGO', '🇦🇴', 'ao', ARRAY['AGO', 'Angola', 'Republic of Angola']::text[]),
('AIA', '🇦🇮', 'ai', ARRAY['AIA', 'Anguilla']::text[]),
('ALA', '🇦🇽', 'ax', ARRAY['ALA', 'Åland Islands']::text[]),
('ALB', '🇦🇱', 'al', ARRAY['ALB', 'Albania', 'Republic of Albania']::text[]),
('ALG', '🇩🇿', 'dz', ARRAY['ALG', 'Algeria', 'People''s Democratic Republic of Algeria']::text[]),
('AND', '🇦🇩', 'ad', ARRAY['AND', 'Andorra', 'Principality of Andorra']::text[]),
('ARE', '🇦🇪', 'ae', ARRAY['ARE', 'United Arab Emirates']::text[]),
('ARG', '🇦🇷', 'ar', ARRAY['ARG', 'Argentina', 'Argentine Republic']::text[]),
('ARM', '🇦🇲', 'am', ARRAY['ARM', 'Armenia', 'Republic of Armenia']::text[]),
('ASM', '🇦🇸', 'as', ARRAY['ASM', 'American Samoa']::text[]),
('ATA', '🇦🇶', 'aq', ARRAY['ATA', 'Antarctica']::text[]),
('ATF', '🇹🇫', 'tf', ARRAY['ATF', 'French Southern Territories']::text[]),
('ATG', '🇦🇬', 'ag', ARRAY['ATG', 'Antigua and Barbuda']::text[]),
('AUS', '🇦🇺', 'au', ARRAY['AUS', 'Australia']::text[]),
('AUT', '🇦🇹', 'at', ARRAY['AUT', 'Austria', 'Republic of Austria']::text[]),
('AZE', '🇦🇿', 'az', ARRAY['AZE', 'Azerbaijan', 'Republic of Azerbaijan']::text[]),
('BDI', '🇧🇮', 'bi', ARRAY['BDI', 'Burundi', 'Republic of Burundi']::text[]),
('BEL', '🇧🇪', 'be', ARRAY['BEL', 'Belgium', 'Kingdom of Belgium']::text[]),
('BEN', '🇧🇯', 'bj', ARRAY['BEN', 'Benin', 'Republic of Benin']::text[]),
('BES', '🇧🇶', 'bq', ARRAY['BES', 'Bonaire, Sint Eustatius and Saba']::text[]),
('BFA', '🇧🇫', 'bf', ARRAY['BFA', 'Burkina Faso']::text[]),
('BGD', '🇧🇩', 'bd', ARRAY['BGD', 'Bangladesh', 'People''s Republic of Bangladesh']::text[]),
('BGR', '🇧🇬', 'bg', ARRAY['BGR', 'Bulgaria', 'Republic of Bulgaria']::text[]),
('BHR', '🇧🇭', 'bh', ARRAY['BHR', 'Bahrain', 'Kingdom of Bahrain']::text[]),
('BHS', '🇧🇸', 'bs', ARRAY['BHS', 'Bahamas', 'Commonwealth of the Bahamas']::text[]),
('BIH', '🇧🇦', 'ba', ARRAY['BIH', 'Bosnia and Herzegovina', 'Republic of Bosnia and Herzegovina']::text[]),
('BLM', '🇧🇱', 'bl', ARRAY['BLM', 'Saint Barthélemy']::text[]),
('BLR', '🇧🇾', 'by', ARRAY['BLR', 'Belarus', 'Republic of Belarus']::text[]),
('BLZ', '🇧🇿', 'bz', ARRAY['BLZ', 'Belize']::text[]),
('BMU', '🇧🇲', 'bm', ARRAY['BMU', 'Bermuda']::text[]),
('BOL', '🇧🇴', 'bo', ARRAY['BOL', 'Bolivia', 'Bolivia, Plurinational State of', 'Plurinational State of Bolivia']::text[]),
('BRA', '🇧🇷', 'br', ARRAY['BRA', 'Brazil', 'Federative Republic of Brazil']::text[]),
('BRB', '🇧🇧', 'bb', ARRAY['BRB', 'Barbados']::text[]),
('BRN', '🇧🇳', 'bn', ARRAY['BRN', 'Brunei Darussalam']::text[]),
('BRU', '🇧🇳', 'bn', ARRAY['BRU', 'Brunei', 'Brunei Darussalam']::text[]),
('BTN', '🇧🇹', 'bt', ARRAY['BTN', 'Bhutan', 'Kingdom of Bhutan']::text[]),
('BVT', '🇧🇻', 'bv', ARRAY['BVT', 'Bouvet Island']::text[]),
('BWA', '🇧🇼', 'bw', ARRAY['BWA', 'Botswana', 'Republic of Botswana']::text[]),
('CAF', '🇨🇫', 'cf', ARRAY['CAF', 'Central African Republic']::text[]),
('CAM', '🇰🇭', 'kh', ARRAY['CAM', 'Cambodia', 'Kingdom of Cambodia']::text[]),
('CAN', '🇨🇦', 'ca', ARRAY['CAN', 'Canada']::text[]),
('CCK', '🇨🇨', 'cc', ARRAY['CCK', 'Cocos (Keeling) Islands']::text[]),
('CGO', '🇨🇬', 'cg', ARRAY['CGO', 'Congo', 'Congo Republic', 'Republic of the Congo']::text[]),
('CHI', '🇨🇱', 'cl', ARRAY['CHI', 'Chile', 'Republic of Chile']::text[]),
('CHN', '🇨🇳', 'cn', ARRAY['CHN', 'China', 'China PR', 'People''s Republic of China']::text[]),
('CIV', '🇨🇮', 'ci', ARRAY['CIV', 'Cote d''Ivoire', 'Côte d''Ivoire', 'Ivory Coast', 'Republic of Côte d''Ivoire']::text[]),
('CMR', '🇨🇲', 'cm', ARRAY['CMR', 'Cameroon', 'Republic of Cameroon']::text[]),
('COD', '🇨🇩', 'cd', ARRAY['COD', 'Congo DR', 'Congo, The Democratic Republic of the', 'DR Congo', 'Democratic Republic of the Congo']::text[]),
('COK', '🇨🇰', 'ck', ARRAY['COK', 'Cook Islands']::text[]),
('COL', '🇨🇴', 'co', ARRAY['COL', 'Colombia', 'Republic of Colombia']::text[]),
('COM', '🇰🇲', 'km', ARRAY['COM', 'Comoros', 'Union of the Comoros']::text[]),
('CPV', '🇨🇻', 'cv', ARRAY['CPV', 'Cabo Verde', 'Republic of Cabo Verde']::text[]),
('CRC', '🇨🇷', 'cr', ARRAY['CRC', 'Costa Rica', 'Republic of Costa Rica']::text[]),
('CRO', '🇭🇷', 'hr', ARRAY['CRO', 'Croatia', 'Republic of Croatia']::text[]),
('CUB', '🇨🇺', 'cu', ARRAY['CUB', 'Cuba', 'Republic of Cuba']::text[]),
('CUW', '🇨🇼', 'cw', ARRAY['CUW', 'Curaçao']::text[]),
('CXR', '🇨🇽', 'cx', ARRAY['CXR', 'Christmas Island']::text[]),
('CYM', '🇰🇾', 'ky', ARRAY['CYM', 'Cayman Islands']::text[]),
('CYP', '🇨🇾', 'cy', ARRAY['CYP', 'Cyprus', 'Republic of Cyprus']::text[]),
('CZE', '🇨🇿', 'cz', ARRAY['CZE', 'Czech Republic', 'Czechia']::text[]),
('DEN', '🇩🇰', 'dk', ARRAY['DEN', 'Denmark', 'Kingdom of Denmark']::text[]),
('DJI', '🇩🇯', 'dj', ARRAY['DJI', 'Djibouti', 'Republic of Djibouti']::text[]),
('DMA', '🇩🇲', 'dm', ARRAY['Commonwealth of Dominica', 'DMA', 'Dominica']::text[]),
('DOM', '🇩🇴', 'do', ARRAY['DOM', 'Dominican Republic']::text[]),
('ECU', '🇪🇨', 'ec', ARRAY['ECU', 'Ecuador', 'Republic of Ecuador']::text[]),
('EGY', '🇪🇬', 'eg', ARRAY['Arab Republic of Egypt', 'EGY', 'Egypt']::text[]),
('ENG', '🏳️', 'gb-eng', ARRAY['ENG', 'England']::text[]),
('ERI', '🇪🇷', 'er', ARRAY['ERI', 'Eritrea', 'the State of Eritrea']::text[]),
('ESH', '🇪🇭', 'eh', ARRAY['ESH', 'Western Sahara']::text[]),
('ESP', '🇪🇸', 'es', ARRAY['ESP', 'Kingdom of Spain', 'Spain']::text[]),
('EST', '🇪🇪', 'ee', ARRAY['EST', 'Estonia', 'Republic of Estonia']::text[]),
('ETH', '🇪🇹', 'et', ARRAY['ETH', 'Ethiopia', 'Federal Democratic Republic of Ethiopia']::text[]),
('FIN', '🇫🇮', 'fi', ARRAY['FIN', 'Finland', 'Republic of Finland']::text[]),
('FJI', '🇫🇯', 'fj', ARRAY['FJI', 'Fiji', 'Republic of Fiji']::text[]),
('FLK', '🇫🇰', 'fk', ARRAY['FLK', 'Falkland Islands (Malvinas)']::text[]),
('FRA', '🇫🇷', 'fr', ARRAY['FRA', 'France', 'French Republic']::text[]),
('FRO', '🇫🇴', 'fo', ARRAY['FRO', 'Faroe Islands']::text[]),
('FSM', '🇫🇲', 'fm', ARRAY['FSM', 'Federated States of Micronesia', 'Micronesia, Federated States of']::text[]),
('GAB', '🇬🇦', 'ga', ARRAY['GAB', 'Gabon', 'Gabonese Republic']::text[]),
('GBR', '🇬🇧', 'gb', ARRAY['GBR', 'Great Britain', 'UK', 'United Kingdom', 'United Kingdom of Great Britain and Northern Ireland']::text[]),
('GEO', '🇬🇪', 'ge', ARRAY['GEO', 'Georgia']::text[]),
('GER', '🇩🇪', 'de', ARRAY['Federal Republic of Germany', 'GER', 'Germany']::text[]),
('GGY', '🇬🇬', 'gg', ARRAY['GGY', 'Guernsey']::text[]),
('GHA', '🇬🇭', 'gh', ARRAY['GHA', 'Ghana', 'Republic of Ghana']::text[]),
('GIB', '🇬🇮', 'gi', ARRAY['GIB', 'Gibraltar']::text[]),
('GIN', '🇬🇳', 'gn', ARRAY['GIN', 'Guinea', 'Republic of Guinea']::text[]),
('GLP', '🇬🇵', 'gp', ARRAY['GLP', 'Guadeloupe']::text[]),
('GMB', '🇬🇲', 'gm', ARRAY['GMB', 'Gambia', 'Republic of the Gambia']::text[]),
('GNB', '🇬🇼', 'gw', ARRAY['GNB', 'Guinea-Bissau', 'Republic of Guinea-Bissau']::text[]),
('GNQ', '🇬🇶', 'gq', ARRAY['Equatorial Guinea', 'GNQ', 'Republic of Equatorial Guinea']::text[]),
('GRD', '🇬🇩', 'gd', ARRAY['GRD', 'Grenada']::text[]),
('GRE', '🇬🇷', 'gr', ARRAY['GRE', 'Greece', 'Hellenic Republic']::text[]),
('GRL', '🇬🇱', 'gl', ARRAY['GRL', 'Greenland']::text[]),
('GTM', '🇬🇹', 'gt', ARRAY['GTM', 'Guatemala', 'Republic of Guatemala']::text[]),
('GUF', '🇬🇫', 'gf', ARRAY['French Guiana', 'GUF']::text[]),
('GUM', '🇬🇺', 'gu', ARRAY['GUM', 'Guam']::text[]),
('GUY', '🇬🇾', 'gy', ARRAY['GUY', 'Guyana', 'Republic of Guyana']::text[]),
('HKG', '🇭🇰', 'hk', ARRAY['HKG', 'Hong Kong', 'Hong Kong Special Administrative Region of China']::text[]),
('HMD', '🇭🇲', 'hm', ARRAY['HMD', 'Heard Island and McDonald Islands']::text[]),
('HND', '🇭🇳', 'hn', ARRAY['HND', 'Honduras', 'Republic of Honduras']::text[]),
('HTI', '🇭🇹', 'ht', ARRAY['HTI', 'Haiti', 'Republic of Haiti']::text[]),
('HUN', '🇭🇺', 'hu', ARRAY['HUN', 'Hungary']::text[]),
('IDN', '🇮🇩', 'id', ARRAY['IDN', 'Indonesia', 'Republic of Indonesia']::text[]),
('IMN', '🇮🇲', 'im', ARRAY['IMN', 'Isle of Man']::text[]),
('IND', '🇮🇳', 'in', ARRAY['IND', 'India', 'Republic of India']::text[]),
('IOT', '🇮🇴', 'io', ARRAY['British Indian Ocean Territory', 'IOT']::text[]),
('IRL', '🇮🇪', 'ie', ARRAY['IRL', 'Ireland', 'Republic of Ireland']::text[]),
('IRN', '🇮🇷', 'ir', ARRAY['IR Iran', 'IRN', 'Iran', 'Iran, Islamic Republic of', 'Islamic Republic of Iran']::text[]),
('IRQ', '🇮🇶', 'iq', ARRAY['IRQ', 'Iraq', 'Republic of Iraq']::text[]),
('ISL', '🇮🇸', 'is', ARRAY['ISL', 'Iceland', 'Republic of Iceland']::text[]),
('ISR', '🇮🇱', 'il', ARRAY['ISR', 'Israel', 'State of Israel']::text[]),
('ITA', '🇮🇹', 'it', ARRAY['ITA', 'Italian Republic', 'Italy']::text[]),
('JAM', '🇯🇲', 'jm', ARRAY['JAM', 'Jamaica']::text[]),
('JEY', '🇯🇪', 'je', ARRAY['JEY', 'Jersey']::text[]),
('JOR', '🇯🇴', 'jo', ARRAY['Hashemite Kingdom of Jordan', 'JOR', 'Jordan']::text[]),
('JPN', '🇯🇵', 'jp', ARRAY['JPN', 'Japan']::text[]),
('KAZ', '🇰🇿', 'kz', ARRAY['KAZ', 'Kazakhstan', 'Republic of Kazakhstan']::text[]),
('KEN', '🇰🇪', 'ke', ARRAY['KEN', 'Kenya', 'Republic of Kenya']::text[]),
('KGZ', '🇰🇬', 'kg', ARRAY['KGZ', 'Kyrgyz Republic', 'Kyrgyzstan']::text[]),
('KIR', '🇰🇮', 'ki', ARRAY['KIR', 'Kiribati', 'Republic of Kiribati']::text[]),
('KNA', '🇰🇳', 'kn', ARRAY['KNA', 'Saint Kitts and Nevis']::text[]),
('KOR', '🇰🇷', 'kr', ARRAY['KOR', 'Korea Republic', 'Korea, Republic of', 'Republic of Korea', 'South Korea']::text[]),
('KOS', '🇽🇰', 'xk', ARRAY['KOS', 'Kosovo']::text[]),
('KSA', '🇸🇦', 'sa', ARRAY['KSA', 'Kingdom of Saudi Arabia', 'Saudi Arabia']::text[]),
('KWT', '🇰🇼', 'kw', ARRAY['KWT', 'Kuwait', 'State of Kuwait']::text[]),
('LAO', '🇱🇦', 'la', ARRAY['LAO', 'Lao People''s Democratic Republic', 'Laos']::text[]),
('LBN', '🇱🇧', 'lb', ARRAY['LBN', 'Lebanese Republic', 'Lebanon']::text[]),
('LBR', '🇱🇷', 'lr', ARRAY['LBR', 'Liberia', 'Republic of Liberia']::text[]),
('LBY', '🇱🇾', 'ly', ARRAY['LBY', 'Libya']::text[]),
('LCA', '🇱🇨', 'lc', ARRAY['LCA', 'Saint Lucia']::text[]),
('LIE', '🇱🇮', 'li', ARRAY['LIE', 'Liechtenstein', 'Principality of Liechtenstein']::text[]),
('LKA', '🇱🇰', 'lk', ARRAY['Democratic Socialist Republic of Sri Lanka', 'LKA', 'Sri Lanka']::text[]),
('LSO', '🇱🇸', 'ls', ARRAY['Kingdom of Lesotho', 'LSO', 'Lesotho']::text[]),
('LTU', '🇱🇹', 'lt', ARRAY['LTU', 'Lithuania', 'Republic of Lithuania']::text[]),
('LUX', '🇱🇺', 'lu', ARRAY['Grand Duchy of Luxembourg', 'LUX', 'Luxembourg']::text[]),
('LVA', '🇱🇻', 'lv', ARRAY['LVA', 'Latvia', 'Republic of Latvia']::text[]),
('MAC', '🇲🇴', 'mo', ARRAY['MAC', 'Macao', 'Macao Special Administrative Region of China']::text[]),
('MAF', '🇲🇫', 'mf', ARRAY['MAF', 'Saint Martin (French part)']::text[]),
('MAR', '🇲🇦', 'ma', ARRAY['Kingdom of Morocco', 'MAR', 'Morocco']::text[]),
('MCO', '🇲🇨', 'mc', ARRAY['MCO', 'Monaco', 'Principality of Monaco']::text[]),
('MDA', '🇲🇩', 'md', ARRAY['MDA', 'Moldova', 'Moldova, Republic of', 'Republic of Moldova']::text[]),
('MDG', '🇲🇬', 'mg', ARRAY['MDG', 'Madagascar', 'Republic of Madagascar']::text[]),
('MDV', '🇲🇻', 'mv', ARRAY['MDV', 'Maldives', 'Republic of Maldives']::text[]),
('MEX', '🇲🇽', 'mx', ARRAY['MEX', 'Mexico', 'United Mexican States']::text[]),
('MHL', '🇲🇭', 'mh', ARRAY['MHL', 'Marshall Islands', 'Republic of the Marshall Islands']::text[]),
('MKD', '🇲🇰', 'mk', ARRAY['MKD', 'Macedonia', 'North Macedonia', 'Republic of North Macedonia']::text[]),
('MLI', '🇲🇱', 'ml', ARRAY['MLI', 'Mali', 'Republic of Mali']::text[]),
('MLT', '🇲🇹', 'mt', ARRAY['MLT', 'Malta', 'Republic of Malta']::text[]),
('MNE', '🇲🇪', 'me', ARRAY['MNE', 'Montenegro']::text[]),
('MNG', '🇲🇳', 'mn', ARRAY['MNG', 'Mongolia']::text[]),
('MNP', '🇲🇵', 'mp', ARRAY['Commonwealth of the Northern Mariana Islands', 'MNP', 'Northern Mariana Islands']::text[]),
('MOZ', '🇲🇿', 'mz', ARRAY['MOZ', 'Mozambique', 'Republic of Mozambique']::text[]),
('MRT', '🇲🇷', 'mr', ARRAY['Islamic Republic of Mauritania', 'MRT', 'Mauritania']::text[]),
('MSR', '🇲🇸', 'ms', ARRAY['MSR', 'Montserrat']::text[]),
('MTQ', '🇲🇶', 'mq', ARRAY['MTQ', 'Martinique']::text[]),
('MUS', '🇲🇺', 'mu', ARRAY['MUS', 'Mauritius', 'Republic of Mauritius']::text[]),
('MWI', '🇲🇼', 'mw', ARRAY['MWI', 'Malawi', 'Republic of Malawi']::text[]),
('MYA', '🇲🇲', 'mm', ARRAY['Burma', 'MYA', 'Myanmar', 'Republic of Myanmar']::text[]),
('MYS', '🇲🇾', 'my', ARRAY['MYS', 'Malaysia']::text[]),
('MYT', '🇾🇹', 'yt', ARRAY['MYT', 'Mayotte']::text[]),
('NAM', '🇳🇦', 'na', ARRAY['NAM', 'Namibia', 'Republic of Namibia']::text[]),
('NCL', '🇳🇨', 'nc', ARRAY['NCL', 'New Caledonia']::text[]),
('NED', '🇳🇱', 'nl', ARRAY['Holland', 'Kingdom of the Netherlands', 'NED', 'Netherlands']::text[]),
('NER', '🇳🇪', 'ne', ARRAY['NER', 'Niger', 'Republic of the Niger']::text[]),
('NFK', '🇳🇫', 'nf', ARRAY['NFK', 'Norfolk Island']::text[]),
('NGA', '🇳🇬', 'ng', ARRAY['Federal Republic of Nigeria', 'NGA', 'Nigeria']::text[]),
('NIC', '🇳🇮', 'ni', ARRAY['NIC', 'Nicaragua', 'Republic of Nicaragua']::text[]),
('NIR', '🏳️', 'gb-nir', ARRAY['NIR', 'Northern Ireland']::text[]),
('NIU', '🇳🇺', 'nu', ARRAY['NIU', 'Niue']::text[]),
('NOR', '🇳🇴', 'no', ARRAY['Kingdom of Norway', 'NOR', 'Norway']::text[]),
('NPL', '🇳🇵', 'np', ARRAY['Federal Democratic Republic of Nepal', 'NPL', 'Nepal']::text[]),
('NRU', '🇳🇷', 'nr', ARRAY['NRU', 'Nauru', 'Republic of Nauru']::text[]),
('NZL', '🇳🇿', 'nz', ARRAY['NZL', 'New Zealand']::text[]),
('OMN', '🇴🇲', 'om', ARRAY['OMN', 'Oman', 'Sultanate of Oman']::text[]),
('PAK', '🇵🇰', 'pk', ARRAY['Islamic Republic of Pakistan', 'PAK', 'Pakistan']::text[]),
('PAN', '🇵🇦', 'pa', ARRAY['PAN', 'Panama', 'Republic of Panama']::text[]),
('PAR', '🇵🇾', 'py', ARRAY['PAR', 'Paraguay', 'Republic of Paraguay']::text[]),
('PCN', '🇵🇳', 'pn', ARRAY['PCN', 'Pitcairn']::text[]),
('PER', '🇵🇪', 'pe', ARRAY['PER', 'Peru', 'Republic of Peru']::text[]),
('PHL', '🇵🇭', 'ph', ARRAY['PHL', 'Philippines', 'Republic of the Philippines']::text[]),
('PLE', '🇵🇸', 'ps', ARRAY['PLE', 'Palestine', 'Palestine, State of', 'the State of Palestine']::text[]),
('PLW', '🇵🇼', 'pw', ARRAY['PLW', 'Palau', 'Republic of Palau']::text[]),
('PNG', '🇵🇬', 'pg', ARRAY['Independent State of Papua New Guinea', 'PNG', 'Papua New Guinea']::text[]),
('POL', '🇵🇱', 'pl', ARRAY['POL', 'Poland', 'Republic of Poland']::text[]),
('POR', '🇵🇹', 'pt', ARRAY['POR', 'Portugal', 'Portuguese Republic']::text[]),
('PRI', '🇵🇷', 'pr', ARRAY['PRI', 'Puerto Rico']::text[]),
('PRK', '🇰🇵', 'kp', ARRAY['Democratic People''s Republic of Korea', 'Korea DPR', 'Korea Democratic People''s Republic', 'Korea, Democratic People''s Republic of', 'North Korea', 'PRK']::text[]),
('PYF', '🇵🇫', 'pf', ARRAY['French Polynesia', 'PYF']::text[]),
('QAT', '🇶🇦', 'qa', ARRAY['QAT', 'Qatar', 'State of Qatar']::text[]),
('REU', '🇷🇪', 're', ARRAY['REU', 'Réunion']::text[]),
('ROU', '🇷🇴', 'ro', ARRAY['ROU', 'Romania']::text[]),
('RSA', '🇿🇦', 'za', ARRAY['RSA', 'Republic of South Africa', 'South Africa']::text[]),
('RUS', '🇷🇺', 'ru', ARRAY['RUS', 'Russian Federation']::text[]),
('RWA', '🇷🇼', 'rw', ARRAY['RWA', 'Rwanda', 'Rwandese Republic']::text[]),
('SCO', '🏳️', 'gb-sct', ARRAY['SCO', 'Scotland']::text[]),
('SDN', '🇸🇩', 'sd', ARRAY['Republic of the Sudan', 'SDN', 'Sudan']::text[]),
('SEN', '🇸🇳', 'sn', ARRAY['Republic of Senegal', 'SEN', 'Senegal']::text[]),
('SGP', '🇸🇬', 'sg', ARRAY['Republic of Singapore', 'SGP', 'Singapore']::text[]),
('SGS', '🇬🇸', 'gs', ARRAY['SGS', 'South Georgia and the South Sandwich Islands']::text[]),
('SHN', '🇸🇭', 'sh', ARRAY['SHN', 'Saint Helena, Ascension and Tristan da Cunha']::text[]),
('SJM', '🇸🇯', 'sj', ARRAY['SJM', 'Svalbard and Jan Mayen']::text[]),
('SLB', '🇸🇧', 'sb', ARRAY['SLB', 'Solomon Islands']::text[]),
('SLE', '🇸🇱', 'sl', ARRAY['Republic of Sierra Leone', 'SLE', 'Sierra Leone']::text[]),
('SLV', '🇸🇻', 'sv', ARRAY['El Salvador', 'Republic of El Salvador', 'SLV']::text[]),
('SMR', '🇸🇲', 'sm', ARRAY['Republic of San Marino', 'SMR', 'San Marino']::text[]),
('SOM', '🇸🇴', 'so', ARRAY['Federal Republic of Somalia', 'SOM', 'Somalia']::text[]),
('SPM', '🇵🇲', 'pm', ARRAY['SPM', 'Saint Pierre and Miquelon']::text[]),
('SRB', '🇷🇸', 'rs', ARRAY['Republic of Serbia', 'SRB', 'Serbia']::text[]),
('SSD', '🇸🇸', 'ss', ARRAY['Republic of South Sudan', 'SSD', 'South Sudan']::text[]),
('STP', '🇸🇹', 'st', ARRAY['Democratic Republic of Sao Tome and Principe', 'STP', 'Sao Tome and Principe']::text[]),
('SUI', '🇨🇭', 'ch', ARRAY['SUI', 'Swiss Confederation', 'Switzerland']::text[]),
('SUR', '🇸🇷', 'sr', ARRAY['Republic of Suriname', 'SUR', 'Suriname']::text[]),
('SVK', '🇸🇰', 'sk', ARRAY['SVK', 'Slovak Republic', 'Slovakia']::text[]),
('SVN', '🇸🇮', 'si', ARRAY['Republic of Slovenia', 'SVN', 'Slovenia']::text[]),
('SWE', '🇸🇪', 'se', ARRAY['Kingdom of Sweden', 'SWE', 'Sweden']::text[]),
('SWZ', '🇸🇿', 'sz', ARRAY['Eswatini', 'Kingdom of Eswatini', 'SWZ']::text[]),
('SXM', '🇸🇽', 'sx', ARRAY['SXM', 'Sint Maarten (Dutch part)']::text[]),
('SYC', '🇸🇨', 'sc', ARRAY['Republic of Seychelles', 'SYC', 'Seychelles']::text[]),
('SYR', '🇸🇾', 'sy', ARRAY['SYR', 'Syria', 'Syrian Arab Republic']::text[]),
('TAN', '🇹🇿', 'tz', ARRAY['TAN', 'Tanzania', 'Tanzania, United Republic of', 'United Republic of Tanzania']::text[]),
('TCA', '🇹🇨', 'tc', ARRAY['TCA', 'Turks and Caicos Islands']::text[]),
('TCD', '🇹🇩', 'td', ARRAY['Chad', 'Republic of Chad', 'TCD']::text[]),
('TGO', '🇹🇬', 'tg', ARRAY['TGO', 'Togo', 'Togolese Republic']::text[]),
('THA', '🇹🇭', 'th', ARRAY['Kingdom of Thailand', 'THA', 'Thailand']::text[]),
('TJK', '🇹🇯', 'tj', ARRAY['Republic of Tajikistan', 'TJK', 'Tajikistan']::text[]),
('TKL', '🇹🇰', 'tk', ARRAY['TKL', 'Tokelau']::text[]),
('TKM', '🇹🇲', 'tm', ARRAY['TKM', 'Turkmenistan']::text[]),
('TLS', '🇹🇱', 'tl', ARRAY['Democratic Republic of Timor-Leste', 'TLS', 'Timor-Leste']::text[]),
('TON', '🇹🇴', 'to', ARRAY['Kingdom of Tonga', 'TON', 'Tonga']::text[]),
('TPE', '🇹🇼', 'tw', ARRAY['Chinese Taipei', 'TPE', 'Taiwan']::text[]),
('TTO', '🇹🇹', 'tt', ARRAY['Republic of Trinidad and Tobago', 'TTO', 'Trinidad and Tobago']::text[]),
('TUN', '🇹🇳', 'tn', ARRAY['Republic of Tunisia', 'TUN', 'Tunisia']::text[]),
('TUR', '🇹🇷', 'tr', ARRAY['Republic of Türkiye', 'TUR', 'Turkey', 'Turkiye', 'Türkiye']::text[]),
('TUV', '🇹🇻', 'tv', ARRAY['TUV', 'Tuvalu']::text[]),
('TWN', '🇹🇼', 'tw', ARRAY['TWN', 'Taiwan', 'Taiwan, Province of China']::text[]),
('UGA', '🇺🇬', 'ug', ARRAY['Republic of Uganda', 'UGA', 'Uganda']::text[]),
('UKR', '🇺🇦', 'ua', ARRAY['UKR', 'Ukraine']::text[]),
('UMI', '🇺🇲', 'um', ARRAY['UMI', 'United States Minor Outlying Islands']::text[]),
('URU', '🇺🇾', 'uy', ARRAY['Eastern Republic of Uruguay', 'URU', 'Uruguay']::text[]),
('USA', '🇺🇸', 'us', ARRAY['USA', 'United States', 'United States of America']::text[]),
('UZB', '🇺🇿', 'uz', ARRAY['Republic of Uzbekistan', 'UZB', 'Uzbekistan']::text[]),
('VAT', '🇻🇦', 'va', ARRAY['Holy See (Vatican City State)', 'VAT']::text[]),
('VCT', '🇻🇨', 'vc', ARRAY['Saint Vincent and the Grenadines', 'VCT']::text[]),
('VEN', '🇻🇪', 've', ARRAY['Bolivarian Republic of Venezuela', 'VEN', 'Venezuela', 'Venezuela, Bolivarian Republic of']::text[]),
('VGB', '🇻🇬', 'vg', ARRAY['British Virgin Islands', 'VGB', 'Virgin Islands, British']::text[]),
('VIE', '🇻🇳', 'vn', ARRAY['Socialist Republic of Viet Nam', 'VIE', 'Viet Nam', 'Vietnam']::text[]),
('VIR', '🇻🇮', 'vi', ARRAY['VIR', 'Virgin Islands of the United States', 'Virgin Islands, U.S.']::text[]),
('VUT', '🇻🇺', 'vu', ARRAY['Republic of Vanuatu', 'VUT', 'Vanuatu']::text[]),
('WAL', '🏳️', 'gb-wls', ARRAY['WAL', 'Wales']::text[]),
('WLF', '🇼🇫', 'wf', ARRAY['WLF', 'Wallis and Futuna']::text[]),
('WSM', '🇼🇸', 'ws', ARRAY['Independent State of Samoa', 'Samoa', 'WSM']::text[]),
('YEM', '🇾🇪', 'ye', ARRAY['Republic of Yemen', 'YEM', 'Yemen']::text[]),
('ZMB', '🇿🇲', 'zm', ARRAY['Republic of Zambia', 'ZMB', 'Zambia']::text[]),
('ZWE', '🇿🇼', 'zw', ARRAY['Republic of Zimbabwe', 'ZWE', 'Zimbabwe']::text[])
      ;

      CREATE OR REPLACE FUNCTION public.international_catalog_match_code(p_label text)
      RETURNS text
      LANGUAGE sql
      STABLE
      SET search_path = public
      AS $$
        SELECT c.code
        FROM public.international_nation_catalog c
        WHERE public.international_normalize_nation_label(p_label) = ANY (
          SELECT public.international_normalize_nation_label(a)
          FROM unnest(c.aliases) AS a
        )
        ORDER BY length(c.code)
        LIMIT 1;
      $$;

      CREATE OR REPLACE FUNCTION public.international_gpdb_matches_nation(
        p_gpdb_label text,
        p_nation_code text
      )
      RETURNS boolean
      LANGUAGE sql
      STABLE
      SET search_path = public
      AS $$
        SELECT EXISTS (
          SELECT 1
          FROM public.international_nations n
          WHERE n.code = upper(btrim(p_nation_code))
            AND n.active = true
            AND (
              public.international_normalize_nation_label(p_gpdb_label)
                = public.international_normalize_nation_label(n.name)
              OR public.international_normalize_nation_label(p_gpdb_label)
                = upper(n.code)
              OR public.international_catalog_match_code(p_gpdb_label) = n.code
            )
        );
      $$;

      CREATE OR REPLACE FUNCTION public.international_generate_nation_code(p_label text)
      RETURNS text
      LANGUAGE plpgsql
      STABLE
      SET search_path = public
      AS $function$
      DECLARE
        v_base text;
        v_code text;
        v_i integer := 0;
      BEGIN
        v_base := left(public.international_normalize_nation_label(p_label), 3);
        IF v_base IS NULL OR v_base = '' THEN
          v_base := 'XXX';
        END IF;
        v_code := v_base;
        WHILE EXISTS (
          SELECT 1 FROM public.international_nations n WHERE n.code = v_code
        ) LOOP
          v_i := v_i + 1;
          v_code := upper(substring(md5(p_label || ':' || v_i::text) FROM 1 FOR 3));
          v_code := regexp_replace(v_code, '[^A-Z]', 'X', 'g');
          IF length(v_code) < 3 THEN
            v_code := rpad(v_code, 3, 'X');
          END IF;
          EXIT WHEN v_i > 200;
        END LOOP;
        RETURN v_code;
      END;
      $function$;

      CREATE OR REPLACE FUNCTION public.international_sync_gpdb_nations()
      RETURNS jsonb
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = public
      AS $function$
      DECLARE
        v_row record;
        v_code text;
        v_emoji text;
        v_rank integer;
        v_inserted integer := 0;
        v_skipped integer := 0;
      BEGIN
        IF NOT public.is_gpsl_admin()
           AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
          RAISE EXCEPTION 'Admin only';
        END IF;

        SELECT coalesce(max(seed_rank), 0) INTO v_rank FROM public.international_nations;

        FOR v_row IN
          SELECT
            p."Nation" AS label,
            count(*)::integer AS players
          FROM public."Players" p
          WHERE btrim(coalesce(p."Nation", '')) <> ''
            AND NOT EXISTS (
              SELECT 1
              FROM public.international_nations n
              WHERE n.active = true
                AND public.international_gpdb_matches_nation(p."Nation", n.code)
            )
          GROUP BY p."Nation"
          ORDER BY players DESC, p."Nation"
        LOOP
          v_code := public.international_catalog_match_code(v_row.label);

          IF v_code IS NULL THEN
            v_code := public.international_generate_nation_code(v_row.label);
            v_emoji := '🏳️';
          ELSE
            SELECT c.flag_emoji INTO v_emoji
            FROM public.international_nation_catalog c
            WHERE c.code = v_code;
          END IF;

          IF EXISTS (
            SELECT 1 FROM public.international_nations n WHERE n.code = v_code
          ) THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
          END IF;

          v_rank := v_rank + 1;
          INSERT INTO public.international_nations (code, name, flag_emoji, seed_rank, active)
          VALUES (v_code, v_row.label, coalesce(v_emoji, '🏳️'), v_rank, true);
          v_inserted := v_inserted + 1;
        END LOOP;

        IF to_regprocedure('public.international_refresh_gpdb_label_map()') IS NOT NULL THEN
          PERFORM public.international_refresh_gpdb_label_map();
        END IF;

        RETURN jsonb_build_object(
          'inserted', v_inserted,
          'skipped_existing_code', v_skipped,
          'active_nations', (SELECT count(*) FROM public.international_nations WHERE active = true)
        );
      END;
      $function$;

      -- Nation select UI: total active nations + draft order size
      DROP VIEW IF EXISTS public.international_selection_public;
      CREATE VIEW public.international_selection_public
      WITH (security_invoker = false)
      AS
      SELECT
        w.id,
        w.phase,
        w.is_open,
        w.opens_at,
        w.closes_at,
        w.current_pick_rank,
        (
          SELECT d.club_short_name
          FROM public.international_owner_draft_order() d
          WHERE d.pick_order = w.current_pick_rank
          LIMIT 1
        ) AS current_pick_club,
        (
          SELECT count(*)::integer
          FROM public.international_owner_nations ion
          WHERE ion.is_active = true
        ) AS nations_assigned,
        (
          SELECT count(*)::integer
          FROM public.international_owner_draft_order()
        ) AS draft_order_size,
        (
          SELECT count(*)::integer
          FROM public.international_nations n
          WHERE n.active = true
        ) AS nations_total
      FROM public.international_selection_windows w
      WHERE w.is_open = true
      ORDER BY w.id DESC
      LIMIT 1;

      CREATE OR REPLACE FUNCTION public.international_player_matches_nation(
        p_player_id text,
        p_nation_code text
      )
      RETURNS boolean
      LANGUAGE sql
      STABLE
      SET search_path = public
      AS $$
        SELECT EXISTS (
          SELECT 1
          FROM public."Players" p
          JOIN public.international_nations n ON n.code = upper(btrim(p_nation_code))
          WHERE p."Konami_ID"::text = btrim(p_player_id)
            AND n.active = true
            AND public.international_gpdb_matches_nation(p."Nation", n.code)
        );
      $$;

      GRANT SELECT ON public.international_nation_catalog TO authenticated;
      GRANT EXECUTE ON FUNCTION public.international_sync_gpdb_nations() TO authenticated;
      GRANT EXECUTE ON FUNCTION public.international_catalog_match_code(text) TO authenticated;
      GRANT EXECUTE ON FUNCTION public.international_gpdb_matches_nation(text, text) TO authenticated;

      NOTIFY pgrst, 'reload schema';
