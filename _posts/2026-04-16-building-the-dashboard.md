---
layout: post
title: "The Dashboard — Discovering Evidence.dev"
date: 2026-04-16
categories: [data-engineering, dashboard, frontend]
---

I knew from the start that I wanted a live public dashboard, not a static report or a screenshot. The question was which tool to use.

## Why Not the Obvious Choices

**Tableau** and **Power BI** were immediately out — they are expensive, and the free tiers do not allow public sharing without embedding tricks.

**Grafana** is excellent for operational metrics but not designed for product analytics dashboards. The user experience for building and sharing analytical views is awkward.

**Metabase** was a serious contender. It is open source, has a clean UI, and connects to DuckDB. But self-hosting Metabase adds infrastructure overhead, and the cloud version has a cost.

**Streamlit** would have worked, but it requires you to write Python to build UI, and the resulting dashboards do not look polished without significant effort.

**Superset** — similar story to Metabase: powerful, but infrastructure-heavy.

## Evidence.dev

Evidence.dev is a different paradigm entirely. You write dashboard pages in Markdown. SQL queries go in fenced code blocks directly in the page. The output of each query is available as a variable in the same file. Charts, tables, and filters are Svelte components that you use inline in the Markdown. The whole thing compiles to a static site — no server, no runtime, just HTML, CSS, and JavaScript.

```markdown
```sql matches
select match_date, home_team, away_team, score
from superligaen.match_results_by_match
order by match_date desc
limit 10
` ` `

<DataTable data={matches} />
```

That is the entire workflow. Write a SQL query, reference its name in a component, and you have a table on your dashboard. It is the fastest path from data to UI that I have found.

Evidence.dev connects to MotherDuck natively via the `@evidence-dev/motherduck` plugin. At build time, it runs the SQL queries against MotherDuck and bundles the results as Parquet files into the static build output. The deployed site loads these Parquet files at runtime using DuckDB-WASM — meaning the dashboard runs analytical queries entirely in the browser, with no server. It is genuinely impressive engineering.

## Dashboard Pages

We built seven pages:

**Home** — a hero banner with the league logo and flag, four KPI tiles (current leader, team count, matches played, goals scored this season), and a navigation grid linking to every other page.

**Standings** — three separate tables covering the Championship Round, Relegation Round, and Regular Season standings, with a season selector to browse historical tables.

**Match Results** — a filterable table of all historical results with a Goals vs xG chart by round that shows which rounds were overperforming or underperforming expected goals.

**Upcoming Fixtures** — a table of the next fixtures sorted by date and kick-off time, plus a match analysis section: select any upcoming fixture from the dropdown and see the head-to-head history between those two clubs and the last five results for each team.

**League Analytics** — cross-team benchmarks: top scorers, most disciplined teams, possession rankings, and season-level trends. This is the "zoom out" page.

**Team Analytics** — deep dive into a single team: select a team and see their season KPIs, recent form, shooting accuracy, possession stats, and discipline record. This page was the most technically interesting to build because it required combining multiple gold views with different grains.

**Referee Analytics** — cards issued, fouls per match, team exposure (which referees are most frequently assigned to which clubs), and a match log for each referee. This one came from a genuine curiosity: in a small league with a small pool of referees, team-referee familiarity is a real thing.

## What Evidence.dev Is Not

Evidence.dev is a static site generator. That means the data is frozen at build time. There is no live query against MotherDuck when a user loads the page — they are loading the data that was baked in during the last build. For a nightly pipeline that updates at midnight, this is perfectly fine. The dashboard is always at most 24 hours stale, which is acceptable for a league that plays two or three times a week.

The implication is that to refresh the data you need to trigger a new build. The nightly GitHub Actions pipeline does this automatically: bronze ingestion → silver dbt run → gold dbt run → trigger Vercel deploy. The deploy takes about two minutes and the site is updated.

## Quirks and Fixes

A few things about Evidence.dev that were not obvious:

**The `%` sign in SQL** — Evidence.dev uses `%` as a template delimiter internally, which conflicts with the SQL `LIKE` operator pattern `'%value%'`. We ran into this when formatting percentage values. The fix was to use the `pct0` format specifier that Evidence provides for formatting numbers as percentages, rather than concatenating a `%` symbol in SQL.

**Sidebar and TOC** — By default, Evidence.dev renders a table of contents and a sidebar on every page. For a dashboard that is supposed to look like a product, these are in the way. The `sidebar: never` and `hide_toc: true` frontmatter options suppress them. This was not in the main documentation but buried in a GitHub issue.

**Mobile responsiveness** — The default Evidence.dev layout is desktop-first. Getting the home page hero banner and the KPI grid to look right on mobile required custom CSS in the Markdown using Tailwind utility classes (which Evidence.dev ships with). Nothing dramatic, but it needed explicit work.

**The `evidence.config.yaml` layout key** — An early version of the config file had an invalid `layout:` key that was silently causing a build warning. We removed it when it started being noisy.

Next: the part of the project that took the most calendar time relative to its apparent simplicity — getting the dashboard deployed.
