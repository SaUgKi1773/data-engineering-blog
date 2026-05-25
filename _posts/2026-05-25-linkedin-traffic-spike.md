---
layout: post
title: "What Happens When You Share a Side Project on LinkedIn"
date: 2026-05-25
categories: [analytics, growth]
---

On April 25 I shared the Superligaen Analytics dashboard on LinkedIn. The next day, 45 people visited the site in a single day — more than the entire preceding week combined.

Here is what the traffic looked like over the 30 days that followed.

## The Numbers

**361 visitors, 6,232 page views, 16% bounce rate** — all over the last 30 days, up +247% and +164% respectively compared to the previous period. The bounce rate also dropped 5 points, meaning people who arrived were more likely to actually explore the dashboard rather than immediately leave.

The spike is visible and unambiguous. April 26 hit ~45 visitors, then traffic fell sharply over the following days and settled into a baseline of roughly 5–15 visitors per day. There was a smaller bump around May 17 — I have no good explanation for that one; probably someone reshared the post or linked to the project somewhere I am not tracking.

## Where the Visitors Came From

The geographic breakdown is exactly what you would expect from a Danish football dashboard shared on a personal LinkedIn profile in Denmark.

| Country | Visitors | Share |
|---------|----------|-------|
| Denmark | 287 | 80% |
| Türkiye | 34 | 9% |
| Germany | 23 | 6% |
| United States | 11 | 3% |
| Austria, Spain, Greece, Japan, Luxembourg, Sweden | 1 each | <0.5% |

Denmark dominates for obvious reasons — this is a Superligaen dashboard and the LinkedIn post was written in English but directed at a Danish professional network. Türkiye at 9% is likely my own network; I have a Turkish background and many connections there. Germany and the US are probably a mix of data engineering professionals who found the project interesting regardless of the football angle.

The long tail of single-visitor countries (Austria, Spain, Greece, Japan, Luxembourg, Sweden) is fun to see. Someone in Japan found a Danish football analytics dashboard. The internet is a weird and wonderful place.

## What a 16% Bounce Rate Actually Means

A 16% bounce rate is genuinely low. Industry averages for dashboards and data tools sit closer to 50–70%. It means that roughly 84% of visitors who landed on the site clicked through to at least one other page.

That matters more than raw visitor counts. 361 visitors who mostly explored the dashboard is a more useful signal than 1,000 who arrived and immediately left. The people who came were actually curious about Danish football data, not just clicking a LinkedIn link out of obligation.

## The Post-Spike Baseline

The more interesting number is not the spike but what comes after it. The floor settled at around 5–10 visitors per day with no further promotion. That is organic traffic from people finding the project directly — probably via search, GitHub, or someone sharing the link in a context I cannot see.

For a side project with no marketing budget and no SEO effort, that baseline feels like a meaningful signal that the thing is actually useful to someone.

## What I Would Do Differently

One thing I did not do before sharing: set up any kind of goal tracking or page-level analytics. I know the total visitor count and country breakdown, but I cannot tell which pages people spent the most time on, whether anyone clicked through to the About page, or whether the LinkedIn visitors behaved differently from the organic baseline visitors.

Vercel Analytics is good at privacy-first aggregation but limited in funnel analysis. Next time I share something, I want to at least check whether there is a page-level breakdown available before the spike happens — so the data is there to analyse afterwards.
