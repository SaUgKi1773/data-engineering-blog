---
layout: post
title: "Switching API Providers — api-football.com vs Sportmonks"
date: 2026-04-25
categories: [data-engineering, ingestion, api]
---

The original data source for this project was api-football.com. It worked well enough to get the project off the ground, but over time it became clear that the free tier was a structural ceiling rather than just a temporary inconvenience. Eventually I switched to Sportmonks. This post explains what drove the switch and what changed when I made it.

## What api-football.com Gave Us

api-football.com was the right choice to start with. The documentation is readable, the free tier includes Danish Superligaen, and the API structure is simple: one endpoint, one resource type. To fetch fixture statistics, you call `/v3/fixtures/statistics?fixture=12345`. To fetch lineups, you call `/v3/fixtures/lineups?fixture=12345`. Each call returns exactly what you asked for.

The free tier limits are **100 API calls per day** and **10 requests per minute**. For the initial design those limits shaped every decision made in the ingestion layer. The bronze layer covered 21 endpoints. A full historical load required thousands of calls, spread across weeks with careful throttling. The nightly incremental run was engineered to do the minimum necessary to stay inside the daily budget.

The 100-call limit also blocked the project from growing. Adding the Danish Cup competition is a one-line config change in the ingestion engine — but doing so would immediately blow the daily quota. The architecture could scale. The API contract could not.

There were also data quality issues that never fully resolved. Several endpoints returned inconsistently structured responses depending on the fixture — player stats missing for one team in a match, venue records with null coordinates, referee data only partially populated. The bronze layer stored whatever came back and the silver transformation handled it as gracefully as it could, but some gaps were endemic to the source.

## What Sportmonks Does Differently

Sportmonks is architecturally different from api-football.com. Where api-football.com has one endpoint per resource type, Sportmonks has one endpoint per entity with an **include system** that lets you fetch related data in the same call.

To fetch a fixture with everything attached — scores, events, lineups, player statistics, referee, formations, periods — you send a single request:

```
GET /v3/football/fixtures/between/{from}/{to}
    ?include=scores;events;events.player;lineups;lineups.details;referees.referee;formations;statistics;periods
```

That single call returns a deeply nested response that api-football.com would have required seven or eight separate calls to assemble. For the nightly incremental run, this is the difference between 30–50 API calls and 5–10.

The rate limits are also meaningfully different. Sportmonks measures usage per entity type — approximately **3,000 requests per hour per entity**. In practice the limit is high enough that it is not a factor in normal operation. The API also returns a `retry_after` field in its 429 responses, which makes backoff logic precise rather than guesswork:

```python
if r.status_code == 429:
    body = r.json()
    retry_after = body.get("retry_after") or body.get("message", {}).get("retry_after") or 0
    wait = int(retry_after) if retry_after else min(60 * (attempt + 1), 600)
    time.sleep(wait)
```

The api-football.com client used exponential backoff without any guidance from the server. The Sportmonks client sleeps exactly as long as the API tells it to.

## The Include System: Power and Complexity

The include system is Sportmonks' biggest strength and its biggest learning curve.

Every Sportmonks entity has a documented list of available includes. You build an include string from that list and pass it as a query parameter. The response nesting depth depends on how deeply you chain them — `lineups` gives you the player ID and position; `lineups;lineups.player` also embeds the full player record; `lineups;lineups.player;lineups.details` adds per-player match statistics.

For the fixtures endpoint, the final include string covers everything the free plan allows:

```
scores;scores.type;scores.participant;
events;events.type;events.player;events.relatedPlayer;events.participant;
timeline;statistics;metadata;
referees.referee;coaches;
periods;periods.type;periods.statistics;periods.events;periods.timeline;
lineups;lineups.player;lineups.position;lineups.type;lineups.detailedPosition;lineups.details;
formations;formations.participant;
sidelined;weatherReport
```

This returns far more data per fixture than api-football.com ever did. The downside is that the response shape is complex, the nesting is deep, and some sub-entities are inconsistently present. Not every fixture has a weather report. Not every lineup has detailed position data. The silver layer handles this with aggressive `TRY_CAST` and `COALESCE` patterns throughout.

## What the Free Plan Still Blocks

Sportmonks' free plan is generous but not unlimited. Several endpoints are explicitly blocked and return HTTP 403:

- **xG data** (expected goals per fixture and per shot) — paywalled at all tiers below the most expensive plan
- **Pre-match and post-match news** — requires a dedicated media add-on
- **Ball coordinates** (tracking data per event) — not available on free
- **In-play and premium odds** — requires a separate odds subscription
- **Pressure and trend data** — requires analytics add-on

The api-football.com free tier also lacked xG, but its absence there never felt like much because the tier was limited in every dimension. With Sportmonks, you have rich tactical data — formations, detailed player stats, period-level breakdowns — but the absence of xG is more noticeable. It is the one metric that most professional football analytics work relies on.

The config file documents every blocked endpoint explicitly so there is no ambiguity about what the current plan can and cannot do:

```python
# Free-plan blocked endpoints (return HTTP 403)
# Do not add these to the manifest — they will always fail:
#   trends, xGFixture, pressure, expectedLineups,
#   premiumOdds, inplayOdds, highlights, predictions,
#   ballCoordinates, prematchNews, postmatchNews
```

## The Migration

The migration was not a simple swap. api-football.com and Sportmonks have different response structures, different ID systems, and different data granularity. You cannot just point the existing ingestion code at the new API.

The approach was to treat it as a clean rebuild of the bronze layer:

1. Write a new ingestion engine from scratch, designed around Sportmonks' include system and pagination model rather than api-football.com's per-endpoint structure.
2. Implement a generic engine (`engine.py`) driven by a declarative manifest — an `ENDPOINT_MANIFEST` list where each entry describes a table, an API path, a fetch strategy, and a delete strategy. Adding a new endpoint is a config change, not a code change.
3. Migrate the silver models to the new source table structure. Sportmonks uses type IDs to categorise events and statistics — a single `fixture_statistics` table where each row is a (fixture, team, type_id, value) tuple, rather than separate columns per statistic. The silver layer joins the `types` lookup table to resolve type names.
4. Validate the gold layer output against the old data to catch anything that changed in the transition.

The ID systems are completely different. api-football.com and Sportmonks assign different integer IDs to the same real-world entities — the same fixture has a different ID in each system. This means the old bronze data and the new bronze data cannot be mixed in the same tables. The transition required a full-refresh load in the new structure; incremental logic could only begin once the historical backfill was complete.

The existing api-football.com bronze tables remain intact in MotherDuck as an archive. They are not queried by anything in the current pipeline, but they exist as a record of what the original ingestion produced.

## What Changed After the Switch

The fixture data is richer. Sportmonks provides period-level breakdowns — you can see how many shots each team had in the second half specifically, not just across the full match. Event records are more complete. Lineup data includes detailed position types (attacking midfielder, defensive midfielder) rather than a single position per player.

The ingestion code is simpler. The old pipeline had 21 separate ingest scripts, each handling the quirks of its specific endpoint. The new pipeline has one generic engine and a manifest. Every strategy pattern (seasonal, date-based, stage-based, round-based) is implemented once and reused.

The nightly run is faster. Fetching a week of incremental fixture data with all includes takes fewer API calls than the equivalent api-football.com run, and the higher rate limits mean less waiting between calls. The `API_CALL_DELAY` in the new client is 0.3 seconds — down from 6 seconds in the original.

One thing that did not improve: **xG data**. That gap exists in both providers at the free tier. If the project ever reaches a point where paying for data makes sense, xG would be the first thing to unlock. It would change the player analytics layer substantially — shot quality alongside shot volume, goal over/underperformance, genuine offensive threat measurement.

For now, the project runs on what the Sportmonks free tier provides. It is significantly more than what we started with.
