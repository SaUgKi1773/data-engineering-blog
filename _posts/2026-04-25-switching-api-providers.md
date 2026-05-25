---
layout: post
title: "Choosing a Football Data API: api-football vs football-data.org vs Sportmonks"
date: 2026-04-25
categories: [data-engineering, ingestion, api]
---

Before a single line of pipeline code was written, there was a more fundamental question: where does the data come from? Football data APIs are plentiful, but free tiers vary wildly in what they actually give you. I evaluated three providers before settling on the one that runs this project today.

## The Short Version

| | api-football.com | football-data.org | Sportmonks |
|---|---|---|---|
| **Free plan call limit** | 100 / day | 10 / minute | ~3,000 / hour per entity |
| **Danish Superligaen included** | ✅ | ❌ | ✅ |
| **Current live season** | ✅ | ❌ (free tier only covers select top leagues) | ✅ |
| **Match statistics** (shots, possession, corners) | ✅ | ❌ | ✅ |
| **Player lineups** | ✅ | ❌ | ✅ |
| **Individual player stats** (ratings, passes, duels) | ✅ | ❌ | ✅ |
| **Event data** (goals, cards, subs) | ✅ | ✅ (basic) | ✅ |
| **Formations** | ❌ | ❌ | ✅ |
| **Period-level breakdowns** | ❌ | ❌ | ✅ |
| **Historical data** | ✅ | ✅ | ✅ |
| **xG (expected goals)** | ❌ | ❌ | ❌ (paywalled) |
| **Verdict** | Usable but capped | Unusable for this project | Current choice |

---

## football-data.org — Disqualified Immediately

I looked at football-data.org first because it markets itself as the developer-friendly, open-data option and it genuinely has a clean API design. The problem is the free tier only covers a fixed list of major competitions: Premier League, Bundesliga, La Liga, Serie A, Ligue 1, and a handful of cup competitions.

Danish Superligaen is not on that list. End of evaluation.

There is no way to request additional competitions, no pay-as-you-go option for smaller leagues, and the upgrade path jumps straight to paid tiers designed for commercial applications. For a project built around Danish football specifically, football-data.org is simply not an option regardless of how nice the API design is.

If your project targets one of the big five European leagues, football-data.org is worth a serious look. For anything else, check the free tier coverage list before spending time on it.

---

## api-football.com — Good Enough to Start, Too Limited to Finish

api-football.com was the first real choice. The free tier includes Danish Superligaen, the documentation is readable, and the data model is straightforward — one endpoint per resource type, predictable response shapes, consistent pagination.

**The 100-call-per-day ceiling is the defining constraint.** Everything about the early pipeline was designed around not exceeding it. The bronze layer covered 21 endpoints. A full historical backfill required thousands of calls spread over weeks. The nightly incremental run was engineered to do the absolute minimum — fetch only what changed, skip everything stable.

That constraint also blocked the project from growing. Adding the Danish Cup is a one-line config change. But it would immediately blow the daily quota. The architecture could scale. The API contract could not.

Data quality was also an ongoing issue. Several endpoints returned inconsistently structured responses depending on the fixture — player stats missing for one team, venue records with null coordinates, referee data only partially populated. Nothing catastrophic, but the silver layer spent a lot of effort compensating for gaps that were endemic to the source rather than edge cases.

api-football.com is a reasonable starting point for a project that fits within 100 calls a day and does not need to grow. This project outgrew it.

---

## Sportmonks — What the Project Runs on Today

Sportmonks is a different category of product. The free tier is genuinely generous, the data is richer, and the architecture forces you to think about data fetching differently.

The key design difference is the **include system**. Instead of one endpoint per resource type, Sportmonks has one endpoint per entity where you specify what related data you want in the same call. Fetching a fixture with scores, events, lineups, player statistics, referee, formations, and period breakdowns is a single API request. The same data from api-football.com would have required seven or eight separate calls.

For a nightly pipeline this matters a lot. The incremental run that previously consumed 30–50 api-football.com calls now takes 5–10 Sportmonks calls. The rate limit of ~3,000 requests per hour per entity is essentially never the bottleneck in normal operation.

The data is also richer than anything api-football.com provided at the free tier. Sportmonks gives you period-level breakdowns (first half shots, second half possession), detailed position types for lineup players (attacking midfielder, defensive midfielder rather than just a generic position label), and formation data at the fixture level. None of that existed in the api-football.com pipeline.

**What the Sportmonks free plan still blocks:** xG, expected lineups, ball coordinates, pressure data, in-play odds, pre- and post-match news, and video highlights. Of these, xG is the most notable absence — it is the one metric that serious football analytics work relies on most heavily. Its absence is more noticeable with Sportmonks than it was with api-football.com, because every other dimension of the data is so much more complete. It is the one obvious gap.

The include system also has a learning curve. Building the right include string for a given endpoint takes time and experimentation. The nesting is deep, some sub-entities are inconsistently present across fixtures, and documentation for edge cases is thin. But once the include strings are working, the pipeline is significantly simpler than the old multi-endpoint design — one generic engine, one manifest, every strategy pattern implemented once.

---

## What I Would Choose Again

If starting from scratch today: Sportmonks, no hesitation. The free tier is the most capable of the three for a project that needs a smaller European league, real match statistics, and room to add competitions without rebuilding the ingestion layer.

football-data.org is not an option if your target league is outside the top five. api-football.com is viable for a small project with modest ambitions, but the 100-call limit will eventually become the ceiling rather than just a constraint. Sportmonks charges nothing until you need xG or commercial features, and by then you will have a project worth paying for.
