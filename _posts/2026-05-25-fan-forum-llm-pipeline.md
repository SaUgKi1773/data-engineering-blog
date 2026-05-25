---
layout: post
title: "Building a Fan Forum with an LLM Pipeline"
date: 2026-05-25
categories: [data-engineering, llm, dashboard]
---

One of the more unusual features on the Superligaen dashboard is the Fan Forum on the match analysis page. Four fictional personas — a stats-obsessed analyst, an elderly lifelong fan, a passionate FC Nordsjælland supporter, and a referee-focused obsessive — post reactions to every completed match. The comments feel like a real forum thread because each persona has a defined character and they reference each other. This post is about how the pipeline behind it is built and the design decisions that shaped it.

## The Architecture

The fan forum follows the same bronze → silver → gold pattern as every other data flow in the project.

**Bronze** is a single table, `groq__llm_match_discussions`, that stores raw API responses from Groq (a hosted Llama inference API). One row per match, one `VARCHAR` column for the raw JSON string the model returns. Nothing is parsed at this stage — the goal is to land the data exactly as it arrived, so the bronze layer is a faithful record of what the model said.

**Silver** (`llm_match_discussions`) parses the raw JSON into one row per persona per match. The parsing is a single DuckDB expression:

```sql
FROM raw r,
     json_each(r.cleaned_response::JSON) j
SELECT
    r.match_id,
    j.value->>'persona'  AS persona_name,
    j.value->>'message'  AS message
```

`json_each` unnests the JSON array into rows. The `->>'persona'` syntax extracts the string value of the `persona` key from each element. The model is asked to return a JSON array of objects; this expression turns that into a normalised table.

**Gold** (`fct_match_discussions`) joins silver to `dim_match` and `dim_persona`, replacing the string `persona_name` and `match_id` with surrogate keys. From this point the data is just another fact table — the same join patterns and query conventions used everywhere else in the semantic layer apply.

The dashboard source (`llm_round_discussions`) queries the gold layer and filters by match for the fan forum section.

## Prompt Engineering

The prompt is built in Python and has three components: a rules block, a personas block, and a match data block.

The rules block is the most important. Without explicit constraints, a language model will generate plausible-sounding but fabricated football commentary. The rules block prevents this:

```
- Use ONLY the stats provided. Do not invent numbers, events, or facts not in the data.
- No xG — it is not available. Do not mention it.
- Each post must be 2-4 sentences, opinionated, and specific to this match.
- They should reference each other to feel like a real conversation thread.
- No generic football commentary — every sentence must be grounded in the match data.
```

The xG rule exists because xG is a common football metric that the model has seen extensively in training data and will reach for automatically. The project does not collect xG data, so any xG figure the model produces would be invented. The explicit prohibition eliminates this.

The match data block provides the context the personas react to: final score, half-time score, shots, big chances, possession, corners, cards, formations, coaches, referee, stadium, and player-level events (goals, assists, own goals, cards, saves, top performer by rating). Providing player names is critical — comments that name specific players feel grounded and specific; comments that only reference "the striker" or "the home team" feel generic.

The personas block lists each persona's name and bio:

```
- Flemming: 68-year-old lifelong Danish football fan. Watched the Superliga since it began...
- Søren: Data analyst in his early 30s. Trusts only the numbers...
- Rasmus: Passionate FC Nordsjælland fan. Always finds a way to bring it back to FCN...
- Ecem: Football officiating obsessive. Never misses a card, penalty decision, or controversial offside call...
```

The model is then told to write exactly four posts in a specified order and return only a JSON array. Forcing a fixed order and a machine-readable output format makes the silver-layer parsing trivial and deterministic.

## The Code Fence Problem

The model was asked to return a JSON array with no other text. A significant fraction of responses arrived like this:

```
```json
[
  {"persona": "Flemming", "message": "..."},
  ...
]
```
```

The model wrapped the output in a markdown code fence despite being told not to. The silver model strips it before parsing:

```sql
REGEXP_REPLACE(
    REGEXP_REPLACE(TRIM(raw_response), '^```(json)?\n?', ''),
    '\n?```$', ''
) AS cleaned_response
```

The first `REGEXP_REPLACE` removes an opening ` ```json ` or ` ``` ` fence. The second removes a closing ` ``` `. The `TRIM` handles leading and trailing whitespace. Because the raw response is preserved in bronze, the cleaning can be adjusted at any time by re-running the silver model — no new API calls required.

## Incremental Processing

The silver model is incremental on `generated_at`:

```sql
{% if is_incremental() %}
WHERE generated_at > (SELECT COALESCE(MAX(generated_at), '1970-01-01'::TIMESTAMP) FROM {{ this }})
{% endif %}
```

The gold model is incremental on `(match_sk, persona_sk)`:

```sql
{% if is_incremental() %}
WHERE NOT EXISTS (
    SELECT 1 FROM {{ this }} t
    WHERE t.match_sk = dm.match_sk AND t.persona_sk = dp.persona_sk
)
{% endif %}
```

The two strategies are different by design. Silver uses a timestamp watermark because a re-run with `--force` on the generation script replaces bronze rows with a new `generated_at` — the silver model needs to pick these up. Gold uses an existence check because the surrogate keys are stable; once a `(match_sk, persona_sk)` pair exists in gold, there is no reason to replace it unless the silver row was explicitly regenerated.

## Persona Design and Retirement

Each persona is defined in `dim_persona` with a `bio` column that the generation script injects directly into the prompt. The bio is the persona's character specification. The model uses it to shape tone, focus, and opinion — not just what the persona says, but how they say it.

The personas are designed to cover different angles of the same match. Flemming reacts emotionally to the scoreline. Søren interrogates the shot and possession numbers. Rasmus filters everything through FC Nordsjælland. Ecem focuses on cards, penalties, and referee decisions. A match with a clean 3-0 win and no cards will produce a happy Flemming, a validating Søren, an FCN comparison from Rasmus, and a note from Ecem that the referee had an easy afternoon.

Personas are retired rather than deleted. `dim_persona` includes an `is_active` flag. When Maja (the original fourth persona, an FC København supporter) was replaced by Ecem, she was marked `is_active = false`. The generation script filters to active personas only:

```python
SELECT persona_name, sort_order, bio
FROM dim_persona
WHERE is_active = true
ORDER BY sort_order
```

Because Maja's `persona_sk` is unchanged in the table, all existing `fct_match_discussions` rows for her matches still join correctly. Her comments remain visible in the fan forum for every historical match she was generated for. The dashboard does not know or care whether a persona is active — it just renders whatever rows are in the fact table.

This is a clean separation: the `is_active` flag controls future generation, not historical display. Retiring a persona costs one column value and no data migration.

## User Comments

The fan forum also accepts user comments, but these are never sent to a server. They are written to `localStorage` keyed by match ID:

```javascript
const entry = { text: commentText.trim(), time: new Date().toISOString().split('T')[0] };
userComments = [...userComments, entry];
localStorage.setItem(matchKey, JSON.stringify(userComments));
```

This is a deliberate architectural choice. The dashboard is a static site with no backend. Adding a comment store would require a database, authentication, and moderation — infrastructure that has ongoing cost and maintenance. `localStorage` gives each visitor a private comment thread that persists across sessions on their own device. It is not shared, but it is persistent, and it adds interactivity without any server dependency.

The LLM comments and the user comments render in the same list, visually indistinguishable except for the avatar style. The LLM posts carry persona initials in a coloured circle; user posts carry a neutral icon. The combined count displayed in the section header includes both.

## Rate Limits and the Free Tier

The generation script calls Groq once per match and sleeps two seconds between calls:

```python
time.sleep(2)  # stay within free-tier rate limits
```

Groq's free tier allows around 30 requests per minute on the Llama 3.3 70B model. A full round of six matches generates six API calls — well within the limit even without the sleep. The sleep is a conservative guard against burst errors on nights when multiple rounds are regenerated at once.

The model choice — Llama 3.3 70B — is deliberate. Smaller models produced noticeably worse output: generic comments, failure to follow the no-xG rule, and personas that sounded identical to each other. The 70B model follows the persona bios reliably and produces comments that feel distinct. The inference cost on the free tier is zero.
