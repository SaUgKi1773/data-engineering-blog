---
layout: post
title: "Choosing a Data Source"
date: 2026-04-10
categories: [data-engineering, architecture]
---

## Choosing the Data Source

The first thing I did was look for a football API. Two candidates came up immediately.

**football-data.org** was the first I tried. The documentation is clean, the free tier is usable, and the community around it is solid. I set up an account, read through the available endpoints, and then hit the first wall: the Danish Superligaen is not included in the free tier. The free tier covers the top five European leagues — Premier League, La Liga, Bundesliga, Serie A, and Ligue 1 — plus a handful of cup competitions. Superligaen requires a paid plan. That was the end of that.

**api-football.com** was the second option, and it did have Superligaen in the free tier. The free tier gives you access to all leagues but caps you at **100 API calls per day**. That sounds like a lot until you start mapping out what you need to fetch.

Each match needs: fixture metadata, statistics, events (goals, cards), lineups, player stats, and predictions. For a season with roughly 200 matches across multiple years, a full historical load requires thousands of calls just for fixtures. Add standings, top scorers, venues, referees, injuries, and odds, and a full bootstrap run across all available seasons (2020–2025) adds up to something in the hundreds of thousands of calls — spread over many days with careful throttling.

The 100-call-per-day limit was also one of the reasons I couldn't expand the project beyond Superligaen. I wanted to include the Danish Cup, the Danish second division, or even add a comparison league from another country — Turkish Süper Lig would have been interesting. The architecture we built is genuinely scalable: adding a new league is just a config change. But doing so would immediately exceed the daily quota. That is a ceiling I am still bumping against.

There is also a rate limit within each day: **10 requests per minute**. Exceeding it returns a 429, and the API does not give you a Retry-After header — you just have to know the limit and respect it. Early versions of the ingestion code used a naive `sleep(6)` between calls, which worked but was fragile. We later replaced it with a retry-with-backoff strategy that is both more correct and more efficient.

## Choosing the Data Warehouse: MotherDuck

Once I knew the data source, I needed a place to store it. The options I considered were:

- **BigQuery** — the obvious choice for cloud data warehousing. Free tier is generous. But the Python client, the IAM setup, the service account JSON files — it adds friction before you have written a single query.
- **Snowflake** — industry standard, but the free trial expires and then you are paying.
- **DuckDB local** — fast, zero setup, perfect for development. But the data only lives on your laptop, which rules out a public dashboard.
- **MotherDuck** — DuckDB in the cloud. The free tier gives you **10 GB of storage** and a managed DuckDB instance accessible via a token. Zero infrastructure to manage. The Python client is just `duckdb` with a `md:` prefix on the connection string.

MotherDuck won immediately. The developer experience is exceptional: you connect with a token, you write standard DuckDB SQL, and your data persists in the cloud. There is a web UI, a CLI, and it integrates natively with Evidence.dev (which I will get to later). For a side project, it removes every infrastructure concern that would otherwise become a time sink.

The one thing MotherDuck does not tell you upfront is that the free plan runs on a **Pulse** tier compute node with a 953 MB memory cap. That limit would come back to bite us several weeks later in a way that was not obvious at all, but more on that in a later post.

## Two Environments from the Start

One decision I made early that saved a lot of grief: set up two separate databases on MotherDuck — `superligaen` for production and `superligaen_dev` for development. Every pipeline run, every dbt model, every SQL change would first be tested against `superligaen_dev` before being pointed at prod. This is standard practice in professional data engineering but easy to skip on a side project. I am glad I did not skip it.

The GitHub Actions workflows have a `target_db` parameter so you can point any run at either database. The dbt profiles have explicit `dev` and `prod` targets. This separation meant I could break things in `superligaen_dev` freely — and I broke things constantly — without ever risking the production data.

## What We Are Building

At this point the stack was: **api-football.com** as the source, **MotherDuck** as the warehouse, **Python** for ingestion, and some form of transformation and dashboard yet to be decided. The architecture I had in mind was a **medallion architecture**: three layers.

- **Bronze** — raw JSON from the API, stored as-is in MotherDuck. One table per API endpoint. No transformation, no validation, just a faithful copy of whatever the API returned.
- **Silver** — cleaned, typed, structured relational tables. Each bronze table gets flattened, nulls handled, types cast correctly.
- **Gold** — a Kimball dimensional model. A fact table and a set of dimension tables designed for analytical queries and dashboard consumption.

That design held throughout the project. The tools used to implement each layer changed significantly, but the three-layer architecture never did.

Next: building the bronze layer.
