# Announcement — Lamine Yamal LUB (participation push)

**Image:** `docs/announcement-yamal-lub-participation-20261029.jpg`  
**Suggested Discord title:** Lamine Yamal LUB — only 64.7% of owners are in

**Clickable link (paste into Discord):**  
[Open Special Auction — Lamine Yamal](https://YOUR-GPSL-HOST/special_auction.html)

*(Replace `YOUR-GPSL-HOST` with your live site host, or use the site-relative path owners already know: `special_auction.html`.)*

---

Owners,

**Lamine Yamal** is live in the **Lowest Unique Bid** special auction — and **only 64.7% of owners** have submitted a bid so far.

If you haven’t entered, you’re leaving him on the table for the clubs that have.

### His value
**GPSL market value: ₿185,000,000**  
*(from the poster — confirm live with the SQL below if needed)*

### How LUB works
- **Lowest Unique Bid wins**
- Bids in the **thousands** (₿1,000 · ₿2,000 · ₿3,000…)
- The **lowest amount nobody else also bid** wins the player

### If you win — 3 options
1. **Sign player** — Yamal joins your club; your winning LUB bid is the fee (when you have squad room)
2. **Sign & release** — squad full (28): release one squad player at market value, then sign Yamal in one step
3. **Take cash (MV)** — decline the player; club credited his **market value**; he stays a free agent

### Enter now
→ [Special Auction](https://YOUR-GPSL-HOST/special_auction.html)

— GPSL

---

### Confirm live MV / participation (SQL)

```sql
SELECT p."Konami_ID", p."Name", p.market_value, p."Contracted_Team"
FROM public."Players" p
WHERE p."Name" ILIKE '%yamal%'
ORDER BY p.market_value DESC NULLS LAST;

SELECT a.id, a.title, a.status, a.prize_player_id,
       public.special_auction_participation_stats(a.id) AS participation
FROM public.special_auctions a
WHERE a.status IN ('scheduled', 'active')
ORDER BY a.id DESC
LIMIT 5;
```
