# Rulebook term sheet

**This is a term sheet, not legal drafting.** It lists, in plain terms, the rules a network rulebook would contain
and, where the contracts enforce a rule, the contract, function and default parameter that enforce it. It is
written to support a lawyer drafting the real rulebook; it is not that rulebook, and nothing here is legal advice.

All names are fictional (Bank A, B and C; A-dT, B-dT, C-dT). Amounts are US dollars; on chain they have 6 decimals.

Column "Enforced by" says where the rule lives: **chain** (a contract refuses anything else), **operator** (the
operator's back office in `internal/`), or **rulebook** (a contractual duty the code does not enforce).

## 1. Parties and roles

| Term | Content | Enforced by |
|---|---|---|
| Members | Banks admitted by governance, each in one tier: CREDIT or PREFUND_ONLY | chain: `MemberRegistry.admit` |
| Member keys | Per member: a settlement wallet (holds other banks' tokens), an `issuerOps` key (pays, sets limits), and on each cross-chain messenger an issuer key (co-signs mints of its own token). No address may serve two members or two purposes | chain: `MemberRegistry`, `CrossChainMessenger.setIssuerKey` |
| The operator | Runs the business window on the ledger and on every spoke, cuts batches, proposes settlement plans, issues pay-in schedules, manages spoke envelopes. Holds no money and is not a counterparty to any obligation | chain: `OPERATOR_ROLE`; rulebook |
| The settlement listener | n independent signers that attest final rail payments and funding values | chain: `SettlementAttestor` |
| Cross-chain attesters | Signers that attest cross-chain messages after source-chain finality | chain: `CrossChainMessenger` |
| Guardian | A fast, restrict-only role: may suspend, restrict, freeze, pause, disable a signer or attester, lower caps and rate limits, disconnect a spoke; may never raise anything | chain: `GUARDIAN_ROLE` on each contract |
| Governance | The members' governance body acting through a timelock; the only authority that admits, reinstates, raises limits or changes signer sets | chain: `DEFAULT_ADMIN_ROLE` held by a `TimelockController` |

## 2. The instrument

| Term | Content | Enforced by |
|---|---|---|
| Nature | Each member's token is a **deposit liability of the issuing member** ("due to depository institutions"), held only by other members | rulebook |
| Units | One token = USD 1; 6 decimals | chain: `decimals() = 6` |
| Issue | Minted only by the ledger when a payment passes the limit checks (on a spoke: by the spoke guard within an envelope, or on a proven cross-chain move) | chain: `LEDGER_ROLE` |
| No onward transfer | Holders cannot transfer, approve or trade tokens; only the cross-chain messenger may move them, for lock-then-burn escrow | chain: `TransfersDisabled()` |
| Extinction | Tokens are burned only by settlement (after the fiat legs are attested) or by the cross-chain messenger (a move proven minted elsewhere) | chain: `BATCHES_ROLE`, `MESSENGER_ROLE` |
| Controls | The guardian may freeze a holder; the issuer or guardian may pause; only the issuer may unpause. Pause and freeze block mints and moves, **never settlement burns** | chain: `ObligationToken` |

## 3. Legal framework

| Term | Content | Enforced by |
|---|---|---|
| Governing law | **New York** law, for the rulebook, the netting contract and every payment order under it | rulebook |
| Netting contract | The rulebook is a netting contract among members; the operator is intended to qualify as a "clearing organization" so that multilateral netting is enforceable under **FDICIA §4404** | rulebook; legal opinion needed |
| Finality of a token transfer | A token transfer is **final and irrevocable when it passes the limit checks**. The rulebook adopts no provisional-payment rule under UCC 4A-405(d) | chain: no function reverses a transfer; rulebook |
| UCC 4A roles | The paying bank's token transfer is its payment order to the receiving bank; the receiving bank, as beneficiary's bank, accepts it by crediting its customer; the issuing bank's obligation is discharged when settlement completes under the rules of the system (UCC 4A-403(b)), that is, when its batch is `COMPLETE` | rulebook |
| No unwind | No batch is ever unwound, in whole or in part. A member that fails to pay is covered by the waterfall (§9) | chain: no restoring function exists; `DefaultManager` |
| Settlement asset | Fiat over CHIPS or RTP, which settle in accounts at a Federal Reserve Bank | rulebook |
| Receivership | The rules must work with the FDIC's powers under 12 USC 1821(e), including the stay until 5:00 p.m. ET on the business day after a receiver's appointment | rulebook; legal opinion needed |

## 4. Credit limits

A limit is a **grant**: the grantor accepts holding the debtor's token.

| Parameter | Default | Who sets it | Rule | Enforced by |
|---|---|---|---|---|
| Mandatory limit per pair | **$5M** (`mandatoryPerPair`) | Governance | Each CREDIT member grants every other CREDIT member min($5M, debtor's free collateral / (CREDIT members − 1)). The mandatory limits a member receives therefore total at most its own collateral (**defaulter pays**) | chain: `CreditLimits.mandatory` |
| Mandatory removal | off | Governance (majority, through the timelock) | Sets every mandatory limit to 0 | chain: `setMandatoryRemoved` |
| Restriction | off | Guardian or operator; lifted only by governance | On a prompt-corrective-action category, a supervisory event or an equivalent trigger, the debtor's mandatory limit from everyone is 0 | chain: `restrict`, `unrestrict` |
| Elective limit | 0 | The grantor, same day | 0 to `electiveMax`, **$100M**, per debtor | chain: `setElective`; `ElectiveAboveMax` |
| Regulatory cap | none | The grantor, with a reason code | Caps the whole bilateral limit (mandatory included). Exists so a member can meet Regulation F and SCCL duties without a credit decision against the consortium minimum | chain: `setRegCap`, `clearRegCap` |
| Bilateral limit | | | min(regulatory cap, mandatory + elective); 0 if either party is not in good standing | chain: `bilateralLimit` |
| Receiver cap | **$100M** | The member may only lower its own; governance may set any value | Caps a member's multilateral net creditor position | chain: `lowerReceiverCap`, `setReceiverCap` |
| Debit cap | derived | | min(system maximum, Σ bilateral limits the member receives). PREFUND_ONLY: min(system maximum, free collateral) | chain: `debitCap` |
| System maximum | **$1bn** (`systemMax`) | Governance | Caps every debit cap | chain |
| Cap trigger level | **100%** of the receiver cap (`triggerBps = 10_000`) | Governance, 1–10_000 bps | Reaching it emits `CapReached` and the operator cuts | chain; operator |
| Effect of changes | | | Every change gates new payments only; exposure already taken is never affected and settles at the next cut | chain |

## 5. Checks on every payment

| # | Check | On failure | Enforced by |
|---|---|---|---|
| 1 | Payer and payee in good standing, distinct, amount > 0 | Rejected | chain: `ExposureLedger.pay` |
| 2 | Outside the business window: the payer's off-hours total ≤ its attested RTP prefund | Rejected | chain |
| 3 | Payee's bilateral net exposure to the payer ≤ the bilateral limit (not for a PREFUND_ONLY payer) | **Queued** | chain |
| 4 | Payee's net position ≤ its receiver cap | **Queued** | chain |
| 5 | Payer's net debit ≤ its debit cap | **Queued** | chain |

Exposure counts open positions, positions in the batch in flight, and every spoke envelope granted (as if fully
used). Queued payments run in FIFO order when headroom returns; the payer may cancel; anything still queued at the
next business day's first cut expires.

## 6. Time

| Term | Value | Enforced by |
|---|---|---|
| Time zone and calendar | US Eastern; Federal Reserve holidays | operator: `internal/calendar` |
| Business window | From **21:00 ET** the calendar day before a business day to the **end-of-day cut at 16:30 ET** | operator sets it on chain (`setWindow`); chain enforces its effect |
| Off-hours | Every other time, including weekends and holidays. No unsecured credit: on the home chain, payments only within attested RTP prefund | chain: check (2) |
| Spoke window | The same window on every spoke, set by the operator at the same boundaries as the home chain; a new spoke starts off-hours. Off-hours a **permissioned** spoke takes no payments and releases nothing from its queue (no prefund allowance there); a **public** spoke stays open, since its envelopes are collateral | chain: `SpokeExposureGuard.setWindow`, `OffHoursCredit`; operator sets it |
| End-of-day cut | **16:30 ET** each business day; every position taken in the window, on the home chain or on a spoke, is cut and settled the same day (also on a day with payments only on a spoke) | operator |
| CHIPS payment cut-off | **17:00 ET**; CHIPS runs on business days from 21:00 ET the day before | operator: rail choice |
| CHIPS minimum time left | The operator uses CHIPS only with at least **15 minutes** left before the cut-off | operator (`MinCHIPSLeft`) |
| Pay-in deadline | **1 hour** after the plan (`PayInWindow`), capped at 17:00 ET for CHIPS. The chain requires a deadline in the future | operator; chain: `DeadlineInPast` |
| Fedwire (RTP funding) | 21:00 ET the day before to 19:00 ET, business days | operator: `internal/calendar` |

## 7. Settlement

| Term | Content | Enforced by |
|---|---|---|
| Triggers | (1) a receiver reaches its trigger level; (2) a member in good standing calls for settlement; (3) the end-of-day cut | chain: events; operator: cuts |
| One batch at a time | A new cut needs the previous batch finalized | chain: `BatchOutstanding` |
| Plan | Multilateral net: for every member, Σ legs received − Σ legs paid = its net position over the batch | chain: `PlanMismatch` |
| Rails | CHIPS on business days during the session; otherwise RTP. An RTP payment is **at most $10M**, so a large leg is several payments | operator; chain: `RtpLimitExceeded` |
| Reference | Every fiat payment carries the batch's ISO 11649 reference ("RF" + check digits + "CS" + batch) and the EndToEndId `CS<batch>-L<leg>-<part>` | operator; listener |
| Evidence of payment | Only the rail's own final posting or release counts. Acknowledgements, camt.054 notifications and creditor statements are for reconciliation only | listener |
| Attestation | **k = 3 of n = 5** listener signatures, strictly ascending by signer; each rail transaction id usable once, forever; the time of finality may not be in the future | chain: `SettlementAttestor` |
| Partial payment | Recorded per leg; nothing is burned until every leg is paid | chain |
| Overpayment | Recorded (`overpaid`); refunded by the operator off chain | chain; operator |
| Finality and release | When every leg is paid the batch is `COMPLETE`; `finalize` burns the netted tokens and releases the exposure | chain |
| Returns | A return request (camt.056) never reverses anything. A return that settles is a new payment handled under governance | listener; rulebook |
| Reconciliation | Rail journals, listener log and chain reconciled after every batch; any break halts new cuts | operator: `internal/reconcile` |

## 8. Financial resources

| Resource | Size | Form | Enforced by |
|---|---|---|---|
| Collateral (defaulter pays) | Sets the mandatory limits the member receives: they total at most its free collateral, up to $5M × (CREDIT members − 1); posting less lowers them. Collateral also backs public-spoke envelopes one-for-one, and stays committed from a cut until the batch settles | Central bank money in a joint account at a Federal Reserve Bank, or Treasuries with haircuts. The chain records only attested values | chain records; rulebook defines the form |
| Loss pool (cover-2) | At least the two largest debit caps, computed by the operator and attested (`POOL_REQUIRED`) | As above; contributions attested per member (`POOL`) | chain: `cut` reverts `PoolNotReplenished` while the pool is short |
| RTP prefund | Each member's own choice; bounds its off-hours payments | The member's position in the RTP joint account, funded over Fedwire | chain: check (2) |
| Attestation of values | 3 of 5 listener signatures; each signer checks its own source; the `asOf` time strictly increases per value and member; each nonce once | | chain: `attestFunding`, `CollateralRegister.attest` |
| Replenishment | After any draw, before the next cut | | chain: the pool check at `cut` |

## 9. Default

| Term | Content | Enforced by |
|---|---|---|
| Event of default | A leg unpaid at the pay-in deadline | chain: `DefaultManager.declare`, callable by anyone after the deadline |
| Consequence | The payer becomes `DEFAULTED`: it can no longer pay or receive, all limits to and from it are 0. **`DEFAULTED` is terminal**; no function reinstates it | chain |
| Waterfall | For each unpaid remainder: (1) the defaulter's collateral, except the part committed to public-spoke positions, which stays behind them; (2) the loss pool, drawn pro rata to contributions; (3) the survivors, pro rata to the elective limits each granted the defaulter, equal shares if none did | chain: `DefaultManager` |
| Survivors | Every admitted **CREDIT-tier** member that is `ACTIVE` or `SUSPENDED`, other than the defaulter. A PREFUND_ONLY member never shares a loss. The leg's own payee absorbs its share instead of paying itself | chain: `DefaultManager`, `absorbLoss` |
| No eligible survivor | The leg's payee bears the rest as a recorded loss (`ShortfallAbsorbed`) | chain: `DefaultManager`, `absorbLoss` |
| Survivor obligations | Binding; paid as fiat legs and attested like any other payment | chain records; rulebook binds |
| Suspension elsewhere | The defaulter is suspended on every spoke | operator: `sendSuspend` |
| Testing | Default procedures tested with members at least annually | rulebook |

## 10. Access

| Term | Content | Enforced by |
|---|---|---|
| Admission | By governance, on objective, risk-based and published criteria | chain: `admit`; rulebook: criteria |
| CREDIT tier | Grants and receives mandatory limits; may grant elective limits; posts collateral; contributes to the pool | chain |
| PREFUND_ONLY tier | Neither grants nor receives mandatory limits; pays only within its own free collateral; holds others' tokens only within elective limits it grants; never shares another member's default loss | chain |
| Suspension | Guardian, fast; reinstatement by governance | chain |
| Exit | Governance records an orderly exit once the member has no position left: no open, pending or spoke-envelope position as holder or issuer, and no queued payment. `EXITED` is terminal; the id and addresses cannot be admitted again. A defaulted member cannot exit. Winding down beforehand, and the return of collateral and pool contributions, are rulebook procedure | chain: `DefaultManager.exit` (`MemberHasPositions`), `MemberRegistry.markExited`; rulebook: wind-down |

## 11. Cross-chain

| Term | Value | Enforced by |
|---|---|---|
| Topology | Hub and spoke: spokes talk only to the home chain | chain: `SpokeToSpoke` |
| Attestation | A strict majority of the attesters (deployment default 3 of 5), after source-chain finality, each reading from a node it runs itself | chain: threshold; rulebook: node rule |
| Mint authority | Every mint needs the attesters **and** the issuing bank's own key; no key may hold both roles | chain |
| Transports | Any carrier may deliver a signed message; none can authorize one | chain |
| Envelopes | Spoke credit is reserved from the global limits at the hub first; public spokes take collateral envelopes only, and that collateral stays committed until the position is released or settles | chain |
| Spoke window | No credit on a permissioned spoke outside the business window (see §6) | chain; operator sets it |
| Supply cap | Per issuer per spoke; raised only by governance, lowered by the guardian | chain |
| Inbound mint rate limit | Per source chain and issuer, on the receiving chain; a token bucket refilling over a window (default 1 hour); unset means no mints | chain |
| Move timeout | A mint not made by its deadline can be cancelled at the destination with the attesters' signatures; the source then unlocks | chain |

## 12. Governance

| Term | Value | Enforced by |
|---|---|---|
| Admin of every contract | A `TimelockController`; the deployer keeps no role | chain: deploy scripts verify it |
| Admin transfer delay | 1 day (`ADMIN_DELAY` default) | chain |
| Timelock delay | Set at deployment (`TIMELOCK_DELAY`; 0 in the local scripts) | rulebook sets the production value |
| Restrict-only fast path | Guardian actions only lower, pause, freeze or disable | chain |
| Changes to the listener or attester sets | Governance only; the guardian may only disable, and the threshold must stay reachable | chain |
