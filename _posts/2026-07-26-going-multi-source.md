---
layout: post
title: "Going Multi-Source — A Friend Asked for Mexico, and Nothing Threw an Error"
date: 2026-07-26
categories: [data-engineering, data-modeling, dbt, multi-league]
---

Three weeks ago a stranger asked for Scotland and the warehouse said yes. This time the request came from a friend, over dinner: *you should do Liga MX — the structure is completely different from anything you've got.* He was right, and that was the appeal. Two tournaments inside one season, each with its own table and its own champion. A knockout stage that decides the title. A play-in round that changed format twice in five years. Everything my model quietly assumed about "a league season" was wrong for Mexico.

There was a bigger reason too. The plan for this platform has always been worldwide, not European — and a project that covers Denmark and Scotland is not worldwide, it's Northern European with ambitions. Mexico was a genuinely good candidate: a big league, a distinctive shape, an audience that isn't mine.

Then I checked the provider. Liga MX isn't on Sportmonks' free plan. Neither is La Liga. Neither is the Süper Lig. The last time I added a league the universe handed me a roadmap; this time it handed me a bill.

So the actual project wasn't *add a league*. It was **add a second data provider** — and those are not remotely the same problem.

## Multi-league was a schema problem. Multi-source is a truth problem.

Adding Scotland meant finding the places where "Denmark" was hardcoded. Constants with nationalities, a season phase the vendor named inconsistently, an ingestion loop that assumed one league id. Annoying, but the shape of the work was obvious: find the assumption, parameterise it, move on.

Adding a second provider is different in kind, because two providers disagree about *what things are*. They disagree about identifiers. They disagree about what a round is called — sometimes with themselves, between seasons. One publishes a running score on every goal; the other doesn't publish one at all. One types its penalty shootouts; the other files them as ordinary penalties.

And here's the part that took me a while to internalise: **almost none of those disagreements produce an error.** They produce data. Plausible, well-formed, confidently wrong data. Over three days of this migration, the count of things that crashed was approximately zero. The count of things that were silently wrong and had to be caught by looking was… the rest of this post.

## The first thing I built wasn't a model

Before touching gold — the layer 96 marts and three live sites read from — I wrote a diffing harness. It snapshots production's gold schema locally, rebuilds gold with your change, and tells you exactly what moved: rows added, rows altered, columns gained, and most importantly **whether any surrogate key changed the entity it points at**.

That last check is the one that matters. If a dimension rebuild renumbers `team_sk`, every historical fact row silently points at the wrong club. Nothing fails. No test catches it, because the new state is perfectly self-consistent — it's just different from yesterday's.

Every gold change in this migration shipped with harness output attached. The refactors printed `IDENTICAL across all 27 relations`. The additive changes printed exactly the rows they were supposed to add and nothing else. It turned "I read it carefully and I think it's fine" into evidence, which is the only thing that makes a change to a live warehouse comfortable.

It also found a bug on its very first run, before I'd changed anything: 725 player transfers pointing at a `dim_date` row that didn't exist, because `dim_date` was the one FK-referenced dimension missing its Unknown/Not-Applicable sentinels. Those transfers had been invisible on every site for as long as the transfer page had existed.

## Nine players who were two people

Here's the design decision I got wrong, and the argument that fixed it.

Two providers mint their own ids. So a dimension key can't be `team_id` any more — it has to be `(team_id, source)`, and every fact-to-dimension join has to match on both. That's 31 join predicates across six fact tables, plus composite keys on seven dimensions.

I looked at the data and pushed back on my own plan. Sportmonks team ids run from 53 to 8,657; the new provider's start at 450,963. Fixture ids: 217k–19.7M against 485M–1.35B. The ranges don't overlap and aren't close to overlapping. Why write 31 predicates that will never be false?

My co-worker on this — the person who owns the product — didn't buy it: *"it is just a coincidence that the IDs dont collide. of course we need the source field in the joins."*

He was right, and I want to be precise about **why** I was wrong, because the mistake is subtler than "he was cautious and I wasn't." I'd checked two entity types and generalised to all of them. When the player dimension finally went multi-source, this came out:

| id | Sportmonks | Highlightly |
|---|---|---|
| 83391 | Henrik Toft | **James Rodríguez** |
| 3857 | Nicky Law | Sergio Gómez |
| 6111 | Niall Keown | Nehuén Pérez |
| 7560 | Alan Maybury | Vitolo |

Nine ids, each belonging to two different footballers. Without the source in the key, those pairs merge into single dimension rows, and James Rodríguez's goals get attributed to a Danish player who never scored them. The uniqueness test would have passed, because after the merge there'd be exactly one row per id. The star schema would have been internally consistent and factually nonsense.

The composite key held: the two `83391`s have separate surrogate keys, their own events, and zero cross-provider leakage.

## Mexico is genuinely a different sport, structurally

My friend was right that Liga MX would break assumptions. Here's what it actually does:

A season year contains **two separate competitions** — Apertura (July–December) and Clausura (January–May). Each has its own 17-round table and its own champion. A club can win one and finish bottom in the other. So "the 2025/26 Liga MX season" isn't a thing you can put a league table against.

We model each tournament as its own season: `2025/26 - Apertura`, `2025/26 - Clausura`. That was the product owner's call, over my suggestion of a season plus a separate tournament column, and it's the better answer — a modifier column implies the two halves are one competition, which is exactly the thing that isn't true.

Then the regular rounds end and the **liguilla** begins: a play-in round, then quarter-finals, semi-finals and a final, all two-legged. Which forces a question the warehouse had never had to answer: *does a knockout match put points on the table?* No. It decides the title, but the table is the seventeen regular rounds only. So those fixtures are league matches that award `NULL` points — not zero, because zero means "played and earned nothing."

And how do you tell a regular round from a knockout? By the round label. Which brings us to the fun part.

## The provider disagrees with itself

Here are the labels Liga MX rounds arrive with, for the same competition:

- `Apertura - Final` and `Clausura - Finals` — singular in one tournament, plural in the other
- `Apertura - Reclasificación` and `Clausura - Reclasificacion` — the accent comes and goes
- `Semi-finals`, `Quarter-finals`, `Final` — one whole season where the tournament prefix simply vanished

Twelve raw variants for what is, in reality, five rounds. If you let those reach a page, a filter dropdown offers users `Final` and `Finals` as separate options.

So the labels get conformed into our own vocabulary — the source doesn't get to decide how the product reads — and the points rule keys off the **conformed** round rather than the raw string, so the round shown on a page and the round used to decide whether points count can never disagree. Anything unrecognised resolves to `Unclassified Round`, which awards nothing and shows up rather than guessing.

That vocabulary work then caught something better. Apertura 2025 had three matches labelled as liguilla rounds — two `Semi-finals` and one `Final` — played on 21 and 24 November. Its quarter-finals started on **27 November**.

A semi-final cannot be played before the quarter-final. Those three were play-in matches, mislabelled at source. The schedule proved it beyond argument.

I proposed a rule to fix it: any knockout match played before its tournament's quarter-finals is a play-in match. It validated cleanly against all twelve tournaments. The product owner rejected it anyway — *"rules change a lot in mexico"* — and again he was right. Liga MX has changed its post-season format twice in five years, from a four-match repechaje to a three-match play-in. A rule tuned to today's shape will eventually misfire on a format nobody has seen yet. Three explicit corrections, each carrying its evidence, cannot.

## The silent failures

This is the section I'd want to read if someone else had written this post, because every item below produced *data* rather than an error.

**Every Mexican kick-off was eight hours wrong.** The timezone helper knew Denmark and Scotland and defaulted everything else to Europe/Copenhagen. So a match that kicked off at 21:00 in Mexico City was recorded as 05:00. The Süper Lig was one to two hours out — Istanbul is UTC+3 year-round. La Liga was correct purely by coincidence, because Madrid shares Copenhagen's offset, which is exactly why nothing looked broken. The fix that matters isn't the five timezone entries; it's that the fallback now returns `NULL`, so the next league added without one produces a *missing* kick-off instead of a plausible Danish one.

**Every new-league match timeline would have shown 0-0 throughout.** The running score after each event was read from a `result` string that Sportmonks stamps on scoring events. The new provider doesn't send that field. So it parsed to NULL, coalesced to zero, and every match read nil-nil from first whistle to last. The score is now *counted* from the event stream instead.

**Toluca beat Tigres 11-9 in a match that finished 2-1.** Sportmonks types its shootout events, so this fact table already excluded them. The new provider files shootout penalties as ordinary penalties — so eleven of them got counted as goals. They're identifiable by the clock (minute 120 with a stoppage offset), and that marker turned out to be exact: 83 such events exist, every one in a match that finished on penalties, none anywhere else.

**A fact table couldn't reproduce itself.** While verifying an unrelated change, the harness reported 116 altered rows in `fct_match_events` that I couldn't account for. So I rebuilt it twice with no code change at all: **130 rows differed between two runs of identical code**. Both the event sequence and the running-score window ordered by four columns that events could tie on, and ties ordered arbitrarily. Beyond being wrong on its own terms, it meant no change to that model could ever be proven safe. It now has a total order and rebuilds byte-identically.

None of these threw. None of them failed a test. Every one of them would have shipped.

## What it actually cost, and what it bought

Fourteen pull requests over three days. Denmark and Scotland came out the other end at **exactly** the row counts and points totals they went in with — through a full-layer rebuild that renumbered every surrogate key in the warehouse — which was the only acceptable outcome, and the harness is why I can state it as a fact rather than a hope.

The warehouse went from two leagues to five:

| | before | after |
|---|---|---|
| `fct_team_matches` | 7,672 | **21,440** |
| `fct_match_events` | 52,103 | **159,885** |
| clubs | 1,409 | **1,493** |
| players | 6,089 | **10,112** |
| tests | 182 | **186** |

And a capability the platform didn't have: **expected goals**. Neither Danish nor Scottish data includes xG on our plan. The new provider carries it, along with 40 team measures per match against Sportmonks' eight — so the fact table went from 9 measures to 44, every one now labelled additive or non-additive, because possession is a percentage and summing it across matches produces numbers in the thousands.

The honest caveat: xG is a 2025-onwards measure in practice. The 2024 season carries it for 6–17% of matches depending on the league. A chart scoped to 2024 would look broken rather than empty, which is worth knowing before designing the page rather than after.

## What's next

Three leagues' worth of data now sit in the warehouse, fully modelled and completely invisible — there are no sites for them yet. That's the next job, and it'll be the first time this platform ships a page with xG on it.

If there's one thing I'd take from this migration into the next one, it's that the second data provider is where a warehouse finds out what it actually believes. The first provider's quirks become your model's assumptions without you ever writing them down: that ids identify things, that a round has one name, that a match has a running score, that everyone plays in Central European Time. The second provider doesn't argue with those assumptions. It just quietly returns data that violates them, and waits to see whether you're paying attention.
