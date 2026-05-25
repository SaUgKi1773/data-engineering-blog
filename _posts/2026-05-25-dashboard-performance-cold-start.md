---
layout: post
title: "Fixing Cold-Start Failures in a DuckDB-WASM Dashboard"
date: 2026-05-25
categories: [data-engineering, dashboard, performance]
---

The match analysis section of the Superligaen dashboard had an annoying property: it worked perfectly if you had already visited another page. It failed silently if you opened it directly. On mobile it almost never loaded. This post is about diagnosing that failure and the architectural change that fixed it.

## How Evidence.dev Executes Queries

To understand the problem, it helps to understand how Evidence.dev's query execution model works in the browser.

Evidence is a static site generator. At build time, it runs the source SQL files against MotherDuck and produces Parquet files — one per source. These Parquet files are deployed alongside the site. The browser downloads the ones it needs for the current page, loads them into DuckDB-WASM (a full DuckDB engine compiled to WebAssembly), and runs the page SQL client-side against the in-memory data.

This means every page view goes through three sequential phases before any data appears:

1. DuckDB-WASM initialises in the browser
2. The required Parquet files download
3. The page queries execute

On a warm visit — where WASM is already initialised and Parquet files are cached — phases 1 and 2 take milliseconds. On a cold visit, phase 1 alone can take a few seconds depending on the device, and phase 2 depends entirely on file size and network speed.

## The Dependency Chain Problem

The match analysis page had a deeper problem on top of the cold-start delay: a four-hop query dependency chain.

The page had three dropdowns — season, round, and match — each populated by a query whose filter depended on the selection above it. The analysis queries (`mc`, `lineup`, `subs`, `discussions`) then filtered on the selected match ID. In Svelte terms:

```
inputs.season → rounds query → inputs.round → match_options query → inputs.match → mc / lineup / subs / discussions
```

On a warm visit, each hop resolves in milliseconds and the whole chain completes in under a second. On a cold visit, WASM is still initialising when the first queries fire. If timing was off, the intermediate queries returned empty and the downstream inputs never got seeded — so the analysis queries never ran. No data, no error, just silence.

The tempting fix was to add fallback values to each input (`?? '0'`, `?? -1`) to prevent Evidence from blocking query execution. This works against you: it makes the queries run immediately with invalid inputs, returning empty results, and then not re-running when the real inputs arrive because Evidence considers the query already resolved.

## The Fix: Split the Pages

The correct fix was to remove the dependency chain entirely by splitting the page in two.

`match-results.md` now contains only the results table and round KPIs. It loads a single Parquet file — `mart_match_results` at 58KB — and nothing else. Loading this page warms up DuckDB-WASM and caches the file.

`match-analysis.md` is a new hidden page (not linked from the sidebar or the home screen) that handles all the analysis: the head-to-head stats card, the lineup, and the fan forum. It receives the match ID via URL parameters rather than dropdowns.

The match names in the results table are rendered as HTML links:

```sql
'<a href="/match-analysis?match=' || cast(match_id as varchar)
    || '&season=' || season
    || '&round=' || cast(cast(match_round_number as integer) as varchar)
    || '" style="color:#2563eb;font-weight:600;text-decoration:none;">'
    || match_name || '</a>' as match_link
```

When the user clicks through, DuckDB-WASM is already warm, `mart_match_results.parquet` is cached, and the match ID is in the URL. The analysis page can run all its queries immediately without waiting for any dropdown interactions.

## Reading URL Parameters in Evidence.dev

Evidence.dev's page SQL templates support `${inputs.x.value}` to filter queries based on dropdown selections. There is no built-in mechanism to read URL query parameters and use them as inputs.

The workaround uses `onMount` (which Evidence.dev injects into every page's scope — do not import it explicitly, that will cause a "already declared" compilation error) to read `window.location.search` and manually seed the input context:

```javascript
import { getInputContext } from '@evidence-dev/sdk/utils/svelte';

const pageInputs = getInputContext();

onMount(() => {
  const sp = new URLSearchParams(window.location.search);
  const m = sp.get('match');
  if (!m) return;
  pageInputs.update(($i) => ({
    ...$i,
    match: {
      value: m,
      label: m,
      rawValues: [{ value: m, label: m, selected: true }]
    }
  }));
});
```

This fires immediately after the component mounts, before WASM has had a chance to time out on any query. Evidence.dev observes the input change and runs the queries. Because WASM is already warm from the previous page, they return quickly.

One thing that does not work in Evidence.dev page script blocks: `import { page } from '$app/stores'`. SvelteKit's `$app/stores` module is only importable from `.svelte` component files, not from compiled `.md` pages. `window.location.search` is the correct alternative.

## The Lineup Loading Bug

After the page split, the head-to-head stats card loaded correctly and the fan forum comments appeared. The lineup section remained blank — no formation, no player names, not even a loading indicator.

The root cause was a mismatched guard condition.

`MatchLineup.svelte` (the component rendering the formation grid) wraps all its output in `{#if allPlayers.length > 0}`. When the component receives an empty `lineup` prop, it renders absolutely nothing — no placeholder, no spinner, no message.

The page code was:

```svelte
{#if mc.length > 0}
  <MatchLineup {lineup} {subs} home_team={mc[0]?.home_team} ... />
{:else}
  <div>Loading lineup…</div>
{/if}
```

`mc` queries `mart_match_results` — the 58KB file that was already cached. It loaded in under a second. So `{#if mc.length > 0}` became true almost immediately, `MatchLineup` mounted with `lineup=[]`, and since `allPlayers.length === 0` the component rendered nothing. The "Loading lineup…" fallback was hidden.

`mart_match_lineup.parquet` is 907KB — fifteen times larger than `mart_match_results`. On a mobile connection it can take several seconds to download. During that window, the page showed a heading and a subtitle and nothing else, with no indication that anything was happening. Users navigated away.

The fix is one character of logic change:

```svelte
{#if lineup.length > 0}
  <MatchLineup {lineup} {subs} home_team={mc[0]?.home_team} ... />
{:else}
  <div>Loading lineup…</div>
{/if}
```

Now the loading placeholder is visible from the moment the page renders until `lineup` populates, regardless of how long the larger Parquet file takes to arrive.

## What This Taught Me About Static Dashboard Architecture

A few things became clearer through this work.

**File size is a first-class concern.** A 58KB Parquet file and a 907KB Parquet file have completely different loading characteristics on mobile. Keeping source files small — by pre-aggregating and filtering aggressively at build time — is not just a storage optimisation; it directly determines what the page feels like on a slow connection.

**Dependency chains multiply cold-start latency.** Each hop in a sequential query chain adds at least one round-trip through WASM. A chain of four means four sequential async operations before any useful data appears. Flattening chains — either by pre-joining in the source SQL or by passing state through the URL — eliminates this.

**Component silences are worse than loading states.** A blank space where content should be is not a neutral state. A user who sees nothing will assume the feature is broken. A user who sees "Loading lineup…" will wait. The visibility of the loading state matters as much as the actual load time.

**Page navigation warms the runtime.** Because WASM initialises once per browser session and Parquet files are cached after first download, the perceived performance of later pages in a session is dramatically better than the first page. Designing the navigation so that users visit the cheaper page first (results table) before the heavier one (lineup) is a form of prefetching that requires no additional infrastructure.
