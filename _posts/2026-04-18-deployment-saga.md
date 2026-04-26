---
layout: post
title: "The Deployment Saga — Netlify, Cloudflare, and Finally Vercel"
date: 2026-04-18
categories: [data-engineering, deployment, devops]
---

This is the chapter I wish someone had written before I started. The deployment story is not a story about bad tools — Netlify, Cloudflare Pages, and Vercel are all good products. It is a story about free tier constraints that are easy to overlook until you hit them, and about how a project with an unusual build profile (large data files, Node.js compilation, MotherDuck token handling) does not fit neatly into the assumptions any of these platforms make.

## Chapter 1: Netlify

I asked Gemini for a recommendation on where to host an Evidence.dev dashboard. The answer was Netlify. Netlify is a well-established static site hosting platform with a generous free tier, good documentation, and a GitHub integration that makes deployment trivially easy — push to main, Netlify rebuilds and deploys automatically.

I set it up. The first build worked. The dashboard was live. Everything looked fine.

The problem appeared five days later.

Netlify's free tier includes **300 build minutes per month**. An Evidence.dev build — installing npm dependencies, running `evidence sources` to query MotherDuck, compiling the dashboard — takes roughly 4 to 5 minutes. If the nightly pipeline triggers a rebuild every night, that is 35 minutes a week, 150 minutes a month. Still within the limit.

Except: during active development, every push to the main branch triggered a rebuild. In those five days, between debugging pipeline issues, iterating on dashboard pages, and fixing configuration problems, I triggered somewhere around 60 to 70 builds. That was essentially the entire monthly quota. On day five, Netlify suspended the site's builds until the next billing cycle.

I could not deploy. The site was frozen. I could have paid to upgrade, but paying for hosting on a side project did not feel right when the entire rest of the stack was on free tiers.

Netlify's build limit is reasonable for a normal static marketing site that deploys a few times a week. It is not designed for a project in active development or for a pipeline that rebuilds nightly with data freshness as a feature. In hindsight, the right approach would have been to build Evidence.dev in GitHub Actions and upload the output to Netlify using the CLI, bypassing Netlify's build system entirely. We eventually did implement this — but by then, there were other reasons to switch.

There were also token handling issues. Evidence.dev requires the MotherDuck token to be base64-encoded and written to a `connection.options.yaml` file before the build runs. Getting that into Netlify's build environment in a way that survived across the `npm run sources` step required several attempts and a dedicated CI step to write the file.

## Chapter 2: Cloudflare Pages

Cloudflare's market position is well-known. It runs a significant portion of the internet's DNS and CDN infrastructure. Cloudflare Pages is their static site hosting product, and it is genuinely fast — assets are served from Cloudflare's edge network, which means low latency everywhere. The free tier has **500 builds per month**, which solved the quota problem immediately.

I migrated. The site was up on Cloudflare Pages. The pipeline was working. Things were good.

Then the data grew.

Evidence.dev bundles the query results as Parquet files into the static build output. As we added more dashboard pages — match results going back to 2020, player stats, referee data — the build output got larger. Cloudflare Pages has a **25 MB file size limit** for individual deployable assets. 

The bundled Parquet data from the Evidence.dev build was a few megabytes over that limit. Cloudflare would not deploy it. We tried compression options, tried splitting queries to reduce individual file sizes, tried serving some data lazily — nothing moved the needle enough without significantly compromising the dashboard's performance.

This was a hard limit that Cloudflare was not going to lift on the free tier.

## Chapter 3: Vercel

At this point I sat down and compared all three platforms properly against what this project actually needs:

| Requirement | Netlify | Cloudflare Pages | Vercel |
|---|---|---|---|
| Builds per month | 300 | 500 | Unlimited (hobby) |
| Max file size | 100 MB total | 25 MB per file | 100 MB per file |
| Build timeout | 15 min | 20 min | 45 min |
| GitHub integration | ✓ | ✓ | ✓ |
| Cost | Free tier | Free tier | Free tier |

Vercel's hobby tier has **no monthly build limit** and a **100 MB per file limit**. Both problems solved.

The migration itself was straightforward — connect the GitHub repository, configure the build command (`npm run build`) and output directory (`build`), add the MotherDuck token as an environment variable. First build succeeded.

## The Deploy Hook Debugging Saga

The one complication with Vercel was controlling *when* it deploys. By default, Vercel rebuilds on every push to main. For this project, that would mean rebuilding every time a code change is merged — including changes that have nothing to do with the dashboard data. We only want to rebuild when the nightly pipeline finishes, or when manually triggered.

The initial approach was a Vercel **deploy hook** — a unique URL you POST to, and Vercel queues a build. The GitHub Actions pipeline would curl that URL at the end of the gold step.

This seemed simple. It was not.

The curl call was returning 200 but the build was not triggering. We added verbose logging to the curl command. The response body was correct. We added a separate test workflow that did nothing but curl the hook and report the response. It worked in isolation. When called from the main pipeline, it did not. 

The exact reason was never fully isolated. There were several issues layered on top of each other: the Vercel deploy hook behaves differently when called from a GitHub Actions runner on certain network configurations, there were permission issues with the GITHUB_TOKEN in the workflow, and at one point a test commit was made to check whether Vercel was even watching the right branch.

We eventually abandoned the deploy hook approach entirely and replaced it with a **dedicated deployment branch** — `publish_dashboard/vercel`. The nightly pipeline's final step makes an empty commit to that branch, and Vercel is configured to only watch that branch for deployments. The GitHub Actions step needs `contents: write` permission to push to a branch, which was another discovery made after the fact.

```yaml
- name: Push to Vercel deploy branch
  run: |
    git config user.email "github-actions@github.com"
    git config user.name "GitHub Actions"
    git checkout -B publish_dashboard/vercel origin/main
    git commit --allow-empty -m "chore: nightly data refresh $(date -u '+%Y-%m-%d %H:%M UTC')"
    git push origin publish_dashboard/vercel --force
```

This approach is more reliable than a webhook because it uses standard git push semantics, which GitHub Actions handles correctly, and Vercel's Git integration handles correctly. The empty commit triggers the deploy without cluttering the main branch history.

## Lessons

If I were starting over, I would evaluate hosting platforms against the specific build profile of the project — build frequency, output size, build time — before committing to anything. The differences between free tiers are not academic; they determine whether your project actually works at the end.

For Evidence.dev specifically, Vercel is the right choice as of today. Unlimited builds, large file support, straightforward integration. The deploy hook is unreliable and the branch-push approach is better.

Next: one of the most impactful refactors in the project — migrating the transformation layer to dbt.
