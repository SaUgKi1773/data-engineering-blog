---
layout: post
title: "Going Multi-League — A Stranger Asked for Scotland, and the Warehouse Said Yes"
date: 2026-07-05
categories: [data-engineering, data-modeling, dbt, multi-league]
---

Three weeks ago a GitHub issue landed on the project from someone I'd never met: *"I would like to see the statistics for the Scottish league too."* One sentence, no code, no context. For a portfolio project that had exactly one league, one website, and one user I could name (me), that issue was the most valuable artifact the project had ever produced — proof that a stranger looked at the thing and wanted more of it.

This weekend we shipped it. The Danish Superliga site now has a sibling — [Scottish Premiership Analytics](https://scottishpremiershipanalytics.vercel.app/) — and both live under a new parent, the [Krogvad Analytics Hub](https://krogvadanalyticshub.vercel.app/). This post is the story of what it actually took to turn a single-league pipeline into a multi-league platform: which parts of the model were ready, which parts only *pretended* to be ready, and the three places where "Denmark" turned out to be hiding in the code wearing a fake moustache.

## The feasibility gift

The first question was brutally practical: do we even have the data? The project runs on Sportmonks' free plan, and the free plan includes exactly two leagues. One is the Danish Superliga. The other — I promise I'm not making this up — is the Scottish Premiership. The one league a user had asked for was the one league we could add without spending a krone. Some days the universe just hands you a roadmap.

The warehouse side looked equally friendly. The gold layer had been built league-agnostic from the start: `dim_league` existed, every fact carried a `league_sk`, and a month earlier we'd league-scoped all the dashboard marts as a defensive move. No dbt model hard-coded the league anywhere. On paper, multi-league was a config change.

On paper.

## Ingestion: where "one league" was load-bearing

The ingestion layer was pinned to Denmark in a way the warehouse never was: a `LEAGUE_ID = 271` constant baked into API paths, and — more subtly — bronze rows that carried `_season_id` and `_fixture_date` metadata columns but had no idea which league they belonged to. That second part mattered more than it looks, because of how our refresh strategies work: fixtures are deleted and reloaded by *date window*.

Picture the naive version. You run a Scotland-only backfill for one season. The engine deletes every fixture in that date window — *both leagues', because the delete can't tell them apart* — then refetches and keeps only Scottish rows. Congratulations: you've silently destroyed fifteen years of Danish fixtures in bronze. The fix was to make league a first-class metadata column, exactly like season and date:

```
(id, raw_json, _season_id, _fixture_date, _league_id, _ingested_at)
```

New rows get tagged at insert time. Legacy rows got a one-time idempotent backfill that reads the league out of each row's own payload (or, for season-scoped tables whose payloads don't carry it, joins through the season→league map). Once every row knows its league, deletes can be league-scoped, and a `--leagues 501 --seasons 2025/2026` run can touch Scotland without being *able* to touch Denmark. We rehearsed exactly that run against a full clone of prod and diffed the Danish counts afterwards: byte-identical.

One pleasant surprise: adding the second league barely increased API traffic. The fixtures endpoint returns every league in a date window anyway (we filter client-side), and the Danish and Scottish seasons run on the same autumn-to-spring calendar — so we merge the overlapping season ranges and fetch each calendar window exactly once. Two leagues, one pass.

## The bug that was waiting sixteen years

`dim_date` labels each calendar date with its season by joining the date against season ranges. With one league, a date matches at most one season. The moment Scottish seasons arrived, almost every date matched *two* — Denmark's 2015/2016 and Scotland's 2015/2016 overlap by nine months — and `dim_date` quietly doubled: 4,768 duplicate dates, which fanned out through every fact join into duplicated matches and transfers. The uniqueness tests caught it within minutes of the first dual-league build, which is the whole reason those tests exist.

The interesting part is the fix. The band-aid (deduplicate, let the lower league id win at the edges) worked, but it papered over the real modelling truth: **season boundaries are a per-country concept**, and a single `season` column on a calendar dimension can't represent two countries' calendars — let alone a future league that plays spring-to-autumn. So `dim_date` now carries per-country season columns:

```sql
LEFT JOIN season_ranges dk  ON d BETWEEN dk.season_start  AND dk.season_end  AND dk.league_id  = 271
LEFT JOIN season_ranges sco ON d BETWEEN sco.season_start AND sco.season_end AND sco.league_id = 501
```

`season_denmark` and `season_scotland`, each from its own join, each matching at most one season — uniqueness by construction, no tie-breaks. The legacy `season` column stayed as a pure-Danish alias so the existing site didn't move a pixel.

## The vendor doesn't know what a season phase is called

The Scottish Premiership has "the split": after 33 rounds the table divides into a top six and a bottom six. Our marts derive the post-split grouping from `match_round_type`, which for Denmark works beautifully because Sportmonks names Danish stages semantically — `Championship Round`, `Relegation Round`. For Scotland? Both halves of the split are labelled `2nd Phase`. And the pre-split stage is called `Regular Season` in 2025/26 but `1st Phase` in 2026/27. Same league, same structure, different names in consecutive seasons.

The real signal lives somewhere else entirely: each post-split fixture carries a *group* object, and Sportmonks names the Scottish groups — I could have kissed them — `Championship Group` and `Relegation Group`. Exactly our vocabulary.

My first instinct was to bolt on a new `match_group_name` column and teach the Scottish marts to read it. That got (rightly) rejected in review: it would have meant two mechanisms for one concept, with every downstream consumer needing to know which league uses which. The better answer was to conform the *existing* attribute inside the data model:

```sql
CASE
    WHEN f.league_id = 501 AND f.group_name = 'Championship Group' THEN 'Championship Round'
    WHEN f.league_id = 501 AND f.group_name = 'Relegation Group'   THEN 'Relegation Round'
    WHEN f.league_id = 501 AND sg.name      = '1st Phase'          THEN 'Regular Season'
    ELSE sg.name
END AS match_round_type
```

League-guarded, so Danish rows structurally cannot change (we proved it with an `EXCEPT` diff against untouched prod: zero rows). And the payoff is the reason this principle exists: after conforming the dimension, the Scottish site's marts are **line-identical to the Danish ones** except for a league id and the season column. No dashboard quirks. The complexity lives in the model, once.

## Constants have nationalities

The sneakiest bugs weren't in the pipeline at all. They were innocent-looking constants that turned out to be Danish:

- The stadium analytics mart filters out bad venue coordinates with a lat/lon bounding box. A *Danish* bounding box. Scottish longitudes are negative — every single Scottish stadium was silently excluded, and the page rendered zero rows.
- Kick-off times were converted to `Europe/Copenhagen` for everyone. Scottish fans would have seen every match an hour late.
- Team short codes come from the API when our curated seed doesn't cover a club — and the API thinks both Dundee *and* Dundee United are `DUD`.

None of these were findable by grepping for "271" or "Superliga". The lesson that stuck: when a codebase has only ever known one country, its constants absorb that country — coordinates, timezones, team counts, even letter-spacing in the logo. A second league is the only test that finds them.

## Shipping it, and what it became

The release itself was almost boring, which was the point: we rehearsed the entire sequence twice (once locally, once against a `COPY FROM DATABASE` clone of prod), so the production run was a re-execution of something already proven — 21 minutes of scoped backfill, silver, gold, and 126 quality tests later, Scotland was in prod and the Danish site hadn't moved.

Then came the part I didn't expect to enjoy so much: the repo grew a second website. `dashboards/` became a parent folder with one Evidence project per league, each site's hero banner now wears its flag (Dannebrog red, Saltire blue — dark-to-light, with the white of each flag carried by the typography), and a third, tiny Evidence project became the [Krogvad Analytics Hub](https://krogvadanalyticshub.vercel.app/): a group-company front door with live, build-time KPIs. Two leagues. Seventeen seasons. 3,512 matches, 9,794 goals, 2,254 players, 11,759 transfers — numbers that update themselves every night because the hub rides the same publish pipeline as everything else.

And the user who asked? Their issue closed automatically when the PR merged, seventeen days after they opened it. The whole stack still costs nothing to run.

## What's next

The second league was the hard one — it's the difference between "a project about Danish football" and "a platform that happens to have two leagues". League three is a config entry, a seed file, and a folder copy. Before that, though, there's a model we've been sketching: build-time win probabilities for upcoming fixtures, computed in pure SQL, with an honesty page that scores the predictions against reality. A match predictor on free infrastructure. That one's going to be fun.
