# Solution Boundaries Worksheet — Stage 1 → M1

FDE-1006 Vedavyas Vayalpadu. Feeds the M1 topology annotation and Stage 3's `governance/policy.yaml`.

## Part 1 — Scope boundary

| Ticket | Area | Call | Why |
|---|---|---|---|
| **A** | Contact Center | **In scope, today** | Read-only balance and history lookup. Tool surface already serves it: `get_balance`, `get_transaction_history`. No new data path. |
| **B** | Fraud & Security | **In scope, today** | Phone-format inconsistency is a deterministic bug in `PhoneNormalizer.NormalizePhone`. Live security gap, not a data-quality nuisance. |
| **C** | Risk & Compliance | **In scope, governed** | Wire approval above threshold. Already modelled as `submit_wire_transfer` + `PAUSED_PENDING_APPROVAL`. Stage 3 sets the rule. |
| **D** | Retail Banking, Product | **Out of scope** | See below. |

**Ticket D exclusion, as an enforceable rule:**

> Opening new account types (CDs, personal loans) is **product origination**, owned by Retail Banking Product. Account servicing is what this engagement covers. Origination carries KYC and suitability obligations this engagement does not, and the deployed tool surface has no write path to any origination system of record: the five tools are `get_balance`, `list_accounts`, `get_transaction_history`, `normalize_phone`, `submit_wire_transfer`. Servicing an existing product is in scope. Opening a new one is not. Client filed it Priority Medium against High for A, B and C.

Enforcement: the agent must refuse origination requests rather than answer helpfully. Add as a Stage 3 rule, not a prompt instruction.

## Part 2 — Data boundary (the masking line)

**Where the line goes: at `AccountTools`' return, inside the container, before anything reaches the agent.**

Confirmed against the as-built deployment diagram: one Azure Container App, the SQLite file inside it, the MCP server in-process with no network hop. There is no internal network to draw a line across. The boundary is a code boundary with two halves, both in `AccountTools`:

- **Scope check — which rows are fetched.** Already implemented.
- **Redaction — which fields leave.** Marked "MUST REDACT HERE" on the as-built diagram. **Not implemented yet:** `get_balance` still emits the full `account_number` as `#101`.

The boundary is the point where a tool call either does or does not retrieve a row belonging to someone other than the authenticated customer. It is enforced in code, before any data is assembled into something the model could see or repeat.

Cited precisely:

| Line | `src/BankingApp/Tools/AccountTools.cs` |
|---|---|
| 107 | `var allowed = EffectiveAccountIds;` |
| 110 | `return Denied(accountId, allowed);` — returns before a connection is opened |
| 113 | `using var connection = _db.Create();` — reached only for in-scope ids |
| 149 | `WHERE a.id IN ({allowed})` — the listing query is itself scoped |

**The mistake this avoids.** Drawing the boundary as a scrubbing step between the database and the cloud model call, as though raw data is fetched and then redacted before it leaves. That is not how this system works. Out-of-scope data is never fetched, so there is nothing to redact downstream, because the query never runs for rows outside the authenticated customer's scope. Annotate at the *query*, not at a transit or network point.

The agent-to-gateway hop is transit. Marking it as the boundary implies redaction in flight, which does not exist here and would be a weaker design if it did.

### What the model can therefore ever see

| Data | Reaches the model | Why |
|---|---|---|
| Balance of an in-scope account | Yes, exact | M2 grades the exact figure; `SystemPrompt.md` rule 2 forbids rounding |
| Name and account number of the session's own account | Yes | Already inside scope; the scope check is the control |
| Transaction descriptions for in-scope accounts | Yes | Required for Ticket A. Residual: free text, unconstrained |
| Any other customer's row | Never | The query does not run for it |
| Schema or raw table contents | Never | No tool exposes them |

Field-level masking of an in-scope account number is a *separate*, secondary control at response assembly. It is defensible but it is not the masking boundary, and conflating the two is the error above.

### The `normalize_phone` finding

`normalize_phone` is a pure deterministic function. It strips non-digits and prefixes `+1`. It requires no model, no reasoning, and no judgement.

Exposing it as a conversational MCP tool means a raw phone number travels through the agent conversation and into the public-cloud model path, to perform a transformation ordinary code does perfectly. This is the keynote's "no model" tier exactly: *if ordinary code can do the job, no model should.* Routing it through the model costs a frontier-tier call and puts PII in a third party's context, for a regex.

**Verified:** the deployed database has no phone column, so no stored phone data crosses this line today. A phone number reaches the model only because a user typed one into chat. The finding is therefore about tool design, not a live data leak.

**Decision:** normalisation belongs behind the masking line as a server-side function. Keeping it in the tool catalogue is acceptable for the demonstration, and it is what the nine-case test grades, but a production Ticket B fix is a batch job over the client's real customer table, not an agent normalising one number per conversational turn.

## Part 3 — Known limitations (name them, do not hide them)

1. **`db/` is stale provenance and contradicts the deployed database.** The README states the baked `src/BankingApp/legacy_bank.db` "was built from `db/init.sql` + `db/seed.sql`". It was not. Verified by direct query:

   | | `db/seed.sql` + `db/init.sql` | baked `legacy_bank.db` (what the app opens) |
   |---|---|---|
   | customers | 10, with `phone_raw`, `email`, `created_date` | **2** (Maria Chen, Robert Davis), columns `id` + `name` only |
   | accounts | 11, columns `account_id`/`account_type`, no currency | **3** (101, 102, 201), columns `id`/`account_number`/`name`/`currency` |
   | account 102 balance | 1200000 cents = $12,000.00 | **125000 cents = $1,250.00** |
   | phone data | 8 formats + 1 NULL | **no phone column exists** |

   The M3 grader's forbidden keyword for account 102 is `1250.00`, which matches the baked database, not the seed file. The baked database is the truth. Anything reasoned from `db/seed.sql` is about a database the app never opens — including the Stage 1 slide's own `FULL_NAME` / `PHONE_RAW` table. "Go look. Don't assume" catches the slide's own data.

2. **Ticket B has no stored data to normalise.** There is no phone column in the deployed schema. `normalize_phone` is a pure function over a string the caller supplies, so phone numbers reach the system only because a user typed one into chat. The Ticket B fix is therefore the `PhoneNormalizer` function and its nine cases, full stop. There is no batch normalisation over a customer table, because there is no such table. The "1 in 5 fraud alerts fail" narrative lives in the client's real pipeline, which is out of this repo.

3. **Policy describes a role the code does not have.** `block-customer-enumeration` denies `list_accounts` when `session.role != 'banker'`. There is no role concept in the code; enforcement is an account-id allowlist in `AccountTools.EffectiveAccountIds`. Same outcome, different mechanism. The policy file is what a compliance reviewer reads, so reconcile it.

4. **Wire threshold units.** `docs/policy-template.yaml` uses `amount_cents` / `wire_transfer_threshold_cents`. The shipped `governance/policy.yaml` and `AccountTools.SubmitWireTransfer` both use **dollars**. The M3 grader scrapes the first number off a threshold/transfer/wire line, so a cents value there would grade against a different threshold than the app enforces. Keep both in dollars.

5. **Transaction descriptions are free text and cross the masking line unfiltered.** Nothing constrains what a teller typed. Not probed by the graded suite, but real.

## Part 4 — What this produces downstream

- **M1 topology:** draw the dashed masking line between the tool layer and the gateway. Annotate the Ticket D exclusion on the diagram.
- **Stage 3 `policy.yaml`:** three rules exist. Add an origination-refusal rule. Reconcile the role rule. Set the threshold in dollars.
- **M4 compliance report:** Part 2 table is the PII section. Part 3 is the limitations section.
