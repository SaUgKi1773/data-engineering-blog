---
layout: post
title: "Migrating to dbt — When Raw SQL Isn't Enough"
date: 2026-04-18
categories: [data-engineering, dbt, transformation]
---

When the silver and gold layers were first built, they ran as plain SQL files executed by Python runner scripts — `run_silver.py` and `run_gold.py`. Each script would read a directory of `.sql` files, connect to MotherDuck, and execute them in a specific order. It worked. The data was correct. But as the number of models grew and the logic became more complex, the cracks in the approach started to show.

## The Problem with Plain SQL Runners

**Order dependency was manual.** If `dim_team` needed to run before `fct_match_results`, you had to remember that and name or number the files accordingly. When we added a new model, figuring out where it slotted into the execution order was entirely up to the developer.

**No incremental logic.** Every run was a full rebuild. For silver models that flatten tens of thousands of fixture records, this was slow and unnecessary. There was no way to say "only process records that arrived since the last run" without writing custom Python logic around each SQL file.

**No compilation validation.** SQL syntax errors only appeared at runtime. There was no way to check whether a model was valid without actually running it against the database.

**No lineage.** There was no documentation of which model depended on what. Understanding the pipeline required reading the code, not querying a manifest.

**Parameterisation was awkward.** The nightly pipeline uses a rolling date window (last 5 days). The full-refresh pipeline uses a full season reload. Passing different variables to the same SQL file required string interpolation in Python, which is fragile and hard to read.

All of these problems have well-known solutions in the data engineering world. They are solved by **dbt**.

## What dbt Brings

dbt (data build tool) is a transformation framework that sits on top of your data warehouse and manages SQL models. You write SQL `SELECT` statements, and dbt handles the `CREATE TABLE AS`, dependency ordering, incremental logic, and documentation.

The key features we needed:

**Dependency resolution** — dbt builds a DAG (directed acyclic graph) of your models by analysing which model references which. You write `{% raw %}{{ ref('silver_fixtures') }}{% endraw %}` instead of a table name, and dbt knows to run `silver_fixtures` before whatever model references it.

**Incremental models** — dbt's `incremental` materialisation allows a model to process only new or updated records on each run, using a configurable filter. For silver models that process fixture data, this means a nightly run that touches only the last 5 days of records rather than reprocessing all 200+ fixtures from every season.

**Macros** — dbt allows you to write Jinja macros for reusable SQL logic. We created three: `fixture_filter()` for filtering by date window, `season_filter()` for full-season reloads, and `gold_incremental_filter()` for the gold layer's incremental logic. These macros mean the filter logic lives in one place and is consistent across all models.

**CI validation** — dbt's `compile` command parses all SQL and resolves all references without executing anything. Adding `dbt compile --target dev` to the CI workflow (run on every pull request) means SQL syntax errors and broken references are caught before they ever reach main.

**Schema management** — dbt's `generate_schema_name` macro controls the schema prefix applied to model outputs. We use this to ensure models land in exactly the right schema (`silver` or `gold`) regardless of the dbt target, without Cloudflare or Vercel prefixes being appended.

## The Migration

The migration itself took one day. The process:

1. Create the `dbt/` directory with `dbt_project.yml` and `profiles.yml`.
2. Port each SQL file to a dbt model by wrapping it in the appropriate dbt configuration block.
3. Replace hardcoded table names with `{% raw %}{{ ref() }}{% endraw %}` calls where models depend on each other.
4. Extract the date window and season filters into macros.
5. Update the GitHub Actions workflows to run `dbt run --select silver.*` and `dbt run --select gold.*` instead of `python run_silver.py`.
6. Delete the old Python runner scripts and raw SQL files.

Step 6 was satisfying. Deleting code that is no longer needed is one of the better feelings in software development.

There was one technical issue during the migration: DuckDB's dialect handles some SQL constructs differently from other databases, and certain patterns that work in standard SQL do not work in DuckDB's dbt adapter. The main culprit was date arithmetic — DuckDB uses `INTERVAL` syntax and `epoch()` for timestamp operations, which dbt's generic date macros do not always handle correctly. We needed to write DuckDB-specific macro implementations rather than relying on dbt's cross-database abstractions.

The dbt-duckdb adapter version also needed to match the DuckDB version that MotherDuck was running (1.5.1 at the time). Version mismatches between the adapter, the dbt-core version, and the DuckDB version produced cryptic errors that took a while to resolve. Once the versions were pinned and aligned, everything worked cleanly.

## Two Targets: Dev and Prod

The dbt profiles configure two targets:

- `dev` — points to `superligaen_dev` on MotherDuck. Used for local development and for CI.
- `prod` — points to `superligaen`. Used by the nightly GitHub Actions pipeline.

The MotherDuck token is passed via the `MOTHERDUCK_TOKEN` environment variable rather than being stored in `profiles.yml`. This keeps credentials out of version control and makes rotating the token a matter of updating a GitHub Secret rather than committing a change.

## What We Did Not Get To

dbt has a testing framework (`dbt test`) that lets you define assertions about your data — things like "this column has no null values", "this foreign key always joins successfully", "this value is always positive". We did not implement any tests during this project. The right time to add them would be now that the models are stable and the architecture is not changing frequently. Tests would catch data quality regressions from the API before they reach the dashboard.

dbt also has documentation generation (`dbt docs generate`) that produces a browsable data catalog with descriptions, lineage graphs, and column-level documentation. Another thing worth adding.

The third item on the list is the **dbt semantic layer**. Rather than defining metrics like "goals per game" or "win rate" directly in dashboard SQL queries, the semantic layer lets you define them once in dbt and expose them as reusable, consistent metrics across any downstream tool. For a project where the same aggregations appear in multiple dashboard pages, this would eliminate duplication and make the numbers trustworthy by construction.

Next: a look at the API limits and infrastructure constraints that shape what this project can and cannot become.
