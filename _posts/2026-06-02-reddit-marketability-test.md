---
layout: post
title: "How I Built a Commercial-Grade Sports Analytics Product for Danish Superliga — at Zero Recurring Cost"
date: 2026-06-02
categories: [analytics, growth]
---

Three days ago I posted a side project to Reddit and was not sure what to expect. The response surprised me — not because people were polite about it, but because they actually *used* it. This is the story of how that project came to be, what is under the hood, and what happens when you find out a pet project might be something more.

## The Gap Nobody Filled

The official Danish Superliga stats sites are solid. Good data, well presented. But what they offer is mostly a stats surface — numbers, tables, league standings. What is missing is the *analytical layer*: contextual metrics, trends over time, player comparisons across dimensions, a proper data model that lets you ask questions the raw numbers cannot answer.

The commercial analytics platforms that go deep — your Optas and StatsBombs of the world — do not cover Superliga at this level of detail, and if they did, access would cost thousands a year.

So there was a genuine gap. Not because nobody cared about Danish football, but because nobody had built the right thing yet.

## It Started as Curiosity

I am a data engineer. I wanted to actually *analyse* the league I follow — not just look up scores. So I started pulling data from the SportMonks API and transforming it locally. No grand plan. Just a question: how good can I make this, and what will it cost me?

The constraint of zero recurring cost turned out to be a feature, not a limitation. Every architecture decision had to be justified. Nothing could be lazy. If something could be pre-computed, it had to be. If a service had a free tier, I had to understand its limits deeply enough to stay inside them. That discipline produces better engineering than an open budget often does.

At some point the project crossed a line. It stopped feeling like a hobby and started feeling like something you would pay for.

## The Stack

Here is what the full pipeline looks like, from raw data to the browser:

**Ingestion:** SportMonks API → Python ingestion scripts → raw data layer. Fixtures, player stats, match events — everything lands in a structured raw layer before any transformation touches it.

**Transformation:** dbt handles all modelling. This is where the real work happens — more on this below.

**Warehouse:** MotherDuck (DuckDB in the cloud). Analytical queries, free tier, no server to manage.

**BI layer:** Evidence — a code-first BI framework where dashboards are Markdown files with SQL queries embedded. Version-controlled, deployable like any other app.

**Hosting:** Vercel. Push to main, the dashboard deploys.

**Orchestration:** GitHub Actions. The entire pipeline — ingestion, transformation, dashboard build, deploy — runs automatically on a schedule. No manual runs. No babysitting.

Total monthly cost: **€0**.

## The Data Model Is the Product

This is the part that separates analytics from a stats dump.

Most sports data sites show you what happened. A proper data model lets you ask *why*, *compared to what*, and *how consistently*. That requires thinking carefully about how you structure the data before a single dashboard gets built.

The project uses a three-layer dbt architecture:

- **Bronze (staging):** Raw API data cleaned and typed. One source of truth per entity.
- **Silver (intermediate):** Business logic applied. Match context added, player-level aggregations computed, slowly-changing dimensions tracked with surrogate keys.
- **Gold (marts):** Fact and dimension tables purpose-built for the BI layer — `fct_player_match_stats`, `dim_players`, `fct_match_events`. The kind of model you would find in a well-run data team at a mid-sized company.

That gold layer is what powers the dashboards: player radars with multi-dimensional scoring, match flow visualisations, head-to-head comparisons, season trend lines. None of that is possible without the model underneath.

The official sites have the data. What they do not have — and what took the most time to build — is the layer that turns data into answers.

## The Marketability Test

Once the product felt genuinely good, I wanted to know if anyone else thought so. Rather than guessing, I ran an experiment: I posted to r/sportsanalytics with the honest framing — *"I built a fully automated analytics product for Danish Superliga — with NO recurring cost"* — and watched what happened.

r/sportsanalytics is a technical audience. Data scientists, analysts, engineers who work in sports. They are not going to upvote something out of politeness.

After three days:

| Metric | Value |
|--------|-------|
| Reddit views | 6,200 |
| Upvotes | 20 |
| Upvote ratio | 85.7% |
| Comments | 13 |
| Site visitors (7 days) | 129 |
| Page views (7 days) | 1,910 |
| Bounce rate | 14% |
| Pages per visitor | ~15 |

The site metrics told the more interesting story. Of the roughly 130 visitors who clicked through from Reddit, 86% explored beyond the landing page, and the average session covered around 15 pages. Traffic held at roughly three times the pre-post baseline for days after the initial spike — a sign of return visits and word-of-mouth, not just a one-day curiosity bump.

**The most surprising finding:** Denmark accounted for only 8.1% of views. The US was 26%, the UK 9.5%, and more than half came from everywhere else. A product built for a specific Danish audience travelled almost entirely on the strength of the engineering story — the zero-cost architecture, the automation, the data model. The football content was almost incidental to who showed up.

That is a meaningful signal. It means the approach is transferable. The same stack, the same discipline, could work for any league with an accessible data source.

## At What Point Does a Pet Project Become a Product?

I do not have a clean answer to that. But I think the line is somewhere around when strangers start using it the way you intended — not just clicking around, but actually exploring, comparing players, following a question through multiple pages.

Fifteen pages per visitor suggests that happened. People were not just looking at the homepage. They were using it.

What I built has a proper data model, a fully automated pipeline, version-controlled dashboards, and zero operational overhead. By most definitions, that is a production system. The question of whether it is a *product* — something with users, with a value proposition someone would pay for — is still open.

The r/sportsanalytics audience validated the technical angle. What I have not tested yet is whether the football content itself resonates with the people who actually follow the league. That is the next experiment: posting to Danish football communities, where nobody cares about dbt or MotherDuck, and seeing if the analytics stand on their own.

That result will tell me something different. And I will write about it when it is in.

---

*The project is live at [superligaanalytics.vercel.app](https://superligaanalytics.vercel.app). The source code is on [GitHub](https://github.com/SaUgKi1773/data-engineering-demo).*
