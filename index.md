---
layout: home
title: "Building Superligaen Analytics"
---

This blog documents the end-to-end journey of building [Superligaen Analytics](https://superligaanalytics.vercel.app/) — a live data engineering project that ingests football data from the Danish premier league, transforms it through a medallion architecture, and serves it on a public dashboard.

The project was built in roughly **10 days** in April 2026, and almost nothing went according to the original plan. Every major tool choice had to be revisited at least once. This is the honest account of what happened, why, and what I'd do differently.

---

**Posts in order:**

1. [The Idea — Why I Built This]({{ site.baseurl }}{% post_url 2026-04-09-the-idea %})
2. [Choosing a Data Source]({{ site.baseurl }}{% post_url 2026-04-10-choosing-the-data-source %})
3. [Building the Bronze Layer — Raw Ingestion]({{ site.baseurl }}{% post_url 2026-04-11-building-the-bronze-layer %})
4. [Silver and Gold — Transforming Data into a Star Schema]({{ site.baseurl }}{% post_url 2026-04-14-silver-and-gold-layers %})
5. [The Dashboard — Discovering Evidence.dev]({{ site.baseurl }}{% post_url 2026-04-16-building-the-dashboard %})
6. [The Deployment Saga — Netlify, Cloudflare, and Finally Vercel]({{ site.baseurl }}{% post_url 2026-04-18-deployment-saga %})
7. [Migrating to dbt — When Raw SQL Isn't Enough]({{ site.baseurl }}{% post_url 2026-04-18-dbt-migration %})
8. [Adding Web Analytics — Vercel and Cloudflare]({{ site.baseurl }}{% post_url 2026-04-19-launch-and-analytics %})
9. [Global Launch — A Conclusion]({{ site.baseurl }}{% post_url 2026-04-19-global-launch %})
10. [What's Next — The Road Ahead]({{ site.baseurl }}{% post_url 2026-04-20-whats-next %})
11. [Why We Migrated from api-football to Sportmonks]({{ site.baseurl }}{% post_url 2026-04-25-switching-api-providers %})
12. [Data Quality Tests — Making the Pipeline Fail Loudly]({{ site.baseurl }}{% post_url 2026-04-29-data-quality-tests %})
13. [Building the Player Analytics Layer]({{ site.baseurl }}{% post_url 2026-05-05-player-analytics-layer %})
14. [Organising the Semantic Layer — From Raw Models to Mart Views]({{ site.baseurl }}{% post_url 2026-05-11-organising-the-semantic-layer %})
15. [Advanced BI Techniques — Making the Data Say More]({{ site.baseurl }}{% post_url 2026-05-17-advanced-bi-techniques %})
16. [Fixing Cold-Start Failures in a DuckDB-WASM Dashboard]({{ site.baseurl }}{% post_url 2026-05-25-dashboard-performance-cold-start %})
17. [Building a Fan Forum with an LLM Pipeline]({{ site.baseurl }}{% post_url 2026-05-25-fan-forum-llm-pipeline %})
18. [What Happens When You Share a Side Project on LinkedIn]({{ site.baseurl }}{% post_url 2026-05-25-linkedin-traffic-spike %})
19. [How I Built a Commercial-Grade Sports Analytics Product for Danish Superliga — at Zero Recurring Cost]({{ site.baseurl }}{% post_url 2026-06-02-reddit-marketability-test %})

---

**Live dashboard:** [superligaanalytics.vercel.app](https://superligaanalytics.vercel.app/)  
**Source code:** [github.com/SaUgKi1773/data-engineering-demo](https://github.com/SaUgKi1773/data-engineering-demo)
