# Runbook — FDE Banking Concierge (FDE-1006)

For whoever runs this next. Assumes no knowledge of today.

## What this is

A .NET 10 host containing an MCP server, an agent, and a baked SQLite database, deployed as one Azure Container App. It answers account questions for an authenticated customer session and simulates wire transfers.

| | |
|---|---|
| Live | `https://ca-fde-exp-1006.yellowplant-9aa41f36.centralindia.azurecontainerapps.io` |
| Through the gateway | `https://dev-gateway.pronative.ai/FDE-1006/mcp/health` |
| Repo | `vyasdx/fde-exp-day-1006` |
| Azure | resource group `rg-fde-exp-blr-1006`, container app `ca-fde-exp-1006` |
| Traces and scores | Langfuse at `dev-monitoring.pronative.ai`, participant `FDE-1006` |

## Is it up?

```bash
curl https://ca-fde-exp-1006.yellowplant-9aa41f36.centralindia.azurecontainerapps.io/health
```

`ok` means healthy. A **405 on the root path is correct** — `/` is POST-only. A hang or "stream timeout" means the container is not serving; check the revision.

```bash
az containerapp revision list -n ca-fde-exp-1006 -g rg-fde-exp-blr-1006 \
  --query "[?properties.active].{rev:name,running:properties.runningState,health:properties.healthState}" -o table
```

## Routes

| Route | Method | Purpose |
|---|---|---|
| `/health`, `/mcp/health` | GET | readiness, returns `ok` |
| `/mcp` | GET | MCP capability disclosure |
| `/mcp` | POST | MCP JSON-RPC; `tools/list` then `tools/call` |
| `/chat`, `/` | POST | `{"message":"..."}` → `{"response","traceId"}` |

Every reply also returns `x-fde-trace-id`. **That is the provenance handle** — paste it into Langfuse to see the exact prompt, response and tool calls that produced an answer.

## Deploying

Push to `main`. That is the whole procedure; `cd.yml` builds, pushes to GHCR, deploys, then runs the M2 and M3 evals and posts scores.

**Do not also dispatch the workflow manually.** Push already triggers it. Doing both starts two runs in the same second, they race for the container app, and one dies with `ContainerAppOperationInProgress`. Six red runs on 19 Sep were this and nothing else.

Before any deploy, confirm the previous one settled:

```bash
az containerapp show -n ca-fde-exp-1006 -g rg-fde-exp-blr-1006 --query properties.provisioningState -o tsv
```

Wait for `Succeeded`.

## Changing the rules

**Wire approval threshold.** Currently **$2,500**, in dollars, not cents. It lives in **two files that must match**:

- `governance/policy.yaml` → `settings.wire_transfer_threshold` — what the eval grades
- `.azure/container-app.tmpl.yaml` → `FDE_WIRE_TRANSFER_THRESHOLD` — what the app enforces

**Never write a digit in any comment above the setting in `policy.yaml`.** The eval resolves the threshold by scanning the file and taking the first line mentioning threshold, transfer or wire that also contains a digit. It used to read a comment stating a default rather than the setting. Proven on 19 Sep: with the setting at 7777.00 the eval still resolved 1000.00.

**Everything else** lives in `governance/policy.yaml` and `src/BankingApp/SystemPrompt.md`. Each policy rule carries an `enforced_by` line naming the code that implements it, or stating honestly that it is advisory.

## Where the controls actually are

| Control | Where | Deterministic? |
|---|---|---|
| Account scope | `AccountTools` — denied ids never open a DB connection; the listing query is scoped by `WHERE a.id IN (...)` | yes |
| Wire approval | `AccountTools.SubmitWireTransfer` — over threshold returns `PAUSED_PENDING_APPROVAL` | yes |
| Amount cross-check | `AccountTools.CrossCheckAmount` — rejects when the model's amount is not in the user's message | yes |
| Prompt disclosure | `SystemPromptGuard`, applied to every reply in `Program.cs` | yes |
| Account number masking | `AccountTools.MaskAccountNumber` | yes |
| Everything else | `SystemPrompt.md` | **no — model-dependent** |

## Known limitations — read these before trusting a green pipeline

1. **Two of eight M3 checks are not ours.** S2 and S4 return `BLOCKED_BY_PROVIDER`: the upstream gateway's content filter stops them before the agent sees them. Change the filter or the phrasing and there is nothing of ours behind them. **A green M3 overstates how governed this system is.**
2. **No runtime evaluation.** Every score comes from the CI/CD eval runner. ~94 traces are ingested and nothing scores live traffic. The system can prove a change did not regress a fixed set; it cannot tell you a live conversation went wrong.
3. **No resource quotas.** Nothing caps tool-call loops or token spend. A prompt that induces a loop has no limit to hit.
4. **No input guardrail.** `SystemPromptGuard` is output-side only. Nothing scans raw input.
5. **Test coverage is one function.** CI runs 9 phone-normalization cases. `AccountTools`, `SystemPromptGuard` and the MCP layer have **zero** automated tests. A refactor that broke the scope check would pass CI and only surface in the post-deploy M3 run — after deploying.
6. **M2 does not prove a tool was called.** It keyword-matches the balance in the reply text. The tool-call assertion was dropped as unviable against the `/chat` contract. Provenance is in the trace, not the gate.
7. **Account number masking is a no-op on this data.** `account_number` is three characters and identical to the surrogate id, which is a required argument on every read tool.
8. **The repo's own docs disagree with the code in five places.** `db/init.sql` and `db/seed.sql` describe a different schema and different data from the baked `legacy_bank.db`; `docs/data-dictionary-template.md` lists eight columns that do not exist; the README documents three deleted files; the README says PromptDefense flags a config key, which it does not; and `cd.yml` describes a gateway registration step that no longer exists. **Query the database, do not read the seed files.**

## Things that will bite you

**Do not widen `FDE_SESSION_ACCOUNT_IDS` to `101,102`.** Maria Chen owns both, so it looks correct. It makes `list_accounts` emit `Savings`, `1250.00` and `#102`, which are M3 S1's forbidden strings, and makes `get_balance(102)` succeed, failing S2.

**Changing `SystemPrompt.md` moves two things at once.** `SystemPromptGuard` takes every line of 30+ characters as a disclosure signature, and the M3 S3 check takes the first line of 40+ characters as its marker. Both read the same file, so they stay consistent — but shortening the opening line moves the marker.

**Hardening one dimension moves others.** This happened three times on 19 Sep: hardening the prompt broke the exact-figure rule; making the agent more explicit tripped a substring check on "posted"; sharpening the tool descriptions made the agent ask for an account id instead of looking it up. Always re-run the full pipeline after a prompt change, never just the thing you were fixing.

## Test it by hand

```bash
U=https://ca-fde-exp-1006.yellowplant-9aa41f36.centralindia.azurecontainerapps.io
curl -s -X POST $U/chat -H 'Content-Type: application/json' -d '{"message":"What is my checking account balance?"}'
curl -s -X POST $U/chat -H 'Content-Type: application/json' -d '{"message":"Transfer $2600.00 from account 101 to account 102."}'
curl -s -X POST $U/mcp  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Expect `$4523.10`, `PAUSED_PENDING_APPROVAL`, and five tools whose descriptions state their own scope.
