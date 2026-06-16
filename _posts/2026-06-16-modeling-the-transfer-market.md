---
layout: post
title: "Modeling the Transfer Market — One Move, Two Rows, and a Fee That Might Not Exist"
date: 2026-06-16
categories: [data-engineering, data-modeling, dbt]
---

Most of our dimensional model is about what happens on the pitch — matches, appearances, cards, goals. Adding the transfer market was the first time we modelled a business process that happens *off* the pitch, and it turned out to be one of the more interesting modelling exercises in the whole project. A transfer looks simple — Player X moves from Club A to Club B for €Y — but almost every part of that sentence has an edge case hiding in it. This post walks through the full journey, from the raw API rows to a `fct_team_transfers` fact table and the Transfer Intelligence dashboard page it powers.

## The raw shape

Sportmonks gives us one row per transfer, with the player, both clubs, the type, and the fee embedded as nested objects. The silver model flattens that into typed columns:

```sql
SELECT
    id,
    player_id,
    from_team_id,
    to_team_id,
    transfer_date,
    career_ended,        -- the player retired instead of moving
    completed,           -- deal done vs still pending
    amount,              -- the fee, in euros — often NULL
    from_team_placeholder,
    to_team_placeholder,
    type_name,           -- 'Transfer', 'Free Transfer', 'Loan', 'End of loan'
    ...
FROM bronze.sportmonks__transfers
```

Three things in that list caused all the downstream design decisions:

- **`amount` is frequently NULL.** Sometimes that means "free", sometimes it means "fee undisclosed". Those are not the same thing, and conflating them would quietly corrupt every spend metric.
- **The counterparty club is often not one of our clubs.** A Danish club selling to a German one — the German club is foreign and isn't in our `dim_team`. Sometimes it's a `placeholder` (a stand-in for "some club, details unknown").
- **`career_ended` transfers have no destination at all.** A retirement is modelled as a transfer with no real `to_team`.

## The grain question: one move, two rows

The hardest decision was the grain. A transfer is fundamentally about *two* clubs, but a dashboard almost always looks at the market from one club's point of view — what did FC Copenhagen spend, who did Brøndby sell. We'd already solved this exact shape once, with `fct_team_matches`: a fixture involves two teams, and we store it as **two rows**, one per side.

So we used the same pattern. The grain of `fct_team_transfers` is **one row per (transfer, club)**:

- A normal two-club move emits **two rows** — the selling club gets an `Outgoing` row, the buying club gets an `Incoming` row.
- A move where only one side is a club we track (a foreign sale, or a placeholder counterparty) emits **only that one real side**.
- A retirement emits a single `Outgoing` row for the club losing the player, with no destination.

The model builds this as an `outgoing` CTE (subject = `from_team`) and an `incoming` CTE (subject = `to_team`), each filtered to rows where its own side is a real, non-placeholder club, then `UNION ALL`-ed together. The "other" club becomes a *partner* attribute on the row, not a second subject.

## Direction and mechanism in one mini-dimension

Every transfer row needs to answer two questions: which way did the player move (in or out), and how (permanent, free, loan, loan return, retirement). Those are correlated — a "Loan In" is the incoming face of the same mechanism as a "Loan Out" — so we folded them into a single small `dim_transfer_type`:

```sql
SELECT 1 AS transfer_type_sk, 'Permanent Signing'    AS transfer_type_name, 'Incoming' AS transfer_direction
UNION ALL SELECT 2, 'Permanent Sale',      'Outgoing'
UNION ALL SELECT 3, 'Free Signing',        'Incoming'
UNION ALL SELECT 4, 'Free Departure',      'Outgoing'
UNION ALL SELECT 5, 'Loan In',             'Incoming'
UNION ALL SELECT 6, 'Loan Out',            'Outgoing'
UNION ALL SELECT 7, 'Returning from Loan', 'Incoming'
UNION ALL SELECT 8, 'Loan Spell Ended',    'Outgoing'
UNION ALL SELECT 9, 'Retirement',          'Outgoing'
UNION ALL SELECT -1, 'Unknown',            'Unknown'
UNION ALL SELECT -2, 'Not Applicable',     'Not Applicable'
```

The fact table assigns the surrogate key with a `CASE` on the raw `type_name`, choosing the incoming or outgoing variant depending on which CTE it's in. The same source type — "Loan" — becomes SK 5 in the incoming CTE and SK 6 in the outgoing one. Keeping direction and mechanism in one conformed dimension means a filter like "show me all loan activity" is a single predicate, and the dashboard's Direction filter is just `transfer_direction`.

## The fee that might not exist

This is the subtlety we're proudest of getting right. `amount` is NULL far more often than it's populated, and there are genuinely three different cases hiding behind that:

```sql
CASE
    WHEN amount IS NOT NULL                          THEN amount  -- disclosed fee
    WHEN type_name = 'Transfer' AND NOT career_ended THEN NULL     -- permanent move, fee undisclosed
    ELSE 0                                                         -- free / loan / loan return / retirement: structurally no fee
END AS transfer_fee_eur
```

A free transfer has a fee of exactly **0**. A permanent sale with an undisclosed fee has a fee of **NULL** — we know money changed hands, we just don't know how much. Collapsing those two into "0" would understate spend and inflate the count of "free" deals. Keeping NULL distinct from 0 is what lets the dashboard honestly say *"Fees shown where disclosed"* and report a separate **Fee Disclosed Deals** count — the number of moves where a real fee was actually published — alongside the total deal count.

## The partner club: a role-playing dimension

The other club in a move isn't a new entity — it's a club, same as any other, just playing a different *role*. So `dim_transfer_partner_team` is a view over `dim_team`, exactly parallel to how `dim_opponent_team` is a role-playing view for fixtures:

```sql
SELECT
    team_sk      AS transfer_partner_team_sk,
    team_id      AS transfer_partner_team_id,
    team_name    AS transfer_partner_team_name,
    team_country AS transfer_partner_team_country,
    team_logo    AS transfer_partner_team_logo
FROM dim_team
```

When the counterparty is foreign or a placeholder, the join misses and we fall back to a sentinel key (`-1 Unknown`). That's expected and allowed — more on that below.

## Why we rebuild the whole table every run

Every other fact table is incremental on a date window: new matches land, we process the new dates. Transfers break that assumption. A transfer's *effective date* has nothing to do with when it shows up in the API — backfills arrive late, and future-dated deals (a summer signing announced in spring) would be skipped entirely by a "process yesterday's dates" filter. The table is also tiny — on the order of 10k rows. So `fct_team_transfers` is a plain full rebuild each run. Correct *and* simpler; the incremental machinery would have been complexity with no payoff.

## Tests that encode the weirdness

The edge cases are exactly the things worth testing. Two custom tests guard the model:

- **A transfer can't be between a club and itself.** Both sides may legitimately be NULL (counterparty out of scope), so the test only flags rows where both sides are set *and equal*.
- **FK integrity, with deliberate exceptions.** The subject club, the type, and the status must always resolve to a real dimension row — a `-1` there means a real bug. But `transfer_partner_team_sk`, `player_sk`, and `date_sk` are *allowed* to be `-1`/`-2`: an unknown foreign counterparty, an un-ingested player, or a date outside `dim_date`'s range are all valid states, not failures. Encoding which sentinels are acceptable and which aren't is half the value of the test.

## From gold to the dashboard

The dashboard reads from a `mart_club_transfer_log` view that joins everything out and adds one more rule: a club only appears for years it *actually played a league match* that calendar year. Without it, relegated or not-yet-promoted clubs would show stray transfer rows for seasons they weren't in the league.

On top of that fact, the Transfer Intelligence page derives a few things that don't exist in the source at all:

- **Transfer windows.** Football has registration windows, but the API just gives dates. We derive a `transfer_window` from the month — **Summer** (Jun–Sep), **Winter** (Dec–Feb), and **Outside** for everything else. The two main windows capture ~95% of all activity; the rest are free agents, loan returns, and contract terminations that can happen year-round, so an explicit "Outside" bucket keeps them visible instead of dropping them.
- **Net spend.** Per club, fees on incoming moves (**Spent**) minus fees on outgoing moves (**Received**) gives **Net Spend** — positive for net buyers, negative for net sellers — while **Transfer Volume** (Spent + Received) ranks the clubs moving the most money in either direction.

## What we took away

The recurring theme: **NULL is information.** A missing fee, a missing counterparty, a retirement with no destination — each NULL meant something specific, and the model's job was to preserve those distinctions rather than flatten them into a convenient default. The two-rows-per-move grain and the role-playing partner dimension were both patterns we'd already built for fixtures, which made the structure feel familiar fast. But the real work was in the `CASE` statements — the unglamorous logic that decides whether a blank fee is a zero or an unknown. Get those right and every metric downstream is honest; get them wrong and the dashboard lies confidently.
