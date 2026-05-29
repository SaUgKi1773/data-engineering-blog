---
layout: post
title: "Why We Migrated from api-football to Sportmonks"
date: 2026-04-25
categories: [data-engineering, ingestion, api]
---

This was not planned. The original architecture was built on api-football.com, the bronze layer was complete, the pipeline was running, and the dashboard was live. Then the nightly job started failing — and fixing it meant rebuilding the entire ingestion layer from scratch.

---

## How It Started: api-football.com

api-football.com was the obvious first choice. It covers Danish Superligaen on the free tier, the documentation is readable, and the data model is straightforward — one endpoint per resource type, predictable response shapes, consistent pagination. Compared to the alternatives, it looked like the path of least resistance.

The free tier has two constraints: **100 calls per day** and **10 calls per minute**. Both shaped every architectural decision that followed.

The bronze layer ended up covering 21 endpoints — leagues, seasons, rounds, standings, fixtures, fixture events, statistics, lineups, player stats, teams, venues, players, top scorers, injuries, predictions, and more. A full historical backfill across all seasons required thousands of calls, spread over weeks of incremental runs. The nightly job was engineered to be as lean as possible: fetch only what could have changed, skip everything stable, stay well under the daily ceiling.

**The 100-call ceiling also blocked the project from growing.** Adding the Danish Cup would have been a one-line config change. But it would immediately blow the daily quota. The architecture was ready to scale. The API contract was not.

To do the full historical backfill and complete development properly, I bought a one-time paid plan — 7,500 calls, enough to bootstrap all seasons and do all the pipeline work. That plan expired when development was done.

---

## The Pipeline Broke

The morning after the paid plan expired, the nightly job failed. The error message was unambiguous: *current season data requires an upgrade. The free plan only covers the previous season.*

This was not a footnote in the pricing page. It is a hard wall. The free tier is structurally limited to historical data — it cannot serve a live pipeline. I had been building on the paid plan without realising that the thing keeping the current season accessible was the payment, not the product. The moment the paid plan lapsed, the dashboard was serving last season's data.

Upgrading was not an option — this project runs on free services by design. So the data source had to change.

---

## Evaluating the Alternatives

**football-data.org** was the first thing I looked at. It has a clean API and genuinely covers the current season for the competitions it supports. But its free tier covers only 13 fixed competitions — the top five European leagues, a handful of cups, Eredivisie, Championship, and a few others. Danish Superligaen is not on the list and there is no way to add it. End of evaluation.

Even if Superligaen were covered, the data depth would be a problem. Match objects on the free plan return the final score, half-time score, and referee — nothing else. No possession, no shots, no player lineups, no player stats, no formations. That is not enough to build a player analytics dashboard on.

**Sportmonks** was the answer. Free tier includes Superligaen, current season works, and the data is richer than anything api-football.com provided. The catch: the architecture is fundamentally different.

---

## Rebuilding the Bronze Layer

api-football.com follows the standard REST pattern — one endpoint per resource. To fetch a fixture with its stats, events, lineups, and player performances, you make separate calls to each endpoint and join the results yourself.

Sportmonks uses an **include system**. There is one endpoint per entity, and you specify what related data you want in the same request. A single call to the fixtures endpoint with the right include string can return scores, events, lineups, player statistics, referee, formations, and period breakdowns all at once. What took seven or eight api-football.com calls now takes one.

This meant the entire bronze ingestion layer had to be rebuilt. The old architecture — one script per endpoint group — was replaced with a **metadata-driven engine**: a single manifest file that lists every entity to ingest, its include string, its delete strategy, and which iteration pattern to use (by season, by round, by date window, etc.). Adding a new entity is a one-line config change. The engine handles the rest.

The migration took a few days. The Sportmonks data model is more complex than api-football.com — the nesting is deep, some sub-entities are inconsistently present across fixtures, and the documentation for edge cases is thin. Getting the include strings right took experimentation. But once the engine was working, the pipeline was cleaner than the old design in every way.

The nightly incremental run that previously consumed 30–50 api-football.com calls now takes 5–10 Sportmonks calls. The rate limit of ~3,000 requests per hour per entity is never the bottleneck.

---

## Provider Comparison

| | api-football.com | football-data.org | Sportmonks |
|---|---|---|---|
| **Free plan call limit** | 100 / day | 10 / minute | ~3,000 / hour per entity |
| **Danish Superligaen included** | ✅ | ❌ | ✅ |
| **Current live season** | ❌ on free plan (paid plan required) | ✅ for covered leagues | ✅ |
| **Match statistics** (shots, possession, corners) | ✅ | ❌ | ✅ |
| **Player lineups** | ✅ | ❌ | ✅ |
| **Individual player stats** (ratings, passes, duels) | ✅ | ❌ | ✅ |
| **Event data** (goals, cards, subs) | ✅ | ✅ (basic) | ✅ |
| **Formations** | ❌ | ❌ | ✅ |
| **Period-level breakdowns** | ❌ | ❌ | ✅ |
| **Historical data** | ✅ | ✅ | ✅ |
| **xG (expected goals)** | ✅ | ❌ | ❌ (paywalled) |
| **Verdict** | Free plan unusable for live pipeline | Unusable for this project | Current choice |

---

## What I Would Do Differently

Start with Sportmonks. The free tier is the most capable of the three for a project that needs a smaller European league, real match statistics, and room to grow. The include system has a learning curve but the payoff is a simpler, more efficient pipeline.

The detour through api-football.com was not entirely wasted — building a complete bronze layer once taught me what the ingestion layer needed to do, and the Sportmonks rebuild came out better for it. But if I were starting today I would not make the detour. Check whether the free tier covers your league and your current season before writing a single line of pipeline code. That check takes five minutes. The migration took several days.
