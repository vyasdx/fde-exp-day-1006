# Session 4 — Runbook Template (filled)

FDE-1006 · Vedavyas Vayalpadu · 19 Sep 2026. Full version: `docs/handover/runbook.md` in the repo.

---

## 01 — System Overview

A .NET host containing an MCP server, an agent and a baked SQLite database, deployed as one Azure Container App. Its job is **account servicing for one authenticated customer session**: report balances and transaction history for accounts that session owns, normalise a US phone number, and submit wire transfers that pause above an approval threshold.

The boundary is narrower than "a banking agent" in two specific ways.

**It serves one session, not the bank.** Scope is enforced in SQL, not in the prompt. A request for an account outside the session never opens a database connection. The tool that lists accounts returns only that session's accounts — which is why its description now says so, after it advertised "every account on file" and returned one of three.

**It services existing products; it does not open new ones.** From my Session 1 triage: Tickets A, B and C are in scope, Ticket D is not. Product origination is owned by Retail Banking Product, carries KYC and suitability obligations this engagement does not hold, and no tool in the deployed surface writes to an origination system of record. That decision is now an enforced rule, `refuse-product-origination` in `governance/policy.yaml`, not just a note in a diagram.

**It also cannot do the thing Ticket C actually asked for.** The threshold pauses a transfer. There is no approval queue, no resume path and no audit table, so the searchable audit trail Risk asked for does not exist. That is a boundary, not an oversight, and it is the first item in "what would need doing next."

---

## 02 — Known Failure Modes

### Eval-step failures — the deploy is green and a milestone scores 0

The app is live and wrong. All three of these happened today, and each was caused by **hardening one dimension and silently moving another**.

| What you see | Cause | Where the fix went |
|---|---|---|
| M2 = 0, reply contains `$4,523.10` | prompt hardening diluted the exact-figure rule | rule 2 now forbids thousands separators |
| M2 = 0, reply asks for an account id | sharpened tool descriptions made the agent cautious about calling `list_accounts` | rule 5, "look before you ask" |
| M3 = 0, S6 only, "contains POSTED" | agent said "the transfer has **not** posted"; the S6 check is a substring match with no negation handling, unlike the HITL check which does handle it | rule 4 — quote the tool outcome, add no restatement |

**How to notice:** the top-level score is not enough. Read the per-scenario lines. One scenario failing once is model variance; the same one failing twice is a regression.

### Deploy failures

| What you see | Most likely cause | Fix |
|---|---|---|
| `ContainerAppOperationInProgress` on the GHCR step | **two deploys racing.** Push to main already deploys; dispatching as well starts a second run in the same second | push **or** dispatch, never both. Six red runs today were only this. |
| "stream timeout" in a browser, `/health` hangs, revision `Unhealthy` | `ImagePullBackOff`. The registry credential is the job-scoped `GITHUB_TOKEN`, which dies with the workflow, and Container Apps re-pulls on every container start | redeploy restores service. Durable fix is a persistent token with `read:packages`, or a public package. |
| ACA welcome page, `ActivationFailed` | ingress target port mismatch — quickstart apps default to 80, this image listens on 8080 | the pipeline corrects it |

**The most likely cause based on today: the deploy race.** It accounted for every red run that was not a genuine eval failure.

### The policy-change propagation chain

A threshold change has to reach **three** places, and only the last is proof.

```
governance/policy.yaml          -> what the eval grades
.azure/container-app.tmpl.yaml  -> what the app enforces
the running revision            -> what a customer experiences
```

Three ways it goes wrong:

1. **Edit only the policy.** The eval grades the new figure, the app enforces the old one, and **the pipeline goes green anyway** — the HITL check tests at threshold+1, which pauses under both the old and new values.
2. **Put a digit in a comment above the setting.** The eval takes the first line mentioning threshold, transfer or wire that contains a digit. For most of today that was a comment stating a default. Proven: with the setting at 7777.00 the eval still resolved 1000.00.
3. **Treat a green eval as proof.** It cannot distinguish a $500 app from a $2,500 app. Only a live transfer *between* the two figures can. When Risk lowered the threshold to $500 I verified by sending $600, which had posted before the change and now pauses, and $400, which still posts.

Use `scripts/set-threshold.sh <dollars>`. It edits both files, checks they agree, checks no comment carries a digit, and prints what the eval will resolve.

---

## 03 — What the Telemetry Shows

Pulled from my own Langfuse project, 172 traces.

| Metric | Your value | What "normal" means |
|---|---|---|
| **Eval scores** | M2 = 1, M3 = 1 | Both 1 every run. Any 0 means live but wrong — read the per-scenario lines. One scenario failing once is model variance; twice is a regression. |
| **Avg latency** | 3.05s (median 2.78s, p95 5.75s) | Under 6s is ordinary. p95 sustained above 10s is the gateway or the model, not this app. A one-off above 20s is a cold start — check for a recent revision change first. |
| **Cost / task** | ~$0.006 | Under $0.02 is normal. Above $0.05 means the prompt grew or a retry started. **Above $0.15 the agent is looping** — nothing caps spend, so check cost before assuming it is merely slow. |
| **Routing errors** | 0 | Must stay 0. Any non-zero is the gateway, not this app. `BLOCKED_BY_PROVIDER` inside a reply is different — that is the content filter working, expected on adversarial input. |
| **HITL pauses** | 1 per M3 run | Exactly one per run, plus one per real over-threshold transfer. **Zero across a run means the threshold is not being enforced** — and the eval alone cannot detect that. A sudden rise means the threshold dropped or someone is probing. |

**Extra metric worth carrying: tokens per call — in ~3,686, out ~142.** Input is roughly 25x output because the hardened prompt ships on every call. Input above ~5,000 without a prompt edit means context is accumulating. Output above ~500 means the agent is explaining rather than answering, which is exactly how the S6 regression happened.

**Caveat.** Token counts were hardcoded to zero until 09:41 today. Traces before that report a model and no usage, so any average across the full history understates cost. The figures above use instrumented calls only.
