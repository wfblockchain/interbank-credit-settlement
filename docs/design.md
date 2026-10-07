# Design specification

This is the normative specification of the contracts and the back office. It was written before the code and has
since been brought in line with it: where the implementation deviated, this text now describes the implementation.
When the two disagree, one of them has a bug. Plain-language flows are in [business-flows.md](business-flows.md); the
cross-chain rationale is in [cross-chain.md](cross-chain.md); known limits are in [§6](#6-known-limits).

All banks, tickers, BICs and routing numbers are fictional: Bank A, B and C issue A-dT, B-dT and C-dT; member ids
are BIC-style test codes (`BNKAUS30`, `BNKBUS30`, `BNKCUS30`) as `bytes32`.

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
| Member id | `bytes32`, BIC-style ASCII left-aligned (`bytes32("BNKAUS30")`). `bytes32("COLLATERAL")` and `bytes32("POOL")` are reserved for waterfall payers and cannot be admitted (`ReservedId`) |
| Chain domains | `uint32`; home = 1; permissioned spoke = 2; public spoke = 3 in tests |
| Time | `block.timestamp`; the operator sets the business window (§5.4) |
| Window enum | `IExposureLedger.Window { BUSINESS, OFF_HOURS }`: **`BUSINESS = 0`, `OFF_HOURS = 1` in Solidity**. A new ledger starts in `OFF_HOURS`. (Go's `calendar.Window` numbers from 1; `internal/deploy` has the on-chain values `WindowBusiness = 0`, `WindowOffHours = 1`.) |
| Roles | OpenZeppelin `AccessControlDefaultAdminRules` on every contract; the default admin is a `TimelockController` in deployment and the deployer keeps no role (`verifyRoles`) |

Role names used throughout: `DEFAULT_ADMIN_ROLE` (governance/timelock), `GUARDIAN_ROLE` (restrict-only, fast),
`OPERATOR_ROLE` (the operator's automated back office), `ISSUER_ADMIN_ROLE` (a bank's own token admin), and the
contract-to-contract roles `LEDGER_ROLE`, `BATCHES_ROLE`, `ATTESTOR_ROLE`, `MESSENGER_ROLE`, `MOVER_ROLE`,
`DEFAULT_MANAGER_ROLE` (granted to contract addresses only).

## 3. Home chain contracts

### 3.1 `MemberRegistry`

```
enum Tier   { NONE, CREDIT, PREFUND_ONLY }
enum Status { NONE, ACTIVE, SUSPENDED, DEFAULTED, EXITED }
struct Member { address wallet; address issuerOps; address token; Tier tier; Status status; }
function admit(bytes32 id, address wallet, address issuerOps, address token, Tier tier)   // DEFAULT_ADMIN
function suspend(bytes32 id, bytes32 reason)                                               // GUARDIAN (fast), ACTIVE only
function reinstate(bytes32 id)                                                             // DEFAULT_ADMIN, SUSPENDED only
function markDefaulted(bytes32 id)                                                         // DEFAULT_MANAGER_ROLE, ACTIVE or SUSPENDED
function member(bytes32 id) view returns (Member)
function memberOfWallet(address) / memberOfIssuerOps(address) / memberOfToken(address) view returns (bytes32)  // 0 if none
function memberIds() view returns (bytes32[])          // every admitted member, whatever its status
function activeCount() / activeCreditCount() view returns (uint256)
function goodStanding(bytes32 id) view returns (bool)  // status == ACTIVE
```
`wallet` holds other banks' tokens (the bank's settlement wallet); `issuerOps` is the bank's key that instructs
payments as payer. A member is *in good standing* iff `status == ACTIVE`. `admit` requires a nonzero id, nonzero
addresses, a valid tier, a token whose `issuer()` is the id (`TokenIssuerMismatch`), and addresses not already used by
any member in any capacity, with `wallet ≠ issuerOps` (`AddressInUse`).

**`DEFAULTED` is terminal**: `reinstate` accepts only `SUSPENDED`, and nothing leaves `DEFAULTED`. `EXITED` is declared
but no function sets it ([§6](#6-known-limits)).

### 3.2 `ObligationToken` (one per issuing bank)

ERC-20 (`name` "Bank A deposit token", `symbol` "A-dT", 6 decimals) with:
- `issuer()` → member id; `mint(to, amount)` only `LEDGER_ROLE` (the ledger);
  `burn(from, amount)` only `BATCHES_ROLE` (settlement) or `MESSENGER_ROLE` (the hub messenger, for a proven move);
- **no user transfers**: `transfer` and `transferFrom` revert `TransfersDisabled()` unless the caller holds
  `MOVER_ROLE` (the hub messenger, for lock-then-burn escrow); `approve` reverts unless the spender holds
  `MOVER_ROLE`. A bank's claim on another bank is not onward-transferable; this keeps exposure equal to holdings (§3.5).
- ERC-7943-style controls: `setFrozen(holder, bool)` by `GUARDIAN_ROLE`; `pause()` by the issuer's
  `ISSUER_ADMIN_ROLE` and `GUARDIAN_ROLE`; `unpause()` by `ISSUER_ADMIN_ROLE`. Paused or frozen blocks mint and
  mover transfers, never `burn` (a settled obligation must always extinguish).

### 3.3 `CollateralRegister`

Attested, off-chain resources per member (held at the central bank joint account or as haircut Treasuries; the chain
only records attested values):
```
enum Kind { COLLATERAL /*0*/, POOL /*1*/, RTP_PREFUND /*2*/, POOL_REQUIRED /*3*/ }   // = Funding.kind
collateral[id]     // defaulter-pays collateral
poolShare[id]      // contribution to the pre-funded loss pool (cover-2); poolTotal = Σ poolShare
rtpPrefund[id]     // the member's attested RTP prefund available for off-hours payments
poolRequired       // network-wide; attested with id 0
publicCommitted[id]// collateral committed to public-spoke envelopes (§4.4)
function attest(Kind kind, bytes32 id, uint256 value, uint64 asOf)   // only ATTESTOR_ROLE (the k-of-n attestor contract)
function drawCollateral(bytes32 id, uint256 amount)                 // DEFAULT_MANAGER_ROLE: waterfall step 1
function drawPool(uint256 amount)                                   // DEFAULT_MANAGER_ROLE: pro rata to poolShare
function commitPublic(bytes32 id, uint256 amount)                   // LEDGER_ROLE: ≤ freeCollateral
function releasePublic(bytes32 id, uint256 amount)                  // LEDGER_ROLE
function collateralCommitted(id) view = publicCommitted[id] + limits.mandatoryBacking(id)
function freeCollateral(id) view = max(0, collateral[id] − collateralCommitted(id))
```
`attest` requires `id == 0` exactly for `POOL_REQUIRED` (`InvalidAttestationId`) and an `asOf` **strictly greater**
than the last one for that `(kind, id)` (`StaleAttestation`). Lowering an attested value below what is committed
does not fail; it reduces the derived mandatory limit (§3.4) and public envelopes going forward, and the operator must
recall envelopes.

### 3.4 `CreditLimits`

Limits are *grants*: `grantor` extends credit to `debtor` = the grantor accepts holding the debtor's token.
```
mandatoryPerPair                  // governance; default 5_000_000e6 ($5M)
systemMax                         // governance; default 1_000_000_000e6 ($1B) — cap on any debit cap
electiveMax                       // governance; default 100_000_000e6 ($100M)
elective[grantor][debtor]         // set by the grantor's issuerOps, same day, 0..electiveMax (ElectiveAboveMax)
regCap[grantor][debtor]           // optional cap the grantor sets (setRegCap / clearRegCap, reason code logged)
receiverCap[id]                   // default 100_000_000e6 ($100M); member may only lower (lowerReceiverCap), governance may set
triggerBps                        // governance; default 10_000 (triggerLevel = receiverCap × bps / 10_000)
mandatoryRemoved                  // governance (majority) switch: mandatory = 0 for all
restricted[debtor]                // restrict() by GUARDIAN or OPERATOR on PCA or supervisory triggers; unrestrict() by governance

collateralFreeForMandatory(d) = max(0, collateral[d] − publicCommitted[d])
mandatory(d) = mandatoryRemoved || restricted[d] || status(d) != ACTIVE || tier(d) != CREDIT || activeCreditCount < 2 ? 0
             : min(mandatoryPerPair, collateralFreeForMandatory(d) / (activeCreditCount − 1))
mandatoryBacking(d) = mandatory(d) × (activeCreditCount − 1)
bilateralLimit(g, d) = (g == d || status(g) != ACTIVE || status(d) != ACTIVE) ? 0
             : min(regCap[g][d] if set else ∞, (tier(g) == CREDIT ? mandatory(d) : 0) + min(elective[g][d], electiveMax))
debitCap(d) = status(d) != ACTIVE ? 0
             : tier(d) == PREFUND_ONLY ? min(systemMax, max(0, collateral[d] − collateralCommitted(d)))
             : min(systemMax, Σ_{g≠d} bilateralLimit(g, d))
```
The EURO1 formula: the mandatory limits a member *receives* total at most its collateral (§3.3), so the forced credit
is defaulter-pays. Note that a grantor not in good standing grants nothing.

**Prefund-only tier** (smaller banks that do not take part in mutual credit): a `PREFUND_ONLY` member neither grants
nor receives mandatory limits and does not count in `activeCreditCount`. As a payer its exposure is covered by its own
collateral, so check (3) of §3.5 does not apply to it and its debit cap is its free collateral. As a receiver it holds
other banks' tokens only within the elective limits it chooses to grant. `setElective`, `setRegCap`, `clearRegCap`
and lowering `receiverCap` take effect immediately and never affect exposure already taken — they only gate new
transfers.

### 3.5 `ExposureLedger`

Positions, the pre-transfer check, the queue, and the hub side of cross-chain envelopes and moves.

**State per ordered pair (issuer i, holder h):**
`open[i][h]` — tokens of i held by h in the current epoch; `pending[i][h]` — tokens in the in-flight batch (locked);
both counted as exposure until the batch completes. Spoke envelopes (§4) reserve headroom as
`envelope[d][i][h]` (amount of i's tokens h may hold on domain d), summed in `envelopeTotal[i][h]`.
`domainKind[d]` (`NONE`, `PERMISSIONED`, `PUBLIC`) is set once per domain by governance (`setDomainKind`).

**Derived positions (include open + pending + envelopes granted):**
```
gross(i, h)    = open[i][h] + pending[i][h] + envelopeTotal[i][h]
bilateralNet(h, i) = max(0, gross(i, h) − gross(h, i))           // exposure of h to i, after the netting contract
netPosition(m) = grossIn[m] − grossOut[m] = Σ_x gross(x, m) − Σ_x gross(m, x)   // > 0: net creditor
```
Envelopes count fully (conservative: a granted envelope is treated as used).

**`pay(bytes32 to, uint256 amount, bytes32 ref) returns (uint256 seq)`** — caller must be the payer's `issuerOps`.
Checks, in order, each a custom error or reason code:
1. payer and payee in good standing and distinct, amount > 0 (`NotIssuerOps`, `ZeroAmount`, `SelfPayment`,
   `PayerNotInGoodStanding`, `PayeeNotInGoodStanding`);
2. window: in `OFF_HOURS` the payer's `offHoursUsed + amount ≤ rtpPrefund[payer]` (`OffHoursPrefundExceeded`; no
   unsecured credit outside business windows, §5.4);
3. `bilateralNet(to, payer)` after ≤ `bilateralLimit(to, payer)` (skipped for a `PREFUND_ONLY` payer);
4. `netPosition(to)` after ≤ `receiverCap[to]`;
5. `−netPosition(payer)` after ≤ `debitCap(payer)`.

(1)–(2) revert. If (3)–(5) fail the payment is **queued** (`Queued(seq, reason)`, reason 3, 4 or 5), not rejected.
On success: `open[payer][to] += amount`, `token(payer).mint(wallet(to), amount)`, append to the epoch commitment
`epochHash = keccak256(abi.encode(epochHash, seq, payer, to, amount, ref))`, emit `Paid(seq, payer, to, amount, ref)`;
in `OFF_HOURS`, `offHoursUsed` grows by `amount`. If after the payment `netPosition(to) ≥ triggerLevel(to)`, emit
`CapReached(to)` — the operator's trigger. The view `check(payer, to, amount)` returns the first failing check
(1–5) or 0. Reason 6 is the public-spoke free-collateral check of `reserveEnvelope`; reason 7 (`R_ENVELOPE`) is
`moveInCheck`'s envelope check.

**Queue:** FIFO array of `{seq, payer, to, amount, ref, enqueuedAt, businessDay, state}`; `drain(uint256 max)`
(anyone) retries from the head and stops at the first entry that still fails checks (2)–(5) or whose token is paused
or recipient frozen; it cancels (`QueueCancelled`, reason 1) entries whose payer or payee is not in good standing.
`cancel(seq)` by the payer (reason 0). At every cut, queue entries from an earlier `businessDay` are expired
(`QueueExpired`). `setWindow(w)` and `setBusinessDay(day)` (never backwards) are `OPERATOR_ROLE`; returning from
`OFF_HOURS` to `BUSINESS` starts a new off-hours session, which resets `offHoursUsed`.

**Hooks for settlement (only `BATCHES_ROLE`):**
- `snapshotForCut() returns (bytes32 epochHash, uint64 epoch)` — moves every `open` into `pending`, records the
  nonzero pairs for the batch, resets `open`, starts a new epoch, expires stale queue entries. Only when no batch is
  pending (`BatchInFlight`).
- `sealBatch(epoch)` — fixes the batch's pair list when the plan is accepted; reverts `RemoteUnrecorded` while
  spoke-locked amounts have reached `pending` but not the pair list. `isSealed(epoch)` is the view.
- `pendingPairs(epoch)` view → arrays `(issuer[], holder[], amount[])`; `pendingPair(epoch, k)` adds the `remote`
  flag.
- `clearPending(epoch, start, count)` — after completion, in order (`PageOutOfOrder`), only once sealed
  (`EpochNotSealed`): zero `pending` for a page of pairs (the batch burns the home tokens in the same call). The last
  page ends the batch (`EpochSettled`).

**Hooks for cross-chain (only `MESSENGER_ROLE`):**
- `reserveEnvelope(domain, issuer, holder, amount)` — issuer and holder in good standing and distinct;
  `PERMISSIONED`: checks (3)–(5) as if paying `amount`, a failure **reverts** (`BilateralLimitExceeded`,
  `ReceiverCapExceeded`, `DebitCapExceeded`); `PUBLIC`: check (6), `commitPublic` from the issuer's free collateral.
  Then adds to `envelope`.
- `releaseEnvelope(domain, issuer, holder, amount)` — lowers it (and, on `PUBLIC`, `releasePublic`).
- `envelopeToPending(domain, issuer, holder, amount, epoch)` — on a spoke's `BATCH_LOCKED`, before the batch is
  sealed: the locked part of the envelope moves into the batch's `pending` and `remoteUnrecorded` grows.
- `addRemoteToBatch(epoch, issuer, holder, amount)` — **`MESSENGER_ROLE`, not `BATCHES_ROLE`**: appends the locked
  amount to the batch's pair list as a remote pair, up to what `envelopeToPending` moved (`RemoteExceedsLocked`).
- Moves (§4.3): `moveOut(domain, issuer, holder, amount)` — home → spoke, `amount ≤ open` (`MoveExceedsOpen`): open
  becomes envelope, gross unchanged (`PUBLIC`: also `commitPublic`); `moveCancelled(…)` — envelope back to open;
  `moveIn(…)` — spoke → home: envelope back to open and the home token minted to the holder's wallet, only if
  `moveInCheck(…) == 0` (`MoveRefused(reason)`); `moveInCheck(…)` view — 7 unless the domain's envelope covers the
  amount; for a `PUBLIC` domain also checks (3)–(5) for the position as it stands.

### 3.6 `SettlementAttestor`

k-of-n EIP-712 attestations by the listener's signers (default k = 3, n = 5). Domain: name
`"CreditSettlementAttestor"`, version `"1"`, chainId, verifyingContract.
```
Payment(uint64 batch, uint32 leg, uint8 rail, bytes32 railTxId, address payerAcct, bytes32 payer, bytes32 payee,
        uint256 amount, uint64 finalAt)
Funding(uint8 kind, bytes32 member, uint256 value, uint64 asOf, uint64 nonce)
function attestPayment(Payment p, bytes[] sigs)   // anyone may submit
function attestFunding(Funding f, bytes[] sigs)   // anyone may submit
```
`rail`: 1 = CHIPS, 2 = RTP. `railTxId` = keccak256 of the rail's own identifier of the final settlement (CHIPS release
sequence / RTP transaction id), **usable once, forever** (`usedRailTx`). `payer` may be a member id or `COLLATERAL` /
`POOL` for waterfall payments. On chain, `attestPayment` also refuses an unknown rail (`InvalidRail`), a zero rail id,
a zero amount, an **RTP payment above $10M** (`RtpLimitExceeded`, `RTP_MAX = 10_000_000e6`) and a **`finalAt` later
than the block time** (`FinalAtInFuture`), then calls `SettlementBatches.recordPayment`. `attestFunding` refuses a
`kind` outside the four of §3.3 and a reused `nonce`, then calls `CollateralRegister.attest`.

Signatures must be at least k, strictly ascending by signer address (`DuplicateSigner`, `SignersNotAscending`) and
each from an enabled signer (`UnknownSigner`). Signer set and k change only by `DEFAULT_ADMIN_ROLE` (timelock);
`GUARDIAN_ROLE` may only disable a signer, and k must stay reachable (`ThresholdUnreachable`).

### 3.7 `SettlementBatches`

**Batch lifecycle:** `NONE → CUT → PLANNED → (PARTIAL) → COMPLETE`, or `PLANNED/PARTIAL → DEFAULTING → COMPLETE`;
then `finalized` once every pair is burned.

```
struct Leg { bytes32 payer; bytes32 payee; uint256 amount; uint256 paid; }
function cut(uint8 trigger) returns (uint64 batch)               // OPERATOR; 1 CAP, 2 RECEIVER_CALL, 3 END_OF_DAY
function requestSettlement()                                     // a member's issuerOps, in good standing: event only
function submitPlan(uint64 batch, Leg[] legs, uint64 deadline)   // OPERATOR proposes, contract verifies
function recordPayment(Payment p)                                // only ATTESTOR_ROLE (the attestor after k-of-n)
function finalize(uint64 batch, uint256 maxPairs)                // anyone; pages burns once COMPLETE
function markDefaulting(uint64 batch)                            // DEFAULT_MANAGER_ROLE, after the deadline
function absorbLoss(uint64 batch, uint32 leg, bytes32 member, uint256 amount)   // DEFAULT_MANAGER_ROLE
function setCrossChain(address hub)                              // DEFAULT_ADMIN: wires the hub messenger
function rfReference(uint64 batch) view returns (string)         // "RF" + check digits + "CS" + batch, ISO 11649
```
- `cut` requires the previous batch finalized (`BatchOutstanding`: one in flight) and `poolTotal ≥ poolRequired`
  (`PoolNotReplenished`); calls `ledger.snapshotForCut()`; stores `{epoch, epochHash, trigger, cutAt, businessDay}`;
  emits `BatchCut(batch, epoch, epochHash)`; if a hub messenger is wired, calls `broadcastCut(epoch)` (§4.3).
- **Plan verification:** status `CUT`; `deadline > now` (`DeadlineInPast`); if a hub is wired,
  `spokesReported(epoch)` (`SpokesNotReported`); then `ledger.sealBatch(epoch)`. For every member m, Σ legs where
  payee = m − Σ legs where payer = m must equal the batch's multilateral net position of m computed from the batch's
  pending pairs (home and remote). Legs have payer ≠ payee, amount > 0, `paid == 0` (`InvalidLeg`), both admitted
  members (`NotAMember`). Otherwise `PlanMismatch(member)`. A plan with no legs completes at once.
- **Payments:** `recordPayment` requires status `PLANNED`, `PARTIAL` or `DEFAULTING`; matches `(batch, leg)`
  (`UnknownLeg`); requires `payee` = leg payee (`WrongPayee`) and `payer` ≠ payee and either the leg payer or a payer
  `DefaultManager.allowedPayer` allows for that leg (`WrongPayer`); adds to `paid` and to `paidBy`. A leg is paid when
  `paid ≥ amount`; `paid > amount` records `overpaid[batch][leg]` (refund by the operator off-chain, emitted as
  `Overpaid`). The first payment that does not complete the batch moves `PLANNED` to `PARTIAL`. All legs paid →
  `COMPLETE`.
- **Finality:** on `COMPLETE`, `finalize` pages through pending pairs: `ledger.clearPending` +
  `token(issuer).burn(holder, amount)` for home pairs; remote pairs emit `PairSettled(…, remote = true)` and are
  burned on their spoke by `BURN_BATCH` (§4.3). Exposure is released only here.
- **Deadline:** after `deadline` with legs unpaid, anyone may call `DefaultManager.declare(batch)`.
- The batch never unwinds: no function restores tokens or positions; the only exit from `PLANNED` is completion.

### 3.8 `DefaultManager`

`declare(batch)` (anyone): the batch must be `PLANNED` or `PARTIAL` (`NotDeclarable`) and past its deadline
(`DeadlineNotPassed`). It calls `markDefaulting`, then marks every member payer of an unpaid leg `DEFAULTED` in the
registry (it can no longer pay or receive; every limit to or from it is 0). For each unpaid leg remainder `r` of
defaulter D, the waterfall allocates cover in order and emits `CoverInstruction(batch, leg, source, amount)`:
1. `COLLATERAL`: up to D's attested `collateral` (`drawCollateral`);
2. `POOL`: up to the pool remaining (`drawPool`, pro rata to every contributor's share);
3. survivors: the rest pro rata to each survivor's **elective** limit granted to D (EURO1 rule). Survivors are every
   admitted member whose status is `ACTIVE` or `SUSPENDED`, other than D. **If every survivor's elective limit to D is
   0, the weights are equal.** The rounding remainder goes to the first survivor with the largest weight. No survivor
   reverts `NoSurvivors`. A survivor that is the leg's own payee does not pay itself: its share is booked by
   `SettlementBatches.absorbLoss` (the leg's remainder shrinks, `absorbed[batch][member]`); every other share is a
   binding obligation `survivorCall[batch][member]`, paid as a payment on that leg.

Cover payments are attested `Payment`s with `payer = COLLATERAL | POOL | member`; `allowedPayer(batch, leg, payer)`
is true for any source with a nonzero `coverAmount`. The pool must be replenished (attested `Funding` of kind `POOL`)
before the next `cut`, which reverts `PoolNotReplenished` while `poolTotal() < poolRequired`. `poolRequired` (the two
largest debit caps, cover-2) is computed by the operator and attested as kind `POOL_REQUIRED`; it is not computed on
chain.

## 4. Cross-chain (spokes)

### 4.1 Shape and authority

Hub-and-spoke. Spokes talk only to home (`SpokeToSpoke`). Every message is attested by the operator's attesters —
at least `threshold` of them, where the threshold must be a strict majority of, and at most, the enabled attesters
(`BadThreshold`; deployment default 3 of 5) — after source-chain finality; a **MINT** additionally needs the issuing
bank's own key (`issuerKey[member]`). No key may be both an attester and an issuer key (`KeyHasOtherRole`).
Third-party transports may carry an attested message; none holds mint power.

Attesters (and, for a MINT, the issuer) sign
`toEthSignedMessageHash(keccak256(abi.encode(keccak256("CreditCrossChainMessage.v4"), sourceMessenger,
destinationMessenger, keccak256(message))))` — the signature **binds both the source and the destination messenger
addresses** (`messageDigest(message)` on the destination). Signatures must be strictly ascending by signer
(`SignersNotSorted`).

### 4.2 Contracts

- `CrossChainMessenger` (abstract base shared by hub and spoke; `LOCAL_DOMAIN`, `HOME_DOMAIN`, `VERSION = 4`):
  message format, verification, `receiveMessage`, `cancelExpired`, `sendMint`, the move records, attester and issuer
  key management, `setRemote`, and the inbound rate limits. Envelope struct encoded with `abi.encode(Envelope)`:
  `{uint8 version=4; uint8 kind; uint32 source; uint32 dest; uint64 nonce; bytes32 member; bytes32 counterparty;
    address recipient; uint256 amount; uint64 epoch; uint64 deadline; bytes32 ref}`.
  Kinds: `MINT=0` (token move, lock-then-burn), `MINT_ACK=1`, `MINT_CANCEL=2`, `ENVELOPE_GRANT=3`,
  `ENVELOPE_RELEASE=4`, `CUT=5`, `BATCH_LOCKED=6`, `BURN_BATCH=7`, `SUSPEND=8`.
  `receiveMessage(bytes message, bytes[] attesterSigs, bytes issuerSig)`; each `(source, nonce)` is accepted once
  (`inbound`: `NONE`, `DONE`, `MINTED`, `CANCELLED`). Each kind is accepted only in its own direction
  (`KindNotAccepted`).
- `HubMessenger` (home): `grantEnvelope` (OPERATOR), `broadcastCut` (only `SettlementBatches`), `spokesReported`,
  `sendBurns` (anyone), `sendSuspend`, `disconnectSpoke` (GUARDIAN), the global accountant `sent` / `returned`, the
  per-epoch spoke reports and remote pairs. It holds `MESSENGER_ROLE` on the ledger and `MOVER_ROLE` and
  `MESSENGER_ROLE` on every home token: home-side escrow of a move is the hub's own balance.
- `SpokeMessenger` (each spoke): `releaseEnvelope` (OPERATOR on the spoke); routes everything it receives through the
  spoke's guard.
- `RemoteObligationToken` on spokes: the `ObligationToken` rules (no user transfers or approvals except to a mover;
  pause and freeze never block burns), plus `lock`, `unlock`, `burnLocked` and `unlockedBalanceOf`. The spoke guard
  holds `LEDGER_ROLE` (mint, for local payments and inbound MINTs) and `MESSENGER_ROLE` (burn, lock, unlock, and a
  restrict-only `pause` on SUSPEND). A locked balance stays in the holder's wallet and cannot move.
- `SpokeExposureGuard` on spokes (one per spoke; immutable `DOMAIN` and `KIND`): members and their keys on that
  chain (`setMember`), `supplyCap[issuer]`, local envelopes `env[issuer][holder]`, usage `used[issuer][holder]` (the
  spoke's `open`), `locked[epoch][issuer][holder]`, `releasable[issuer][holder]` (parked headroom), and a local FIFO
  queue. Local `pay(to, amount, ref)` by the payer's issuerOps on that chain mints the payer's token to the payee's
  wallet iff `used + amount ≤ env` and the supply cap holds (else queued locally, reason 1 or 2).
  `PERMISSIONED` and `PUBLIC` spokes run the same mechanics; the difference lives at the hub (`domainKind`, §4.4).

### 4.3 Message flows

- **Envelope grant:** hub `grantEnvelope(domain, issuer, holder, amount)` (OPERATOR) → `ledger.reserveEnvelope`
  (checks run, headroom reserved first) → `ENVELOPE_GRANT` → spoke `guard.grant` raises `env`; for an unknown or
  suspended pair it raises nothing and parks the amount as `releasable`. **Release:** spoke
  `SpokeMessenger.releaseEnvelope` (OPERATOR on the spoke) lowers parked headroom first, then unused `env`
  (`ReleaseExceedsFree`) → `ENVELOPE_RELEASE` → hub `ledger.releaseEnvelope`. Allocated ≥ used at every moment.
- **Token move (lock-then-burn):** source `sendMint(issuer, holder, amount, dest, recipient, deadline)` by the
  holder's wallet (`NotHolderWallet`): the token is **locked** (home: transferred into the hub; spoke: `lock` in the
  wallet), the source's position moves (home: `ledger.moveOut`, open → envelope, and `sent[issuer][dest] += amount`;
  spoke: `used` and `env` fall together), and the move is recorded `PENDING`. Destination `receiveMessage(MINT)` with
  the issuer key runs the side's mint check (hub: known, recipient = holder's home wallet, not blocked, accountant,
  `ledger.moveInCheck`; spoke: known, not suspended, recipient = holder's wallet there, not blocked, supply cap). If
  it fails, the nonce is marked `CANCELLED` and `MINT_CANCEL` goes back. If it passes, the inbound rate limit is
  spent (§4.6) and the destination mints (hub: `ledger.moveIn`, `returned += amount`; spoke: `used` and `env` rise
  together), marks the nonce `MINTED` and sends `MINT_ACK`; the source then **burns** the locked amount
  (`MoveCompleted`). On `MINT_CANCEL` the source unlocks and restores the position (hub: `ledger.moveCancelled`,
  `sent −= amount`). Replies carry the move's nonce in `ref` and must match the move (`MoveMismatch`).
  **Deadline:** after `deadline`, anyone may call `cancelExpired(message, attesterSigs)` on the destination — the
  **attesters' signatures only**, no issuer key — which marks the un-minted nonce `CANCELLED` (it can never mint
  afterwards) and sends `MINT_CANCEL`. A token is never burned before its mint is proven, and never minted twice.
- **Cut:** hub `SettlementBatches.cut` → `HubMessenger.broadcastCut(epoch)` → `CUT` to every connected spoke → spoke
  `guard.cut(epoch)` moves every nonzero `used` into `locked` for the epoch, **taking the locked amount out of both
  `env` and `used`**, and locks the tokens → one `BATCH_LOCKED(epoch, issuer, holder, amount)` per locked pair, then
  a **terminator**: `BATCH_LOCKED` with zero `member` and `counterparty` and `amount` = the number of pairs → hub
  `ledger.envelopeToPending` + `ledger.addRemoteToBatch` per pair. `spokesReported(epoch)` is true when every
  connected spoke that was sent the cut has sent its terminator and the pair count matches; `submitPlan` reverts
  `SpokesNotReported` until then.
- **Burn:** batch `COMPLETE` → anyone calls `HubMessenger.sendBurns(epoch)` (once, `BurnsAlreadySent`) → one
  `BURN_BATCH(epoch, issuer, holder, amount)` per remote pair → spoke `guard.burnBatch` burns exactly the locked
  amount (`BurnMismatch`). Until it lands those tokens are *settled-pending-burn*: locked, not usable, only burnable.
  The cut has already taken them out of `env` and `used`; the operator re-grants envelopes as needed.
- **Suspend:** `HubMessenger.sendSuspend(member)` — anyone for a member not in good standing, the guardian for any
  member → `SUSPEND(member)` to every connected spoke → `guard.suspend` marks the member suspended, pauses its token
  there, and **cuts every envelope it is party to down to what is in use** (`env = used`), parking the excess as
  `releasable` for the operator to release. Restrict-only: a `SUSPEND` can never raise anything. Lifting it on a spoke
  is governance (`reinstate`); envelopes return only by new grants.
- **Lost spoke:** `HubMessenger.disconnectSpoke(domain)` (GUARDIAN) removes the remote: nothing more is accepted from
  it and it no longer gates `spokesReported`. Its envelopes stay reserved. Reconnecting is governance (`setRemote`).

### 4.4 Public spokes

On a `PUBLIC` spoke a hub grant draws from the issuer's **free collateral** (`collateral − mandatory backing − other
public envelopes`), not from credit limits; a home → public-spoke move commits collateral the same way. The receiving
bank's exposure there is covered one-for-one. Default credit on a public spoke is 0. A spoke → home move from a
public spoke is refused unless checks (3)–(5) hold at home (`moveInCheck`).

### 4.5 Invariants (all fuzzed)

1. Per issuer and holder: Σ supply over all chains (home token + each spoke's remote token, locks and move escrow
   included) = home open + home part of pending + spoke open + spoke locked + pending-move escrow; net positions
   consistent.
2. Per pair and spoke: `used ≤ env` on the spoke and `env(spoke) ≤ envelope[d][i][h]` at the hub.
3. Every accepted credit-taking action (home pay, permissioned grant, public-spoke move landing home) leaves every
   limit of §3.5 satisfied with envelopes counted as fully used.
4. No mint without the issuer key and the attester majority; no nonce minted twice; a cancelled nonce never mints;
   every honest message delivers.
5. No `SUSPEND` raises a limit or unfreezes anything.
6. A public-spoke envelope ≤ attested free collateral at grant time.

### 4.6 Bounds on a failed chain or transport

- `supplyCap[issuer]` on each spoke (static; raised by governance through the timelock, lowered by the guardian);
- **inbound mint rate limit** per (source domain, issuer) on the receiving chain: a token bucket of `capacity`
  refilling at `capacity / window` (default window 1 h when set with 0). Governance sets or raises it with
  `setRateLimit` (the bucket starts full); the guardian may only lower it (`lowerRateLimit`). It limits mints, not
  burns. **An exhausted bucket reverts the delivery (`RateLimited`), which is retryable: the message stays
  deliverable and is not cancelled. An unset bucket has capacity 0, so the corridor is closed;**
- the hub's **global accountant**: per (issuer, domain) the hub tracks `sent` (locked at home for moves to that spoke,
  less cancelled moves) and `returned` (minted at home from that spoke); a spoke can never mint at home more than home
  recorded as sent to it (and spoke-to-spoke always goes through home);
- attesters and issuers read the source chain from nodes they run themselves (operational rule; not enforceable on
  chain).

## 5. Back office (Go)

### 5.1 Rails simulator (`internal/rails`)

- **CHIPS:** weekdays only; session opens 21:00 ET the previous calendar day, payments cut off 17:00 ET; no size limit;
  each released payment is final at release and gets a sequence id (`CHIPS-yyyymmdd-nnnnnn`); closing positions are
  tracked for a 30-minute funding window. The release algorithm and prefunding are not simulated.
- **RTP:** 24x7; per-payment limit $10,000,000; each participant has a prefunded position in a joint account, funded
  only via Fedwire (weekdays 21:00 prev day–19:00 ET); a payment is final at posting; transaction id
  `RTP-yyyymmdd-nnnnnnnn`; camt.056 is a *request* recorded in the journal that never reverses a posted payment.
- Both journals are append-only and expose a finality feed (the listener's only input). `CopyReference` injects a
  payment that copies another payment's message (fault test).

### 5.2 ISO 20022 (`internal/iso20022`)

pacs.008.001.08 for RTP legs (`RmtInf/Strd/CdtrRefInf/Ref` = the batch's ISO 11649 `RF` reference) and
pacs.009.001.08 for CHIPS FI-to-FI legs (that version has unstructured remittance only, so the `RF` reference is the
single `Ustrd` line). `EndToEndId` (also `InstrId` and `TxId`) = `CS<batch>-L<leg>-<n>` (≤ 35 chars). Only canonical
forms parse back. camt.054 output is for reconciliation only.

### 5.3 Listener (`internal/listener`)

n signer processes (5 in the tests and demo), each with its own key and its own rail-journal cursors. Each signs an
EIP-712 `Payment` only for a journal entry that is a final payment on CHIPS or RTP, whose message parses to a batch
and leg and agrees with the entry (amount, accounts), whose leg is open on chain (read afresh from the chain each
time), whose payer account belongs to the leg payer or an allowed waterfall payer and payee account to the leg
payee, and which it has not signed before. The aggregator collects k signatures from distinct current signers,
orders them, and calls `SettlementAttestor.attestPayment`. At start the runner checks that every key is a current
signer, reads k from the contract, and checks that its EIP-712 digests equal the contract's. Unmatched entries go
to a manual-review queue; return requests and duplicates are skipped; nothing is signed
for them. Funding attestations: each signer signs a `Funding` only if its own source reports exactly that value;
`asOf` is strictly increasing per (kind, member) and each nonce is new.

### 5.4 Operator (`internal/operator`)

- business window: `BUSINESS` from the CHIPS open (21:00 ET the previous day) to the end-of-day cut (16:30 ET) on
  business days, else `OFF_HOURS` (set on chain by `OPERATOR_ROLE` at each boundary, with `setBusinessDay(yyyymmdd)`
  when entering `BUSINESS`; only `OFF_HOURS` restricts). Payments after the end-of-day cut are off-hours, so nothing
  taken on credit carries overnight. `offHoursUsed` resets when the window returns to `BUSINESS`. Off-hours, every cut
  settles over RTP from the debtor's prefund; the rulebook earmarks the attested prefund for that purpose;
- triggers: `CapReached` → cut (CAP); `SettlementRequested` → cut (RECEIVER_CALL); 16:30 ET → final cut of the day
  (END_OF_DAY), so every position settles inside the business day. Triggers that arrive while a batch is in flight
  wait for it; a cut is skipped when the open epoch's `epochHash` is zero (no payments);
- plan builder: multilateral net per member → legs from net debtors to net creditors, largest first (at most
  members − 1 legs), checked locally as the contract will, then `submitPlan`; the operator verifies that the chain's
  `rfReference(batch)` equals its own;
- rail choice (`ChooseRail`): CHIPS while the CHIPS session is open with at least `MinCHIPSLeft` (default 15 min)
  before 17:00 ET, deadline `now + PayInWindow` (default 1 h) capped at 17:00 ET; else RTP split into ≤ $10M parts,
  deadline `now + PayInWindow`. The planner does not check the payer's RTP position; the rail refuses a payment that
  exceeds it;
- pay-in schedule: per part `{batch, leg, part, payer, payee, amount, rail, RF reference, EndToEndId, deadline}`;
- default path: after the deadline, `declare`; then waterfall instructions from `CoverInstruction` events (COLLATERAL
  and POOL pay from joint sub-accounts; survivors pay their shares; the payee's own share is absorbed, not paid);
- after each finalized batch: `drain`, then three-way reconciliation (`internal/reconcile`: rail journals ↔ listener
  log ↔ chain `PaymentRecorded`) with a halt on any break: new cuts are refused until it clears.
- The home-chain back office is complete at this revision; the cross-chain transport (attesters, issuer signers,
  relayer) and the envelope rebalancer are being added under `internal/xchain`.

### 5.5 Economics (`internal/econ`, `cmd/econ`)

Synthetic interbank flows (N banks, heavy-tailed sizes, intraday seasonality) through three settlement designs:
gross RTGS (liquidity = Σ gross outflows), prefunded continuous netting (CHIPS-like: liquidity = prefund needed to
release every payment, with and without a queue), and this model (credit within limits, cap and end-of-day
settlement). Outputs per design: liquidity used, settlement efficiency (value settled / liquidity), opening balances
needed, number of fiat settlements, max exposure, and for this model the collateral and cover-2 pool required.
Results in [economics.md](economics.md).

## 6. Known limits

These are properties of the code at this revision, stated so that reviewers do not have to find them.

- **A disconnected spoke strands its in-flight state.** After `disconnectSpoke`, nothing from that spoke is accepted:
  moves to it that are still `PENDING` keep their tokens in the hub's escrow (no `MINT_ACK` or `MINT_CANCEL` can
  arrive), its locked batch pairs are never reported or burned, and its envelopes stay reserved at the hub. The loss
  is bounded by the envelopes granted to it, its supply caps and the inbound rate limit, and the reserved headroom
  keeps counting against the members' limits until governance reconnects the spoke or the members agree a resolution.
- **The accountant's `sent` count only grows** (it falls only when a move is cancelled). Settlement burns on a spoke
  do not reduce it, so it bounds cumulative returns from a spoke by cumulative sends to it, not by what the spoke
  holds now; and tokens created on a spoke by local payments can move home only within `sent − returned`.
- **One batch in flight.** A cut needs the previous batch finalized, which bounds the number of cuts a day by the
  time a batch takes to complete (see [economics.md](economics.md)).
- **The cover-2 pool requirement is attested, not computed on chain.** `poolRequired` is whatever the listener last
  attested (kind `POOL_REQUIRED`); the chain does not recompute the two largest debit caps when limits change.
- **`EXITED` is unreachable.** No function sets it; an orderly exit procedure is not implemented.
- **Equal-weight survivor fallback.** When no survivor granted the defaulter an elective limit, every `ACTIVE` or
  `SUSPENDED` member, `PREFUND_ONLY` members included, bears an equal share, although the prefund-only tier is meant
  to stay outside loss sharing.
- **Public-spoke collateral is released at the cut, not at settlement.** `envelopeToPending` calls `_takeEnvelope`,
  which calls `releasePublic`: from the cut until the batch completes, the locked public-spoke amount is ordinary
  pending exposure at the hub and the issuer's freed collateral can be committed again.
- **`epochHash` covers home payments only.** Spoke payments, moves landing home (`moveIn`) and cancelled moves
  (`moveCancelled`) change `open` without entering the hash, and the operator skips a cut whose `epochHash` is zero.
- **No window rule on spokes.** Check (2) applies to home `pay` only; a permissioned spoke's envelope stays usable
  outside the business window (it was reserved, and counted, within it).
