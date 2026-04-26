---
layout: post
title: "Global Launch — A Conclusion"
date: 2026-04-19
categories: [data-engineering, deployment]
---

By April 2026 — roughly ten days after the first real commit — the pipeline was stable, the dashboard had seven pages, and the nightly job was running cleanly. It was time to call it launched.

The live dashboard is at [superligaanalytics.vercel.app](https://superligaanalytics.vercel.app/).

## What Shipped

The final state of the project at launch:

- **Bronze layer** — 21 endpoints ingested nightly from api-football.com into MotherDuck
- **Silver layer** — 18 dbt models that flatten and type-cast the raw JSON
- **Gold layer** — Kimball star schema: 10 dimension tables and `fct_match_results`
- **Dashboard** — 7 Evidence.dev pages: Home, Standings, Match Results, Upcoming Fixtures, League Analytics, Team Analytics, Referee Analytics
- **Orchestration** — GitHub Actions nightly pipeline: bronze → silver → gold → Vercel deploy
- **CI** — dbt compile on every pull request to main
- **Dev/prod separation** — `superligaen_dev` and `superligaen` databases, `dev` and `prod` dbt targets

## Reflections

This project went from initial commit to live dashboard in approximately ten days of active development. That is fast enough that almost every architectural choice was made under time pressure, with incomplete information, and revised at least once.

The tools that delivered exactly what they promised: MotherDuck, DuckDB, dbt, GitHub Actions. No surprises, no unexplained failures.

The tools that required more navigation: Netlify (build limits), Cloudflare Pages (file size limits), Evidence.dev (underdocumented behaviour around layouts and template syntax).

The choices I would make the same way: MotherDuck as the warehouse, dbt for transformations, Evidence.dev for the dashboard, Vercel for hosting, the Kimball star schema, the dev/prod database separation.

The choices I would make differently: evaluate hosting platforms against build frequency before committing; add dbt tests from the beginning rather than deferring them; set up dbt documentation from the start.

The ambitions that did not make it in: multi-league support (blocked by API quota), dbt tests, dbt semantic layer, dbt documentation, real-time match events (requires a paid API tier).

The project is now in maintenance mode. The nightly pipeline runs, the data updates, and the dashboard reflects last night's results every morning. For a project built entirely on free tiers in ten days, that is a good place to be.
