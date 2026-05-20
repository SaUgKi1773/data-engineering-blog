---
layout: post
title: "Organising the Semantic Layer — From Raw Models to Mart Views"
date: 2026-05-11
categories: [data-engineering, dbt, architecture]
---

When the gold layer was first built, the dashboard queried the dimensional model directly. A page that needed to show team standings would join `fct_team_matches` to `dim_team`, `dim_match`, `dim_stadium`, `dim_referee`, and `dim_match_result`, filtering for completed matches and aggregating points and goal difference. That join pattern appeared in six or seven dashboard pages, written independently, with subtle differences in filter conditions between them.

This is exactly the problem that a semantic layer is meant to solve. Business logic — what counts as a completed match, how points are calculated, what "is_current_season" means — was defined in the dashboard SQL rather than in the transformation layer. Changing the definition of a metric meant finding every place it appeared and updating them all.

## The Architecture: Gold → Mart → Dashboard

The solution was to add a mart layer between the gold dimensional model and the dashboard. The mart layer contains flat, denormalised views that the dashboard queries directly.

```
Bronze (raw JSON)
  → Silver (typed, relational)
    → Gold (Kimball star schema: fct + dims)
      → Mart (flat, denormalised views)
        → Dashboard (Evidence.dev queries)
```

The mart layer has two main objects: `mart_match_facts` and `mart_player_facts`. Each is a view that joins out everything the dashboard needs into a single flat table.

`mart_match_facts` joins `fct_team_matches` to every dimension it references — team, opponent team, stadium, referee, match, league, coach, formation, match result, team side, and date. The result is one row per (match, team) with every dimension attribute embedded directly. A dashboard query that wants team standings can `GROUP BY team_name` without knowing anything about `dim_team` or surrogate keys.

`mart_player_facts` does the same for `fct_player_appearances` — joining out player name, position, team, and match context so that player analytics queries are self-contained.

## Centralising Business Logic

The mart views also centralise the business logic that was previously scattered across dashboard pages.

**What counts as a completed match?** In the old structure, every page that filtered for completed results used `WHERE result IN ('Win', 'Draw', 'Loss')`. If the definition changed — say, to include penalty shootout results separately — every page needed an update. In the mart, this logic lives in one place:

```sql
CASE
    WHEN m.match_result_sk = 1 THEN 'Win'
    WHEN m.match_result_sk = 2 THEN 'Draw'
    WHEN m.match_result_sk = 3 THEN 'Loss'
    WHEN m.match_result_sk = 4 THEN 'Pending'
    ...
END AS result
```

Dashboard pages still filter with `WHERE result IN ('Win', 'Draw', 'Loss')` — but the definition of what those strings mean is owned by the mart, not the dashboard.

**What is the current season?** The mart derives an `is_current_season` boolean:

```sql
season = (
    SELECT season
    FROM superligaen.dim_season
    WHERE is_current = true
    LIMIT 1
) AS is_current_season
```

Every dashboard filter that defaults to the current season uses `WHERE is_current_season = true`. The mart controls what "current" means.

**What is the standings type?** Superligaen splits its season into a regular season, a Championship Group (top six), and a Relegation Group (bottom eight). The API calls these different stage types. The mart maps them to human-readable labels — `'Championship Group'`, `'Relegation Group'`, `'Regular Season'` — so the standings page can display them correctly without knowing the internal stage type IDs.

## Surrogate Keys Stay in Gold

One deliberate design decision: the mart layer exposes natural identifiers, not surrogate keys. The dashboard knows about `player_id` (the Sportmonks player ID) and `match_id` (the Sportmonks fixture ID). It does not know about `player_sk` or `match_sk`.

Surrogate keys exist to handle slowly changing dimension history — if a player transfers clubs, their surrogate key lets you track appearances with the old team and appearances with the new team separately. That logic is correctly in the gold layer. The mart resolves it and exposes the stable natural IDs and the human-readable names. The dashboard never needs to know a surrogate key exists.

## What the Mart Pattern Costs

The mart layer adds one more step to the transformation chain. A bug in the mart produces wrong numbers in the dashboard without any immediate signal that the mart is the source of the problem.

The mitigation is the dbt test suite described in the previous post. The tests run against the gold layer, not the mart views. If the gold layer is clean, the mart should be correct — and if it is not, the mart definition itself is where the bug is, which is easier to audit than a join that spans six dashboard SQL blocks.

The other cost is that mart views are optimised for the queries the dashboard actually runs. A new dashboard page with a different access pattern might find the mart does not serve it well. So far this has not happened — the two main views have covered every query pattern encountered in practice. If a third access pattern emerges, adding a third mart view is the appropriate response rather than adding joins back into the dashboard.

## Where the dbt Semantic Layer Fits

The mart pattern described here is a practical approximation of what the dbt Semantic Layer does more formally. The formal semantic layer would define metrics as first-class objects:

```yaml
metrics:
  - name: goals_per_match
    model: ref('fct_team_matches')
    label: Goals per Match
    calculation_method: ratio
    expression: goals_scored / matches_played
    filters:
      - field: match_result_sk
        operator: in
        value: [1, 2, 3]
```

The dashboard would then query metrics by name rather than writing SQL. The metric definition would be the single source of truth — one place to update, one place to test.

We are not there yet. The dbt Semantic Layer requires a metrics-aware query layer between dbt and the consuming tool, and Evidence.dev does not currently have a built-in integration for it. The mart pattern achieves the same goal of centralising business logic — it just does so at the SQL view level rather than at the dbt metrics layer. For a project at this scale, the pragmatic approach is the right one for now.
