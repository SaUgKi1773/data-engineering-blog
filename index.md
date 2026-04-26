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

---

**Live dashboard:** [superligaanalytics.vercel.app](https://superligaanalytics.vercel.app/)  
**Source code:** [github.com/SaUgKi1773/data-engineering-demo](https://github.com/SaUgKi1773/data-engineering-demo)
