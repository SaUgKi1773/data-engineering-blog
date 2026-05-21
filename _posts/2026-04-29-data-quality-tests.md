---
layout: post
title: "Data Quality Tests — Making the Pipeline Fail Loudly"
date: 2026-04-29
categories: [data-engineering, dbt, testing]
---

The roadmap post flagged data quality tests as a priority. The pipeline runs nightly. The dashboard is public. If bad data reaches the gold layer, real users see wrong numbers, and there is no automated check stopping that from happening. That situation had to change.

This post covers what we built: a test suite across the gold layer that runs as part of every dbt pipeline execution and fails loudly on any violation.

## Two Kinds of Tests in dbt

dbt has two test mechanisms that work differently and serve different purposes.

**Schema tests** are declared in YAML alongside model definitions. They are concise and cover the most common assertions — uniqueness, not-null, referential integrity, accepted values. You declare them once and dbt generates the SQL:

```yaml
- name: dim_team
  columns:
    - name: team_sk
      tests: [not_null, unique]
    - name: team_name
      tests: [not_null]
```

**Singular tests** are plain SQL files in the `tests/` directory. A test passes if the query returns zero rows. Any row returned is a failure. These handle assertions that do not fit the schema test vocabulary — cross-model consistency checks, mathematical invariants, volume thresholds.

The gold layer uses both. Schema tests in `_schema.yml` files handle the column-level assertions. Singular tests in `tests/gold/` handle everything more complex.

## What the Schema Tests Cover

Every dimension has `not_null` and `unique` on its surrogate key. Every natural key (the real-world API ID) has the same constraints, but conditional on the sentinel records being excluded:

```yaml
- name: team_id
  tests:
    - not_null:
        config: {where: "team_sk > 0"}
    - unique:
        config: {where: "team_sk > 0"}
```

The `where: "team_sk > 0"` condition excludes the sentinel records (`-1` for Unknown, `-2` for Not Applicable). Sentinel rows intentionally have no natural key — that is the point of them. Without the condition, the uniqueness test would fail on every dimension that has sentinels. With the condition, the test correctly validates only the real rows.

The fact tables have composite uniqueness tests, using `dbt_utils`:

```yaml
- name: fct_team_matches
  tests:
    - dbt_utils.unique_combination_of_columns:
        arguments:
          combination_of_columns: [match_sk, team_side_sk]
```

One row per (match, team side). If this fires, it means the pipeline produced duplicate rows for a fixture — which would double-count goals, cards, and possession in every dashboard query that aggregates this table.

Categorical dimensions also have accepted value constraints:

```yaml
- name: match_result
  tests:
    - accepted_values:
        arguments:
          values: ['Win', 'Draw', 'Loss', 'Pending', 'Unknown Match Result', 'Not Applicable Match Result']
```

This guards against the API returning a result value that does not map to any known category — which would either silently drop records or surface as a new unhandled value in dashboard dropdowns.

## The Singular Tests

The singular tests handle assertions that cannot be expressed per-column.

**Volume floors** — a bad full-refresh that wipes data should fail immediately rather than leaving the dashboard showing zero matches:

```sql
SELECT 'fct_team_matches' AS model, count(*) AS actual, 2000 AS min_expected
FROM {{ ref('fct_team_matches') }}
WHERE match_sk > 0
HAVING count(*) < 2000
```

The thresholds are set well below current actuals — 2,000 rows against a current count of around 4,000 — so legitimate data never trips the test. But a partial wipe or a failed rebuild would.

**Possession sums to 100%** — home and away possession must sum to approximately 100% for every completed match:

```sql
SELECT match_sk, sum(ball_possession_pct) AS total_possession
FROM {{ ref('fct_team_matches') }}
WHERE ball_possession_pct IS NOT NULL AND match_sk > 0
GROUP BY match_sk
HAVING count(*) = 2 AND abs(sum(ball_possession_pct) - 100) > 1
```

The 1pp tolerance handles rounding. If a match shows home 55%, away 46%, that is a data error — possibly a mis-mapped team ID in the silver layer.

**Player minutes in range** — a player's minutes played must be between 0 and 120 (90 regulation + 30 extra time):

```sql
SELECT match_sk, player_sk, minutes_played
FROM {{ ref('fct_player_appearances') }}
WHERE minutes_played < 0 OR minutes_played > 120
```

A value of 999 or -1 indicates the silver transformation produced a nonsense result from missing or malformed API data.

**Sentinel rows present in every dimension** — every dimension that the fact tables join to must have its `-1` (Unknown) and `-2` (Not Applicable) sentinel rows. If they are missing, unresolved foreign keys would produce NULL matches on INNER JOINs rather than gracefully falling through to the Unknown bucket:

```sql
SELECT 'dim_team' AS dim_name, expected_sk
FROM (VALUES (-1), (-2)) t(expected_sk)
WHERE expected_sk NOT IN (SELECT team_sk FROM {{ ref('dim_team') }})
UNION ALL
SELECT 'dim_match', expected_sk ...
-- repeated for every dimension
```

This one runs last in the test order. If it fires, something truncated a dimension table without reseeding the sentinels — which would be a silent failure mode with cascading consequences.

**FK integrity on the fact tables** — for every real appearance row (not a sentinel), the foreign keys must resolve to real dimension rows:

```sql
SELECT 'player_sk' AS fk, match_sk, player_sk
FROM {{ ref('fct_player_appearances') }}
WHERE match_sk > 0 AND player_sk = -1
```

A `player_sk = -1` on a real match row means a player appeared in a fixture but the pipeline could not match them to `dim_player`. This would drop them from every player-filtered query in the dashboard without any visible error.

**HT goals ≤ FT goals** — a halftime score cannot exceed the full-time score:

```sql
SELECT match_sk, team_sk, goals_ht_scored, goals_scored
FROM {{ ref('fct_team_matches') }}
WHERE goals_ht_scored > goals_scored AND match_sk > 0
```

**Points consistency** — if a team won, they should have 3 points; a draw gives 1; a loss gives 0:

```sql
SELECT match_sk, team_sk, match_result_sk, points_earned
FROM {{ ref('fct_team_matches') }}
WHERE match_result_sk IN (1, 2, 3) -- Win, Draw, Loss
  AND NOT (
    (match_result_sk = 1 AND points_earned = 3) OR
    (match_result_sk = 2 AND points_earned = 1) OR
    (match_result_sk = 3 AND points_earned = 0)
  )
```

No negative statistics — goals, shots, passes, tackles and similar count metrics should never be negative:

```sql
SELECT match_sk, team_sk
FROM {{ ref('fct_team_matches') }}
WHERE goals_scored < 0 OR total_shots < 0 OR total_passes < 0
   OR yellow_cards < 0 OR corner_kicks < 0
```

## Running Tests in CI

All tests run as part of the nightly pipeline via GitHub Actions, after the dbt models complete:

```yaml
- name: Run dbt tests
  run: dbt test --select gold
  env:
    MOTHERDUCK_TOKEN: ${{ secrets.MOTHERDUCK_TOKEN }}
```

If any test fails, the workflow step fails, the pipeline is marked red, and a notification fires. The production database is not written to if tests fail — the models run first, the tests validate the output, and downstream steps (the mart views that the dashboard queries) only proceed if everything passes.

During development, `dbt test --select gold` against the dev database runs in about 30 seconds. That is fast enough to run after every significant model change without breaking flow.

## What the Tests Caught

The test suite found real issues during development. The most instructive one: `assert_fct_team_matches_fk_integrity.sql` fired because several historical fixtures had a `venue_id` that did not resolve in `dim_stadium`. The venue existed in the API but was outside the geographic bounding box used to filter out non-Danish stadiums in the silver layer. The filter was set to Danish coordinates, but a handful of international pre-season matches had slipped into the seasonal data.

The fix was to relax the filter for historical non-regular-season fixtures rather than discarding the data. The test caught it; without the test, it would have been invisible. Those matches would have resolved to `stadium_sk = -1` and disappeared from every stadium-filtered query.

The DQ layer is not complete — there are certainly edge cases it does not cover. But every test that exists is there because either a real failure happened or a plausible one was considered carefully enough to warrant a guard. Silent corruption is the worst outcome in a pipeline like this.
