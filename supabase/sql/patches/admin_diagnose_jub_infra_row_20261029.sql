-- JUB infra row: raw ledger vs public view
SELECT 'raw' AS src, l.id, l.season_id, l.amount, l.created_at,
       l.metadata->>'source' AS source, left(l.description, 100) AS description
FROM public.competition_finance_ledger l
WHERE l.club_short_name = 'JUB' AND l.entry_type = 'infra_purchase'
UNION ALL
SELECT 'public', p.id, p.season_id, p.amount, p.created_at,
       p.metadata->>'source', left(p.description, 100)
FROM public.competition_finance_ledger_public p
WHERE p.club_short_name = 'JUB' AND p.entry_type = 'infra_purchase';

SELECT id, label, is_current, status
FROM public.competition_seasons
ORDER BY id;
