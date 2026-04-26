---
layout: post
title: "Building the Bronze Layer — Raw Ingestion"
date: 2026-04-11
categories: [data-engineering, ingestion]
---

The bronze layer has one job: pull data from the API and store it in the warehouse exactly as it arrived. No transformation, no business logic. If the API gives you a nested JSON blob, you store a nested JSON blob. The philosophy is that raw data is irreplaceable — once you transform it, you lose the original, and if your transformation logic turns out to be wrong you have nothing to go back to.

## The First Version Was a Monolith

The first version of the ingestion code was a single Python script that did everything: built URLs, called the API, handled pagination, and wrote to MotherDuck. It worked, but by the time it covered three or four endpoints it was already hard to follow. The first significant refactor split it into focused modules:

- `api.py` — the HTTP client, rate limiting, retry/backoff
- `db.py` — the MotherDuck connection
- `config.py` — endpoint configuration, environment variables
- `ingest_*.py` — one file per logical group of endpoints

That structure stayed for the rest of the project.

## The Rate Limiting Problem

api-football.com allows 10 requests per minute. The first version of the code just did `time.sleep(6)` between calls — six seconds per request keeps you just under the limit if every call takes zero time, which of course they do not. On fast calls the sleep is too short; on slow calls it is wasted time.

The proper solution is **retry with exponential backoff**: make the call, and if you get a 429, wait and try again. The wait doubles each retry with a small random jitter to avoid thundering herd problems. Here is the core of what we ended up with:

```python
def api_get(url, params, retries=5):
    for attempt in range(retries):
        response = requests.get(url, headers=HEADERS, params=params)
        if response.status_code == 200:
            return response.json()
        if response.status_code == 429:
            wait = (2 ** attempt) + random.uniform(0, 1)
            time.sleep(wait)
    raise Exception(f"API call failed after {retries} retries: {url}")
```

This was more correct than sleep-based limiting and also faster on days when the API was responding quickly.

## Idempotency: Delete-Before-Insert

One of the more important early decisions was how to handle re-runs. If the nightly pipeline fails halfway through and you re-run it, you do not want to double-insert yesterday's data. The pattern we chose was **delete-before-insert**: before inserting any records for a given date window, delete everything for that date window first. If the insert then succeeds, you have exactly one copy of the data. If it fails, the next run will delete and re-insert cleanly.

For full loads the pattern is a full table truncate before reloading. For incremental runs it is a targeted delete by date range — typically a rolling window of recent days to catch any late-arriving corrections from the API.

Getting this right took several iterations. One early bug was that the teams endpoint returns a JSON array of team objects, and the initial code was inserting the whole array as a single row rather than unnesting it first. Another was that the venues endpoint needed a `season` parameter that was not being passed, so it silently returned empty results for several seasons.

## 21 Endpoints

The final bronze layer covers 21 endpoints from the api-football.com free tier:

| Group | Endpoints |
|---|---|
| League | leagues, seasons, rounds, standings |
| Match | fixtures, fixture events, fixture statistics, fixture lineups, fixture player stats |
| Team | teams, venues |
| Player | players, top scorers, top assisters, top yellow cards, top red cards |
| Prediction | fixture predictions, fixture odds |
| Other | injuries, sidelined, trophies, coaches |

Each endpoint has its own ingestion script because the API parameters, pagination behaviour, and response shapes vary significantly. Some endpoints require a league ID and season. Some require a fixture ID and can only be fetched one fixture at a time (which is why fixture statistics alone accounts for a large chunk of the daily API call budget). Some, like odds and predictions, return data that changes right up until kick-off, so they need to be re-fetched regularly.

## Incremental vs Full Load

The ingestion runner supports two modes, controlled by a command-line flag:

- `--full-load` — truncate and reload everything from 2020 to the current season. Used for initial bootstrap and occasional corrective runs.
- Incremental (default) — fetch only the last N days of data (default 5). Used by the nightly GitHub Actions cron job.

The `--lookback` parameter controls how many days back the incremental run looks. Setting it to 5 rather than 1 gives a buffer for late-arriving data and ensures that matches played over the weekend are picked up reliably even if the cron runs only once per day.

The nightly schedule runs at **23:00 UTC**, which is midnight Danish time. That is late enough to catch the result of any evening match from the same day.

## A Note on the Season

One subtlety with football APIs: the "current season" is not always obvious. Superligaen runs on a split-season calendar — the 2025/26 season starts in mid-2025 and finishes in mid-2026. Whether you are in the "2025" season or the "2026" season depends on the calendar and the convention used by the API.

The first version of the code hardcoded `CURRENT_SEASON = 2024`, which was wrong. The second version tried to derive it from today's date using a heuristic (if month >= 7, season = year; else season = year - 1), which was better but still not correct around season transitions. The final version queries the leagues endpoint directly to find which season is currently active. The API knows — you should ask it.

## What Lands in Bronze

Every bronze table has a consistent shape: the raw API response JSON is stored in a `response` column of type `JSON`, alongside metadata columns like `inserted_at`, `season`, and sometimes `fixture_id` or `league_id` depending on the endpoint. No type casting, no column extraction — just the raw blob.

This means bronze is not useful for direct querying, but it is a perfect foundation for silver. If we ever decide that a silver transformation was wrong, we can drop the silver table and rerun the transformation against the unchanged bronze data. That is the point.

Next: turning the raw JSON blobs into structured, typed tables — and then into a Kimball dimensional model.
