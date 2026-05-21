---
layout: post
title: "Advanced BI Techniques — Making the Data Say More"
date: 2026-05-17
categories: [data-engineering, analytics, dashboard]
---

The roadmap post described a gap between what the dashboard was doing and what it could do. Most of the charts were single-metric bar charts. They were readable. They also left most of the signal in the data on the table.

This post is about the techniques added to close that gap — radar charts, performance timelines, scatter plots, percentile rankings, and bubble maps. The goal in each case was the same: surface a relationship or a pattern that a single-axis view cannot show.

## Radar Charts

A radar chart shows multiple metrics simultaneously, anchored to a common scale, in a shape that can be read as a fingerprint. It is better than a table for comparison because the shape difference between two players is immediately visible; a table forces you to scan rows.

The Evidence.dev `Radar` component expects a long-format dataset — one row per (axis label, value) rather than one wide row per entity. The data transformation in SQL looks like this:

```sql
SELECT player_id, 'Goals / 90' AS metric, goals_per_90 / max_goals_per_90 * 100 AS value FROM ...
UNION ALL
SELECT player_id, 'Assists / 90', assists_per_90 / max_assists_per_90 * 100
UNION ALL
SELECT player_id, 'Pass Acc %', pass_accuracy
-- ... more axes
```

Each axis is normalised to a 0–100 scale where 100 is the league maximum for that metric and position group. This is the important decision: normalising to the league maximum for the player's position, not the global maximum. A goalkeeper's radar should show saves relative to how many other goalkeepers save, not relative to how many goals outfield players score. Without position-aware normalisation, every goalkeeper would have near-zero values on every attacking axis and the shape would be meaningless.

The normalisation is computed in the mart query using window functions:

```sql
max(goals_per_90) over (partition by position_group, season) as max_goals_per_90
```

## Performance Timelines

A performance timeline shows a player's rating and a key statistic (goals, assists, or saves) across every match in the season in chronological order. The timeline serves two purposes that an aggregate view cannot: it shows form, and it shows the relationship between two metrics over time.

The implementation uses a combined chart — a bar chart for the counting statistic layered over a line chart for the rating. Evidence.dev handles this with a `ComboChart` component (bar + line on the same axes). The right Y-axis carries the rating (range approximately 5–9), the left Y-axis carries the counting metric.

The tricky part was the dual Y-axis configuration. Both axes need explicit min/max ranges set or the chart scales them independently, making the visual relationship between bar height and line position misleading. A match with 2 goals but a rating of 6.5 should not look the same as a match with 2 goals and a rating of 8.5.

## Scatter Plots

A scatter plot is the right tool for showing the relationship between two variables across a population. The league analytics page uses a scatter plot to compare attacking output (shots per match or goals per match) against defensive solidity (goals conceded per match) for all teams. Each dot is a team; the ideal position is top-left (high attacking output, low goals conceded).

The chart tells you something a table cannot: it shows clustering. Are the top teams bunched together or spread out? Is there a team that is defensively strong but offensively limited, or one that attacks heavily but leaks goals? The shape of the distribution is the insight.

Evidence.dev's `ScatterPlot` component supports point labels and a tooltip per point. The challenge is legibility when teams overlap at similar coordinates — small marker sizes and label offsets help but do not fully solve the problem at all zoom levels.

## Percentile Rankings

A raw statistic — "this player averaged 6.8 rating this season" — is hard to interpret without context. Is that good? How does it compare to other players? Percentile rankings make the context explicit.

The implementation uses DuckDB's `percent_rank()` window function:

```sql
round(
    percent_rank() over (
        partition by position_group, season
        order by avg_rating asc
    ) * 100
) as rating_percentile
```

`PERCENT_RANK()` returns a value between 0 and 1 representing the fraction of the population that falls below this row. Multiplying by 100 and rounding gives a clean percentile. "Top 15% of midfielders by rating" is a more useful statement than "average rating 7.2".

The percentile is shown on the player profile as a supporting label: the KPI card shows the raw value, and the label below it shows the percentile rank in brackets. This lets a casual reader understand the number and an analyst use the raw value directly.

## Bubble Maps

Stadium intelligence uses a geographic bubble map where each stadium is a point on a map of Denmark, the bubble size represents total goals scored at that venue, and the colour represents the playing surface type (grass, artificial turf, or other).

Three pieces of information in one chart: location, volume, and category. A bar chart of goals by stadium would show the volume but not the geography. A plain map would show the locations but not the scale difference between stadiums. The bubble map shows all three simultaneously.

The size normalisation matters here. Raw goal counts vary from around 20 to over 200 depending on how many matches a stadium has hosted. Using raw counts as bubble sizes produces a chart where the largest bubble dominates and small stadiums are invisible dots. The solution is to scale each stadium's bubble size relative to the minimum, so the smallest bubble is still visible:

```sql
sum(goals_scored) - (min(sum(goals_scored)) over () - 1) as total_goals_scaled
```

This shifts the minimum value to 1 while preserving the relative differences between stadiums.

## Rolling Averages

The original match results charts showed per-match statistics as individual data points. A single match is a poor signal of team form — one exceptional result or one particularly poor defensive performance can distort the picture. Rolling averages smooth this out.

A 5-match rolling average in DuckDB:

```sql
avg(goals_scored) over (
    partition by team_id, season
    order by match_date
    rows between 4 preceding and current row
) as goals_rolling_5
```

The window specification `rows between 4 preceding and current row` includes the current match and the four before it — five matches total. The result is a trend line rather than a scatter of points. It becomes clear whether a team is improving, declining, or consistent over a run of fixtures.

## The Underlying Principle

Every technique here is a version of the same idea: context makes data meaningful. A raw number says what happened. Percentiles say how unusual it was. Radar shapes say what kind of player or team this is. Timelines say whether it is a trend or a blip. Scatter plots say where this entity sits relative to its peers.

The dashboard is now closer to a tool that produces understanding, not just numbers. A fan can read the radar chart and understand a player's strengths at a glance. An analyst can use the scatter plot to spot teams that are overachieving or under their true ceiling. The same data, presented differently, gives both of them something useful.

The next natural extension is contextual benchmarks throughout — league averages as reference lines on every bar chart, so a number like "58% pass accuracy" immediately sits in context rather than floating on its own. That is a small addition with a large impact on readability.
