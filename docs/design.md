# Design specification

This is the normative specification of the contracts and the back office. The code implements it; when the two
disagree, one of them has a bug. Plain-language flows are in [business-flows.md](business-flows.md).

All banks, tickers, BICs and routing numbers are fictional: Bank A, B and C issue A-dT, B-dT and C-dT; member ids
are SWIFT test-style codes (`BNKAUS30`, `BNKBUS30`, `BNKCUS30`) as `bytes32`.

## 1. The model in one paragraph

Each member bank issues its own deposit token. When a customer of Bank A pays a customer of Bank B, Bank A mints
A-dT to Bank B's settlement wallet: Bank B now holds a claim on Bank A (a deposit of Bank B at Bank A) and credits its
customer in its own books. Holding another bank's token is **credit exposure**, so every transfer is checked, before
anything moves, against bilateral limits, the receiver's credit cap, the payer's net debit cap and a system maximum.
Positions are settled **net, in fiat**, over CHIPS (one message, weekdays) or RTP (legs of at most $10M, any day),
when a receiver reaches its cap, when a receiver asks, and always at end of day. The operator's **settlement listener**
does not move assets: it observes the rails' own finality events and attests them, and only then are the settled
tokens burned. A token transfer is final when it passes the checks; it is never unwound — a defaulting debtor's
obligation is covered by a waterfall of pre-funded resources.

## 2. Units, identities, time

| Item | Rule |
|---|---|
| Amounts | `uint256`, 6 decimals (1 USD = 1_000_000). All tokens use 6 decimals. |
| Member id | `bytes32`, BIC-style ASCII left-aligned (`bytes32("BNKAUS30")`) |
| Chain domains | `uint32`; home = 1; permissioned spoke = 2; public spoke = 3 in tests |
| Time | `block.timestamp`; the operator sets the business window (§5.4) |
| Roles | OpenZeppelin `AccessControlDefaultAdminRules` on every contract; the default admin is a `TimelockController` in deployment |

Role names used throughout: `DEFAULT_ADMIN_ROLE` (governance/timelock), `GUARDIAN_ROLE` (restrict-only, fast),
`OPERATOR_ROLE` (the operator's automated back office), `LEDGER_ROLE` / `BATCHES_ROLE` / `ATTESTOR_ROLE` /
`MESSENGER_ROLE` (contract-to-contract wiring, granted to contract addresses only).

## 3. Home chain contracts

### 3.1 `MemberRegistry`

```
enum Tier   { NONE, CREDIT, PREFUND_ONLY }
enum Status { NONE, ACTIVE, SUSPENDED, DEFAULTED, EXITED }
struct Member { address wallet; address issuerOps; address token; Tier tier; Status status; }
function admit(bytes32 id, address wallet, address issuerOps, address token, Tier tier)   // DEFAULT_ADMIN
function suspend(bytes32 id, bytes32 reason)                                               // GUARDIAN (fast)
function reinstate(bytes32 id)                                                             // DEFAULT_ADMIN
function markDefaulted(bytes32 id)                                                         // DEFAULT_MANAGER_ROLE
function member(bytes32 id) view returns (Member)
function memberOfWallet(address) view returns (bytes32)   // 0 if none
function memberIds() view returns (bytes32[])
function activeCount() view returns (uint256)
```
`wallet` holds other banks' tokens (the bank's settlement wallet); `issuerOps` is the bank's key that instructs
payments as payer. A member is *in good standing* iff `status == ACTIVE`.

### 3.2 `ObligationToken` (one per issuing bank)

ERC-20 (`name` "Bank A deposit token", `symbol` "A-dT", 6 decimals) with:
- `issuer()` → member id; `mint(to, amount)` only `LEDGER_ROLE` (the ledger, and on spokes the spoke guard);
  `burn(from, amount)` only `BATCHES_ROLE` (settlement) or `MESSENGER_ROLE` (cross-chain);
- **no user transfers**: `transfer`, `transferFrom` and `approve` revert `TransfersDisabled()` except for holders with
  `MOVER_ROLE` (the messenger, for lock-then-burn escrow). A bank's claim on another bank is not onward-transferable;
  this keeps exposure equal to holdings (§3.5).
- ERC-7943-style controls: `setFrozen(holder, bool)` by `GUARDIAN_ROLE`; `pause()` by the issuer's
  `ISSUER_ADMIN_ROLE` and `GUARDIAN_ROLE`; `unpause()` by `ISSUER_ADMIN_ROLE`. Paused or frozen blocks mint and
  mover transfers, never `burn` by settlement (a settled obligation must always extinguish).

### 3.3 `CollateralRegister`

Attested, off-chain resources per member (held at the central bank joint account or as haircut Treasuries; the chain
only records attested values):
```
collateral[id]     // defaulter-pays collateral
poolShare[id]      // contribution to the pre-funded loss pool (cover-2)
rtpPrefund[id]     // the member's attested RTP prefund available for off-hours payments
function attest(Kind kind, bytes32 id, uint256 value, uint64 asOf)   // only ATTESTOR_ROLE (the k-of-n attestor contract)
function poolTotal() view returns (uint256)
function collateralCommitted(id) view returns (uint256) // mandatory backing + public-chain envelopes (§4.4)
```
Lowering an attested value below what is committed does not fail; it reduces the derived mandatory limit (§3.4) and
public envelopes going forward, and the operator must recall envelopes.

### 3.4 `CreditLimits`

Limits are *grants*: `grantor` extends credit to `debtor` = the grantor accepts holding the debtor's token.
```
mandatoryPerPair                  // governance; default 5_000_000e6 ($5M)
systemMax                         // governance; default 1_000_000_000e6 ($1B) — cap on any debit cap
elective[grantor][debtor]         // set by the grantor, same day, 0..electiveMax (default $100M)
regCap[grantor][debtor]           // optional cap the grantor sets for regulatory reasons (Reg F, SCCL); reason code logged
receiverCap[id]                   // default 100_000_000e6 ($100M); member may lower, governance may set
mandatoryRemoved                  // governance (majority) switch: mandatory = 0 for all
restricted[debtor]                // set by GUARDIAN/OPERATOR on PCA or supervisory triggers: mandatory to debtor = 0

mandatory(debtor) = mandatoryRemoved || restricted[debtor] || !goodStanding(debtor) || tier != CREDIT ? 0
                  : min(mandatoryPerPair, collateralFreeForMandatory(debtor) / (activeCreditMembers - 1))
bilateralLimit(grantor, debtor) = (debtor not in good standing || grantor == debtor) ? 0
                  : min(regCap[g][d] or ∞ when unset, mandatory(debtor) + elective[g][d])
debitCap(debtor) = min(systemMax, Σ_{g≠d} bilateralLimit(g, d))
```
The EURO1 formula: the mandatory limits a member *receives* total at most its collateral (§3.3), so the forced credit
is defaulter-pays.

**Prefund-only tier** (smaller banks that do not take part in mutual credit): a `PREFUND_ONLY` member neither grants
nor receives mandatory limits. As a payer its exposure is covered by its own collateral, so check (3) of §3.5 does not
apply to it and `debitCap(d) = min(systemMax, collateral[d] − collateralCommitted(d))`. As a receiver it holds other
banks' tokens only within the elective limits it chooses to grant. `setElective`, `setRegCap(debtor, cap, reason)` and lowering `receiverCap` take effect immediately
and never affect exposure already taken — they only gate new transfers.

### 3.5 `ExposureLedger`

Positions, the pre-transfer check, the queue, and the hub side of cross-chain envelopes.

**State per ordered pair (issuer i, holder h):**
`open[i][h]` — tokens of i held by h minted in the current epoch; `pending[i][h]` — tokens in the in-flight batch
(locked); both counted as exposure until the batch completes. Spoke envelopes (§4) reserve headroom as
`envelope[d][i][h]` (amount of i's tokens h may receive on domain d).

**Derived positions (include open + pending + envelopes granted):**
```
gross(i, h)    = open[i][h] + pending[i][h] + Σ_d envelope[d][i][h]
bilateralNet(h ← i) = max(0, gross(i, h) − gross(h, i))           // exposure of h to i, after the netting contract
netPosition(m) = Σ_x gross(x, m) − Σ_x gross(m, x)                // > 0: net creditor
```
Envelopes count fully (conservative: a granted envelope is treated as used).

**`pay(bytes32 to, uint256 amount, bytes32 ref) returns (uint256 seq)`** — caller must be the payer's `issuerOps`.
Checks, in order, each a custom error:
1. payer and payee in good standing and distinct;
2. window: in `OFF_HOURS` the payer's `offHoursUsed + amount ≤ rtpPrefund[payer]` (no unsecured credit outside
   business windows, §5.4);
3. `bilateralNet(to ← payer)` after ≤ `bilateralLimit(to, payer)`;
4. `netPosition(to)` after ≤ `receiverCap[to]`;
5. `−netPosition(payer)` after ≤ `debitCap(payer)`;
If (3)–(5) fail the payment is **queued** (`Queued(seq, reason)`), not rejected; (1)–(2) revert. On success:
`open[payer][to] += amount`, `token(payer).mint(wallet(to), amount)`, append to the epoch commitment
`epochHash = keccak256(abi.encode(epochHash, seq, payer, to, amount, ref))`, emit `Paid(seq, payer, to, amount, ref)`.
If after the payment `netPosition(to) ≥ triggerLevel(to)` (default = `receiverCap`, governance-settable as a
fraction), emit `CapReached(to)` — the operator's trigger.

**Queue:** FIFO array of `{seq, payer, to, amount, ref, enqueuedAt}`; `drain(uint256 max)` (anyone) retries from the
head, stops at the first still-failing entry for liveness of order per payer but skips entries whose payer is not in
good standing (they are cancelled); `cancel(seq)` by the payer; at every cut, queue entries older than the cut's
`businessDay` are cancelled (`QueueExpired`).

**Hooks for settlement (only `BATCHES_ROLE`):**
- `snapshotForCut() returns (bytes32 epochHash, uint64 epoch)` — moves every `open` into `pending`, records the
  nonzero pairs for the batch, resets `open`, starts a new epoch. Only when no batch is pending.
- `pendingPairs(uint64 epoch)` view → arrays `(issuer[], holder[], amount[])`.
- `clearPending(uint64 epoch, uint256 start, uint256 count)` — after completion, zero `pending` for a page of pairs
  (the batch burns the tokens in the same call).
- `addRemoteToBatch(epoch, issuer, holder, amount)` — spoke amounts locked on other chains (§4.5).

**Hooks for cross-chain (only `MESSENGER_ROLE`):** `reserveEnvelope(domain, issuer, holder, amount)` (checks
(3)–(6) as if paying `amount`, then adds to `envelope`), `releaseEnvelope(domain, issuer, holder, amount)`,
`envelopeToPending(domain, issuer, holder, amount, epoch)` (on a spoke's `BATCH_LOCKED`: the locked part of the
envelope moves into the batch's pending).

### 3.6 `SettlementAttestor`

k-of-n EIP-712 attestations by the listener's signers (default k = 3, n = 5). Domain: name
`"CreditSettlementAttestor"`, version `"1"`, chainId, verifyingContract.
```
Payment(uint64 batch, uint32 leg, uint8 rail, bytes32 railTxId, address payerAcct, bytes32 payer, bytes32 payee,
        uint256 amount, uint64 finalAt)
Funding(uint8 kind, bytes32 member, uint256 value, uint64 asOf, uint64 nonce)
```
`rail`: 1 = CHIPS, 2 = RTP. `railTxId` = the rail's own identifier of the final settlement (CHIPS release sequence /
RTP transaction id), **usable once, forever** (`usedRailTx`). `payer` may be a member id or `COLLATERAL` /
`POOL` (`bytes32("COLLATERAL")`, `bytes32("POOL")`) for waterfall payments. Signatures must be strictly ascending by
signer address and each from a current signer. Signer set and k change only by `DEFAULT_ADMIN_ROLE` (timelock);
`GUARDIAN_ROLE` may only disable a signer (and k must stay reachable: k ≤ enabled signers).

### 3.7 `SettlementBatches`

**Batch lifecycle:** `NONE → CUT → PLANNED → (PARTIAL) → COMPLETE`, or `PLANNED/PARTIAL → DEFAULTING → COMPLETE`.

```
struct Leg { bytes32 payer; bytes32 payee; uint256 amount; uint256 paid; }
function cut(uint8 trigger)            // OPERATOR; trigger: 1 CAP, 2 RECEIVER_CALL, 3 END_OF_DAY
function requestSettlement()           // a member's issuerOps: receiver call → OPERATOR cuts (event only)
function submitPlan(uint64 batch, Leg[] legs, uint64 deadline)   // OPERATOR proposes, contract verifies
function recordPayment(Payment p)      // only ATTESTOR_ROLE (called by SettlementAttestor after k-of-n)
function finalize(uint64 batch, uint256 maxPairs)                // anyone; pages burns once COMPLETE
function reference(uint64 batch) view returns (string)           // "RF" + check digits + "CS" + batch, ISO 11649
```
- `cut` calls `ledger.snapshotForCut()`; stores `{epoch, epochHash, trigger, cutAt, businessDay}`; emits
  `BatchCut(batch, epoch, epochHash)`. Requires no other batch outstanding (one in flight).
- **Plan verification:** for every member m, Σ legs where payee = m − Σ legs where payer = m must equal the batch's
  multilateral net position of m computed from the batch's pending pairs (home + remote locked amounts). Legs have
  payer ≠ payee, amount > 0, both members. Otherwise `PlanMismatch(member)`.
- **Payments:** `recordPayment` matches `(batch, leg)`; requires `payer` = leg payer **or** the waterfall payer
  allowed by `DefaultManager` for that leg; `payee` = leg payee; adds to `paid`. A leg is paid when `paid ≥ amount`;
  `paid > amount` records `overpaid[batch][leg]` (refund by the operator off-chain, emitted as `Overpaid`). Partial
  payments (RTP legs of ≤ $10M) leave the batch `PARTIAL`. All legs paid → `COMPLETE`.
- **Finality:** on `COMPLETE`, `finalize` pages through pending pairs: `ledger.clearPending` + `token(issuer).burn(holder,
  amount)`; remote pairs are burned by `BURN_BATCH` messages (§4.5). Exposure is released only here.
- **Deadline:** after `deadline` with legs unpaid, anyone may call `DefaultManager.declare(batch)`.
- The batch never unwinds: no function restores tokens or positions; the only exit from `PLANNED` is completion.

### 3.8 `DefaultManager`

`declare(batch)` after the deadline: every member payer of an unpaid leg is `markDefaulted` in the registry
(suspended from paying and receiving; all its outgoing elective/mandatory limits irrelevant). For each unpaid
leg remainder `r` of defaulter D, the waterfall allocates cover in order and emits `CoverInstruction(batch, leg,
source, amount)`:
1. `COLLATERAL`: up to D's attested `collateral` not yet used;
2. `POOL`: up to the pool remaining;
3. `SURVIVORS`: the rest pro rata to each survivor's **elective** limit granted to D (EURO1 rule), as binding
   obligations recorded per survivor (`survivorCall[batch][member]`), paid as legs by those members.
Cover payments are attested `Payment`s with `payer = COLLATERAL | POOL | member`. `poolUsed` must be replenished
(attested `Funding` of kind `POOL`) before the next `cut` — `cut` reverts `PoolNotReplenished` while
`poolTotal() < poolRequired` (governance parameter = the two largest debit caps, cover-2, recomputed by the operator
and attested).

## 4. Cross-chain (spokes)

### 4.1 Shape and authority

Hub-and-spoke. Spokes talk only to home. Every message is attested by the operator's m-of-n attesters (strict
majority) after source-chain finality; a **MINT** additionally needs the issuing bank's own key (`issuerAttester`).
Third-party transports may carry an attested message; none holds mint power.

### 4.2 Contracts

- `CrossChainMessenger` (hub and spoke; one contract, `LOCAL_DOMAIN`, `HOME_DOMAIN`). Envelope struct encoded with
  `abi.encode(Envelope)`:
  `{uint8 version=4; uint8 kind; uint32 source; uint32 dest; uint64 nonce; bytes32 member; bytes32 counterparty;
    address recipient; uint256 amount; uint64 epoch; uint64 deadline; bytes32 ref}`.
  Kinds: `MINT=0` (token move, lock-then-burn), `MINT_ACK=1`, `MINT_CANCEL=2`, `ENVELOPE_GRANT=3`,
  `ENVELOPE_RELEASE=4`, `CUT=5`, `BATCH_LOCKED=6`, `BURN_BATCH=7`, `SUSPEND=8`.
  `receiveMessage(bytes envelope, bytes[] attesterSigs, bytes issuerSig)`; nonce per (source, nonce) used once.
- `RemoteObligationToken` on spokes: same interface as `ObligationToken` (no user transfers; mint by the spoke guard
  for local payments and by the messenger for MINT; burn by the messenger), plus `lock/unlock` by the messenger.
- `SpokeExposureGuard` on spokes: local envelopes `env[issuer][holder]` and usage `used[issuer][holder]`; local
  `pay(to, amount, ref)` by the payer's issuerOps on that chain mints the payer's token to the payee's wallet iff
  `used + amount ≤ env` (else queued locally); keeps `open[issuer][holder]` per epoch for the cut.
  `kind[domain]`: `PERMISSIONED` (credit envelopes) or `PUBLIC` (collateral envelopes only, §4.4).

### 4.3 Message flows

- **Envelope grant:** hub `grantEnvelope(domain, issuer, holder, amount)` (OPERATOR) → `ledger.reserveEnvelope` (checks
  run, headroom reserved first) → `ENVELOPE_GRANT` → spoke raises `env`. **Release:** spoke `releaseEnvelope` (OPERATOR
  on the spoke) lowers `env` by unused amount first → `ENVELOPE_RELEASE` → hub `ledger.releaseEnvelope` (only after
  the spoke's finality). Allocated ≥ used at every moment.
- **Token move (lock-then-burn):** source `sendMint(issuer, holder, amount, dest, recipient, deadline)` by the holder's
  wallet: the token is **locked** in the messenger (not burned) and the move is recorded `PENDING`. Destination
  `receiveMessage(MINT)` with issuer key: mints (subject to dest supply cap and inbound rate limit, §4.6) and marks
  the nonce `MINTED` → `MINT_ACK` back → source **burns** the locked amount. After `deadline` the destination may
  mark an un-minted nonce `CANCELLED` (it can never mint it afterwards) → `MINT_CANCEL` → source **unlocks**. A token
  is never burned before its mint is proven, and never minted twice. Exposure moves with the envelope: the source
  releases its envelope usage and the destination's usage rises inside its envelope; if the destination envelope is
  insufficient the mint is refused (`MINT_CANCEL` immediately).
- **Cut:** hub `SettlementBatches.cut` → messenger `broadcastCut(epoch)` → `CUT` to every spoke → spoke snapshots
  `open` per pair into its locked batch, resets → `BATCH_LOCKED(epoch, issuer, holder, amount)` per nonzero pair →
  hub `ledger.envelopeToPending` + `addRemoteToBatch`. The operator submits the plan only after every connected spoke
  has reported for that epoch (`spokesReported(epoch)`).
- **Burn:** batch `COMPLETE` → hub sends `BURN_BATCH(epoch, issuer, holder, amount)` → spoke burns the locked amount
  and frees its envelope usage (`used −= amount`). Until it lands those tokens are *settled-pending-burn*: locked,
  not usable, only burnable.
- **Suspend:** registry suspension or default → hub `SUSPEND(member)` → every spoke freezes that issuer's token and
  sets its envelopes to zero. Restrict-only: a `SUSPEND` can never raise anything.

### 4.4 Public spokes

On a `PUBLIC` spoke a hub grant draws from the issuer's **free collateral** (`collateral − mandatory backing −
other public envelopes`), not from credit limits; the receiving bank's exposure there is covered one-for-one. Default
credit on a public spoke is 0.

### 4.5 Invariants (all fuzzed)

1. Per issuer: Σ supply over all chains (home token + each spoke's remote token incl. locked) = Σ open + Σ pending +
   Σ spoke `open` + Σ spoke locked.
2. Per pair and spoke: `used ≤ env` on the spoke and `env(spoke) ≤ envelope[d][i][h]` at the hub.
3. Every limit of §3.5 holds with envelopes counted as fully used.
4. No mint without the issuer key and the attester majority; no nonce minted twice; a cancelled nonce never mints.
5. No `SUSPEND` raises a limit or unfreezes anything.
6. A public-spoke envelope ≤ attested free collateral at grant time.

### 4.6 Bounds on a failed chain or transport

- `supplyCap[issuer]` on each spoke (static, timelocked to raise);
- **inbound mint rate limit** per (source domain, issuer) on the receiving chain: a token bucket of `capacity` refilling
  at `capacity / window` (default window 1 h) — limits mints, not burns;
- the hub's **global accountant**: per (issuer, domain) the hub tracks `sent`/`returned`; a spoke can never mint at
  home more than home recorded as sent to it (and spoke-to-spoke always goes through home);
- attesters and issuers read the source chain from nodes they run themselves (operational rule; the code takes an
  explicit RPC per signer).

## 5. Back office (Go)

### 5.1 Rails simulator (`internal/rails`)

- **CHIPS:** weekdays only; session opens 21:00 ET the previous calendar day, payments cut off 17:00 ET; no size limit;
  each released payment is final at release and gets a sequence id; closing positions funded within 30 min.
- **RTP:** 24x7; per-payment limit $10,000,000; each participant has a prefunded position in a joint account, funded
  only via Fedwire (weekdays 21:00 prev day–19:00 ET); a payment is final at posting; transaction id; camt.056 is a
  *request* that never reverses a posted payment.
- Both journals are append-only and expose a finality feed (the listener's only input).

### 5.2 ISO 20022 (`internal/iso20022`)

pacs.008 for settlement legs (and pacs.009 for CHIPS FI-to-FI), carrying the batch reference: `RmtInf/Strd/CdtrRefInf/
Ref` = ISO 11649 `RF` reference of the batch, `EndToEndId` = `CS<batch>-L<leg>-<n>` (≤ 35 chars). camt.054 output is
for reconciliation only.

### 5.3 Listener (`internal/listener`)

n signer processes, each with its own key and its own rail-journal reader. Each signs an EIP-712 `Payment` only for a
journal entry that is final, whose reference parses to an open batch and leg, whose payer and payee accounts match
the leg (or the waterfall instruction), and which it has not signed before. The submitter collects k signatures and
calls `SettlementAttestor.attestPayment`. Unmatched entries go to a manual-review queue; nothing is signed for them.

### 5.4 Operator (`internal/operator`)

- business window: `BUSINESS` from the CHIPS open (21:00 ET the previous day) to the end-of-day cut (16:30 ET) on
  business days, else `OFF_HOURS` (set on chain by `OPERATOR_ROLE` at each boundary; only `OFF_HOURS` restricts).
  Payments after the end-of-day cut are off-hours, so nothing taken on credit carries overnight. `offHoursUsed`
  resets when the window returns to `BUSINESS`. Off-hours, every cut settles over RTP from the debtor's prefund;
  the rulebook earmarks the attested prefund for that purpose;
- triggers: `CapReached` → cut (CAP); receiver call → cut; 16:30 ET → final cut of the day (END_OF_DAY), so every
  position settles inside the business day;
- plan builder: multilateral net per member → legs from net debtors to net creditors, largest first, then
  `submitPlan`; rail choice: CHIPS during the CHIPS session, else RTP split into ≤ $10M legs within the payer's prefund;
- pay-in schedule: per leg `{batch, leg, payer, payee, amount, rail, RF reference, EndToEndId pattern, deadline}`;
- envelope rebalancer for spokes; reconciliation (rail journal ↔ listener log ↔ chain) with halt on a break.

### 5.5 Economics (`internal/econ`, `cmd/econ`)

Synthetic interbank flows (N banks, heavy-tailed sizes, intraday seasonality) through three settlement designs:
gross RTGS (liquidity = Σ gross outflows), prefunded continuous netting (CHIPS-like: liquidity = prefund needed to
release every payment), and this model (credit within limits, cap and end-of-day settlement). Outputs per design:
liquidity used, settlement efficiency (value settled / liquidity), number of fiat settlements, max exposure, and for
this model the collateral and cover-2 pool required. Results in `docs/economics.md`.
