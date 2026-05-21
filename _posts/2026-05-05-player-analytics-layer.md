---
layout: post
title: "Building the Player Analytics Layer"
date: 2026-05-05
categories: [data-engineering, dbt, analytics]
---

The roadmap post described player analytics as data that was already sitting in the warehouse — it just needed to be modelled and served. That was accurate. Sportmonks returns per-player match statistics for every fixture as part of the lineups include. The challenge was not acquiring the data but deciding what to do with it.

## What the Source Data Contains

Sportmonks includes player statistics at the lineup detail level. Each fixture-player combination comes with a record that contains the statistics the player produced in that match: goals, assists, shots (on target, off target, blocked), passes (total, accurate, into the final third), tackles, interceptions, duels (total, won, lost), dribbles (attempted, completed), aerial duels, key passes, big chances created, saves (for goalkeepers), cards, minutes played, and a rating.

The rating is particularly useful. Sportmonks calculates a performance rating per player per match — a number roughly between 5 and 9, where 6.5 is average, above 7 is a good performance, and above 8 is exceptional. It is not a metric you can derive from raw statistics; it is a judgement produced by Sportmonks' scoring system. That makes it valuable precisely because it captures things the raw counts miss.

The raw data lands in the bronze `sportmonks__fixtures` table, nested inside the lineups include. The silver layer (`fixture_lineup_details.sql`) flattens it: one row per (fixture, player), with each stat as a typed column. From there it feeds `fct_player_appearances` in the gold layer.

## The Fact Table: fct_player_appearances

The fact table has one row per (match, player, team). It joins to the dimension tables for context: `dim_player` for the player's name and nationality, `dim_team` for the club, `dim_match` for the fixture date and round, `dim_position` for the player's position.

The foreign key structure follows the same pattern as `fct_team_matches`: surrogate keys everywhere, sentinel records for Unknown (-1) and Not Applicable (-2), INNER JOINs throughout. The sentinel pattern means that a player who appears in a fixture but cannot be matched to `dim_player` still generates a row — it just resolves to the Unknown player rather than disappearing silently.

The table currently has around 50,000 rows, covering every player appearance across all seasons from 2010 onwards.

## The Mart: mart_player_facts

The gold fact table is normalised — surrogate keys, no denormalisation. Querying it directly from the dashboard would require joining five or six dimension tables for every query. The mart layer exists to avoid that.

`mart_player_facts` is a denormalised view that joins everything out into a single flat table the dashboard can query directly. Player name, team name, team logo, position, season, round number, match date, all 50+ statistics, the rating, minutes played — all in one row per player per match. Dashboard queries `SELECT` from `mart_player_facts` without any joins.

The mart also adds two derived columns that are not in the source data: `goals_contributions` (goals + assists) and `is_current_season` (boolean, derived from the season field). The first is a convenience aggregation used throughout the player analytics pages. The second drives the "this season" filter default on every dropdown.

## The Dashboard Layer: Player Profile

The player analytics page was designed around a player selector — a dropdown showing all players who have appeared in at least one match in the selected season. Selecting a player loads their profile.

The profile has four sections:

**Season overview** — the player's aggregated statistics for the full season. Total goals, assists, matches played, average rating, total minutes. Presented as KPI cards at the top of the page, giving a quick picture of their contribution.

**League standing** — where the player ranks in the league for their key metrics. A card that says "Top 8% of attackers in the league by goals per 90" is more informative than a raw number, because it gives context. The percentile is calculated in the SQL query by ranking the player against all players at the same position across the same season.

**Radar chart** — a spider chart across eight dimensions: goals per 90, assists per 90, pass accuracy, key passes per 90, dribbles completed per 90, tackles per 90, aerial duels won per 90, and rating. Each axis is scaled to the league maximum for that metric and that position group, so 100% means best in the league. The shape of the radar gives an immediate fingerprint of the player's style — a wide attacker looks different from a box striker, a ball-playing defender looks different from a stopper.

**Performance timeline** — a chart showing the player's rating and a key statistic (goals or saves, depending on position) across every match in the season. The timeline separates a genuine form run from a one-off performance, and it shows what happened to form around a change in manager, a long absence, or a run of difficult fixtures.

## Per-90 Normalisation

Most player statistics in the dashboard are shown per 90 minutes rather than in aggregate. A player who played 600 minutes and scored 4 goals contributed the same per-90 rate as one who played 1,200 minutes and scored 8, but aggregates would make the second player look twice as good.

The per-90 calculation:

```sql
round(goals_scored * 90.0 / nullif(minutes_played, 0), 2) as goals_per_90
```

`NULLIF` handles zero-minute appearances (substitutes who were injured before they came on, for example). Multiplying by 90 before dividing by minutes means the result is goals per 90 minutes regardless of how many minutes the player actually played.

The threshold for inclusion in the radar and the league standings is 450 minutes — roughly five full matches. Players below this threshold have too few minutes for per-90 rates to be meaningful. A forward who played one match and scored would show a goals-per-90 rate of 90 * (1/90) = 1.0, which would put them at the top of the chart based on a single data point.

## What the Data Can and Cannot Tell You

The player analytics layer surfaces what happened. It shows that a player had an exceptional first half of the season and a poor second half. It shows that a winger contributes heavily on key passes but rarely scores. It shows that a goalkeeper's save percentage dropped in the Championship Round.

What it cannot tell you is why. Injuries, form, tactical changes, quality of opposition — these context layers are not in the data. The timeline chart invites interpretation; it does not provide it.

The absence of xG is the most significant gap. Goals and shots are what you can count. Expected goals would let you distinguish a striker who scores from difficult angles — genuinely clinical — from one who scores because they get into good positions. That distinction matters. It is not available on the current plan, and it is the clearest signal about where a player analytics layer like this one has room to grow.
