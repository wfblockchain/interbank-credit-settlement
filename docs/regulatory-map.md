# Regulatory map

This document sets each design choice of the model against the international standards and the US rules that would
apply to it, and lists the legal questions the model cannot answer by itself. It is an analysis to support review,
not legal advice. Every regulatory statement links to a public source; quotations are from those sources.

The contracts and parameters referred to are described in [design.md](design.md) and
[rulebook-term-sheet.md](rulebook-term-sheet.md).

## 1. What kind of system this is

In the language of the international standards, the model is a **deferred net settlement (DNS) payment system
without a settlement guarantee in which participants face credit exposures to each other**: a member that holds
another member's token has extended it credit until the next net fiat settlement. That classification drives most
of what follows.

| Standard or rule | Why it applies | Source |
|---|---|---|
| CPSS-IOSCO Principles for Financial Market Infrastructures (PFMI), April 2012 | The global standard for systemically important payment systems | [PFMI (BIS)](https://www.bis.org/cpmi/publ/d101a.pdf); [IOSCO-hosted copy](https://www.iosco.org/library/pubdocs/pdf/IOSCOPD377-PFMI.pdf) |
| Federal Reserve Policy on Payment System Risk (PSR), Part I | Applies the PFMI to private systems expected to settle "a daily aggregate gross value of U.S. dollar-denominated transactions exceeding $5 billion on any day during the next twelve months" | [Federal Reserve, PSR](https://www.federalreserve.gov/paymentsystems/psr_about.htm) |
| Regulation HH (12 CFR 234) | Binding standards for a financial market utility designated by FSOC; designation weighs value, counterparty exposure and interdependencies, and FSOC may also designate an *activity* | [12 CFR 234.2](https://www.law.cornell.edu/cfr/text/12/234.2); [12 CFR 234.3](https://www.law.cornell.edu/cfr/text/12/234.3); [12 USC 5463](https://www.law.cornell.edu/uscode/text/12/5463) |
| Regulation F, SCCL, national-bank lending limits | Each member's exposure to each other member is a credit exposure under its own prudential limits | §3 below |
| FDICIA netting, FDIC receivership powers, UCC Article 4A | Whether netting and finality survive a member's failure | §4 below |
| GENIUS Act, FDIC April 2026 proposal | Whether the token is a deposit or something else | §5 below |

For comparison: the system the US already designated in this space, CHIPS, has had its operator designated as a
systemically important financial market utility since July 2012
([Treasury, 2012 designations](https://home.treasury.gov/system/files/261/2012-Appendix-A-Designation-of-Systemically-Important-Market-Utilities.pdf)).
A new system that *creates* bank-to-bank credit exposure would meet the statutory designation factors of counterparty
exposure and interdependency once volumes are material. The model is therefore built to the Regulation HH standards
from the start.

## 2. The design choices against the PFMI and the Federal Reserve's standards

| Design choice | Requirement | How the model meets it | What remains |
|---|---|---|---|
| **Bilateral limits, receiver cap, debit cap, system maximum**, all checked before a token moves; breaching payments queue | PFMI P4: "effectively measure, monitor, and manage its credit exposures"; 3.4.4: in a DNS system without a guarantee, give participants the "capacity to ... measure and monitor their current exposures to each other". The 1990 G10 netting standards asked that "limits are placed on the maximum level of credit exposure that can be produced by each participant" ([BIS, Report on Interbank Netting Schemes](https://www.bis.org/cpmi/publ/d04.htm)) | `ExposureLedger.pay` checks (3)–(5); every position is on chain and readable by every member; `bilateralNet`, `netPosition`, `check` are public views | Exposure dashboards for members are an operational deliverable |
| **Defaulter-pays collateral**: the mandatory limits a member receives total at most its own collateral | PFMI P4 (cover exposures "fully with a high degree of confidence using collateral", 3.4.6); P5: collateral "with low credit, liquidity, and market risks" and "appropriately conservative haircuts" | `CreditLimits.mandatory` = min($5M, free collateral / (credit members − 1)), the EURO1 formula. The collateral is held off chain (central bank money in a joint account, or haircut Treasuries) and attested 3-of-5 | Haircuts, eligible collateral and concentration limits belong in the rulebook; the chain only records attested values |
| **Cover-2 loss pool**, required before every cut | P4 KC5 (3.4.7): a DNS system with no settlement guarantee should hold "at a minimum, sufficient resources to cover the exposures of the two participants and their affiliates that would create the largest aggregate credit exposure in the system" | `SettlementBatches.cut` reverts `PoolNotReplenished` while `poolTotal < poolRequired`; the requirement (two largest debit caps) is computed by the operator and attested | The requirement is attested, not computed on chain (see [design.md §6](design.md#6-known-limits)). Affiliates are not modelled: members of one group would have to be aggregated by the rulebook |
| **Liquidity to settle the same day** if the largest debtor fails | P7 KC3: liquid resources "to effect same-day settlement ... [under] the default of the participant and its affiliates that would generate the largest aggregate payment obligation"; KC5: qualifying liquid resources; KC6: "should not assume the availability of emergency central bank credit" | The waterfall pays a defaulter's legs from its collateral and the pool the same day, over CHIPS or RTP, from sub-accounts of the joint account | Treasuries count as liquid only with "prearranged and highly reliable funding arrangements" (KC5). The pool's form decides whether P7 is met; see open question 6 |
| **End-of-day cut at 16:30 ET**; every position taken in the business window settles the same business day | P8: "final settlement, at a minimum by the end of the value date"; 3.4.5: "avoid carrying over these exposures to the next day"; 3.8.5: deferral to the next business day "can entail overnight risk exposures"; Reg HH 234.3(a)(8) | Operator: END_OF_DAY cut at 16:30, CHIPS pay-in deadline 17:00. Chain: one batch at a time, a plan that must net exactly, burns only when every leg is final | The end-of-day rule is enforced by the operator, not by the chain; a missed deadline turns into the default path, whose cover payments have no on-chain deadline |
| **Three triggers** (receiver cap, receiver call, end of day) | P8 KC2: "consider adopting RTGS or multiple-batch processing during the settlement day"; 3.7.6 suggests "continuous or extremely frequent batch settlement" | Cuts run as often as triggers fire, one batch in flight | One batch in flight bounds the cut rate (about 18 a day at 30-minute completion in the simulation, [economics.md](economics.md)) |
| **No unwind**; a token transfer is final when it passes the checks | 3.7.3: "The potential total liquidity pressure of unwinding could be equal to the gross value of the netted transactions"; P7 asks rules that "avoid unwinding, revoking, or delaying" settlement | No function restores tokens or positions; the only exit from `PLANNED` is completion, by the debtor or the waterfall | Legal finality depends on the rulebook and the netting law (§4) |
| **Settlement over CHIPS or RTP** | P9: "conduct its money settlements in central bank money where practical and available" | Both rails settle in accounts at the Federal Reserve Bank of New York: RTP from a prefunded joint account; CHIPS from a prefunded balance account ([Richmond Fed EB 26-28](https://www.richmondfed.org/publications/research/economic_brief/2026/eb_26-28); [Federal Reserve Board, R-1107](https://www.federalreserve.gov/boarddocs/press/boardacts/2001/20010530/attachment.pdf)) | The token leg is commercial bank money by design; the analysis must show that the *final* settlement asset is central bank money |
| **The listener attests the rails' own finality events**, 3 of 5, each rail transaction id once | P8 KC1: "clearly define the point at which settlement is final" | Only a final rail entry, matched to an open leg by reference, payer, payee and amount, can be attested; acknowledgements and camt.054 are reconciliation output only; a reconciliation break halts cuts | The evidence is only as good as the feed: see open question 8 |
| **Default rules**: declaration after the deadline, waterfall (collateral, pool, survivors pro rata to elective limits), pool replenished before the next cut | P13 KC1: rules that "address the replenishment of resources following a default"; KC4: test with participants "at least annually"; 3.13.1: "timely completion of settlement" | `DefaultManager.declare`, `CoverInstruction` events, `absorbLoss`; `cut` blocked until the pool is whole | Annual testing and publication are rulebook duties |
| **Access tiers**: CREDIT and PREFUND_ONLY | P18: "objective, risk-based, and publicly disclosed criteria for participation, which permit fair and open access", with "the least-restrictive impact on access"; Reg HH 234.3(a)(18) | A smaller bank can join without granting or receiving mandatory credit; its exposure is bounded by its own collateral | The admission criteria themselves are rulebook content; see open question 10 |
| **Restrict-only guardian, timelocked governance** | P2 (governance) and P17 (operational risk) generally | Every contract's admin is a timelock; fast actions can only lower or stop | Key ceremonies and separation of duties are operational |

### Precedents behind these choices

- **Pre-2001 CHIPS** required every participant to set bilateral credit limits from October 1984 and added sender
  net debit caps from 1986 ([GAO/GGD-97-73](https://euro.ecom.cmu.edu//resources/elibrary/epay/GAO_payment_systems.htm);
  [FRB Dallas, 1989](https://www.dallasfed.org/~/media/documents/research/papers/1989/wp8910.pdf)). From 1990 a
  collateralized loss-sharing obligation stood behind them. On 22 January 2001 CHIPS moved to prefunded real-time
  final settlement "in response to demands of CHIPS participants to eliminate any possibility of an unwind"
  ([Federal Reserve Board, R-1107](https://www.federalreserve.gov/boarddocs/press/boardacts/2001/20010530/attachment.pdf)).
  A simulation on 1983 CHIPS data had found that one large participant's failure to settle "could result in close
  to half of all other participants in turn being unable to settle"
  ([IMF, 1994, ch. 7](https://www.elibrary.imf.org/display/book/9781557753861/ch07.xml)). This is why the model has
  no unwind and a pre-funded waterfall.
- **CHAPS before RTGS.** The Bank of England found that net-settlement exposures were set "not by the direct credit
  judgments made by the receiving bank ... but rather by the pattern of payments", and that "the only safe way to
  control it is therefore to remove it"
  ([Bank of England Quarterly Bulletin, 1993](https://www.bankofengland.co.uk/-/media/boe/files/quarterly-bulletin/1993/the-uk-approach-to-controlling-large-value-payment-systems.pdf)).
  This is why the forced (mandatory) part of each limit is small and fully backed by the debtor's own collateral.
- **EURO1** is the live system with mandatory bilateral limits. Its mandatory element "must be maintained unless a
  majority of participants request its cancellation", the system caps every debit cap, the pool must be
  "replenished prior to starting up the system on the next operating day", and "pre-fund participants" stay outside
  loss sharing ([ECB oversight assessment, 2011](https://www.ecb.europa.eu/pub/pdf/other/oversightassessment201111en.pdf)).
  Under stress it cut the mandatory limit by 80% and made discretionary limits changeable on the same day, so that
  "overnight credit risk becomes intraday credit risk"
  ([presentation to the ECB COGEPS, 2013](https://ecb.europa.eu/paym/groups/pdf/cogeps/20130305/20130305_COGEPS_Item_D11_1.pdf)).
  The model copies the mandatory formula, the majority switch, same-day elective changes, the system maximum and the
  non-credit tier.

## 3. Credit-exposure rules for each member

A member that holds another member's token has a claim on it. Three US regimes treat intraday exposure leniently and
anything longer as credit. The model is built so that exposure ends every business day by its terms.

| Regime | Rule | Design response | Source |
|---|---|---|---|
| **Regulation F §206.3** | When a correspondent's condition "creates significant payment risk", the bank must "limit the bank's exposure to the correspondent, either by the establishment of internal limits or by other means" | A member can always cut what it will accept from a weak counterparty without a bilateral credit decision against the network's minimum: `restrict` (mandatory to 0 on a PCA or supervisory trigger), `setRegCap` (a cap with a logged reason), `setElective` (same day), `lowerReceiverCap`, and `requestSettlement` to settle what is already held | [12 CFR 206.3](https://www.law.cornell.edu/cfr/text/12/206.3) |
| **Regulation F §206.4** | Interday credit exposure to a correspondent that is not adequately capitalized is limited to 25% of total capital; exposure from "settlement of transactions, intraday exposure" is excluded; collateralized exposure may be excluded; enforceable netting may be applied | Same-day settlement keeps positions intraday; the mandatory part is collateralized; netting rests on the netting contract (§4) | [12 CFR 206.4](https://www.law.cornell.edu/cfr/text/12/206.4) |
| **SCCL §252.71(v), §252.72, §252.77** | Covered companies are limited to 25% of tier 1 capital per counterparty (15% between the largest banks). "Intraday credit exposure" is exempt only if it "by its terms is to be repaid, sold, or terminated by the end of its business day in the United States" | The end-of-day cut and same-day settlement are rules of the system, not observed behaviour; outside the business window only prefunded payments are possible; a covered member near its headroom uses `setRegCap` | [12 CFR 252.71](https://www.law.cornell.edu/cfr/text/12/252.71); [252.72](https://www.law.cornell.edu/cfr/text/12/252.72); [252.77](https://www.law.cornell.edu/cfr/text/12/252.77) |
| **12 CFR 32.2(q)** (national-bank lending limits) | "Loans and extensions of credit" exclude intraday overdrafts paid before close of business and one-day Federal funds | Same-day settlement | [12 CFR 32.2](https://www.law.cornell.edu/cfr/text/12/32.2) |

The weekend and holiday rule follows from the rails. RTP runs 24x7 but caps each payment at $10M
([ABA Banking Journal, 2024](https://bankingjournal.aba.com/2024/12/rtp-network-to-raise-individual-transaction-limit-to-10m/);
[Richmond Fed EB 26-28](https://www.richmondfed.org/publications/research/economic_brief/2026/eb_26-28)), and its
prefunded positions can be funded only over Fedwire, so participants "must preposition prefunding ... for
transactions they anticipate sending over weekends and holidays"
([comment letter, Docket OP-1831](https://www.federalreserve.gov/SECRS/2024/September/20240918/OP-1831/OP-1831_090424_160594_327837303844_1.pdf)).
CHIPS runs on weekdays only (same source), and Fedwire stays closed on Saturdays even after its planned 22x6 expansion
([Federal Register 2025-19942](https://www.govinfo.gov/content/pkg/FR-2025-11-17/html/2025-19942.htm)). Credit
taken on a Saturday could not settle before Monday and would be interday. The model therefore allows no unsecured
credit outside the business window: off-hours payments must fit within the payer's attested RTP prefund.

Two further points for members' treasury and capital teams. A claim on a US depository institution carries a 20%
risk weight under the standardized approach ([12 CFR 217.32](https://www.law.cornell.edu/cfr/text/12/217.32)). For
the issuing bank, an open position held by another bank is unsecured wholesale funding from a financial-sector entity,
a 100% outflow under the LCR unless it is an operational deposit
([12 CFR 249.32](https://www.law.cornell.edu/cfr/text/12/249.32)). Both favour short positions.

## 4. Netting, finality and receivership

| Rule | Content | Design response | Source |
|---|---|---|---|
| **FDICIA §4404** | Multilateral netting among "members" of a "clearing organization" is enforceable "notwithstanding any other provision of State or Federal law", other than listed carve-outs including §1821(e); a failed member's position is its net amount under the netting contract | The rulebook is the netting contract; the operator is meant to be a clearing organization. Netting fixes a failed member's *net* debit but does not pay it: the waterfall does | [12 USC 4404](https://www.law.cornell.edu/uscode/text/12/4404); [12 USC 4402](https://www.law.cornell.edu/uscode/text/12/4402); [12 USC 4405](https://www.law.cornell.edu/uscode/text/12/4405) |
| **12 USC 1821(e)** | The FDIC as receiver may repudiate contracts and transfer qualified financial contracts all-or-none; counterparties may not close out until "5:00 p.m. (eastern time) on the business day following the date of the appointment of the receiver" | The model never relies on closing out a member's contracts: it settles a defaulter's legs from pre-funded resources the same day | [12 USC 1821](https://www.law.cornell.edu/uscode/text/12/1821) |
| **UCC 4A-103** | A payment order is an instruction to pay a beneficiary where the receiving bank "is to be reimbursed by debiting an account of, or otherwise receiving payment from, the sender" | A token transfer that tells Bank B to credit its customer, with Bank A to pay through the system, fits this; the rulebook states each message's role | [UCC 4A-103](https://www.law.cornell.edu/ucc/4A/4A-103) |
| **UCC 4A-403(b)** | In a multilateral netting system, the receiving bank "receives final settlement when settlement is complete in accordance with the rules of the system" | Settlement is complete when the batch is `COMPLETE`; that event is on chain and attested from the rails' finality | [UCC 4A-403](https://www.law.cornell.edu/ucc/4A/4A-403) |
| **UCC 4A-405(d), (e)** | A system rule may make payments to beneficiaries provisional; if a netting system fails to settle, "the acceptance by the beneficiary's bank is nullified" | The rulebook adopts no provisional-payment rule, and settlement cannot fail for want of resources while the waterfall holds. 4A-405(e) is exactly the unwind the PFMI warn against | [UCC 4A-405](https://www.law.cornell.edu/ucc/4A/4A-405) |

Governing law is New York for the rulebook and every payment order, matching existing US large-value practice.

## 5. The token: a deposit, issued natively on every chain

| Rule | Content | Design response | Source |
|---|---|---|---|
| **GENIUS Act §2(22)** | "Payment stablecoin" does not include a digital asset that "is a deposit ... including a deposit recorded using distributed ledger technology" | Each token is documented as a deposit liability of its issuer, held only by other members, never onward-transferable | [Pub. L. 119-27](https://www.govinfo.gov/content/pkg/PLAW-119publ27/html/PLAW-119publ27.htm) |
| **FDIC proposal, April 2026** | The technology used to record or transfer a deposit "is not a factor in applying the statutory definition"; the proposal warns "there may be tokenized bank liabilities that are not deposits" | The token is the issuer's own liability on every chain it appears on | [Federal Register 2026-06974](https://www.federalregister.gov/documents/2026/04/10/2026-06974/genius-act-requirements-and-standards-for-fdic-supervised-permitted-payment-stablecoin-issuers-and); [proposal text](https://public-inspection.federalregister.gov/2026-06974.pdf) |
| **The same proposal, question 138** | "How should the FDIC view a digital asset that only represents an interest in or claim on a deposit ... rather than being the tokenized deposit itself? ... could such a product be viewed as a payment stablecoin backed by tokenized deposits?" | **No wrapping.** A token on a spoke is minted by the issuer's own contract under the issuer's own key, and the source burns its tokens once the mint is proven; nothing on a spoke is a claim on tokens escrowed elsewhere. See [cross-chain.md](cross-chain.md) | [proposal text](https://public-inspection.federalregister.gov/2026-06974.pdf) |
| **Deposit insurance** | Corporate deposits are insured up to the standard maximum in aggregate | Insurance is immaterial against interbank positions of millions; the receivership feature that matters is depositor preference, which favours the deposit framing | [12 CFR 330.11](https://www.law.cornell.edu/cfr/text/12/330.11) |

The GENIUS implementing rules were still at proposal stage in the sources reviewed (October 2026).

## 6. Open legal questions

The model takes a position on each of these, but each needs a lawyer's answer before any real deployment.

1. **Clearing-organization status.** Does the operator meet the full definition of a "clearing organization" in
   [12 USC 4402](https://www.law.cornell.edu/uscode/text/12/4402) (and the Board's Regulation EE), so that §4404
   applies to every member? A netting opinion is needed for each member's insolvency regime.
2. **Payment orders.** Is each token transfer a UCC 4A payment order, and is the batch's fiat leg the "settlement"
   of 4A-403(b)? Which role does each message play, and does New York law govern under the system-rule choice of law?
3. **The receivership stay.** `DefaultManager.declare` can run as soon as a pay-in deadline passes. If the debtor was
   placed in receivership, the FDIC's powers under §1821(e) apply. The waterfall does not need the failed bank's
   cooperation, but whether drawing its attested collateral and recording cover payments is consistent with the stay
   needs analysis.
4. **Deposit characterization.** Does an interbank token balance meet the FDIA definition of "deposit", so that the
   GENIUS exclusion and depositor preference apply? How is "due to depository institutions" booked across chains?
5. **Several ledgers, one liability.** Question 138 of the FDIC proposal asks about claims on deposits. The model mints
   natively on each chain; does a regulator accept a token that exists on several chains as one deposit whose total is
   the sum across chains? How does the issuer aggregate holdings for insurance and for the proposal's recordkeeping
   question (question 137)?
6. **Qualifying resources.** Are collateral and pool contributions held as Treasuries "qualifying liquid resources"
   under PFMI P7 KC5? What prearranged funding makes them usable on the same day, including after 17:00 ET?
7. **"By its terms" for SCCL.** The end-of-day settlement is a system rule. Does a position that settles late through
   the default path (cover payments have no on-chain deadline) remain intraday for SCCL, Regulation F and Part 32?
8. **Finality evidence.** The listener can be no better than the rail data it reads. A listener operated outside
   the rail operator sees bank-reported entries, not the rail's own posting. Can the operator obtain a direct finality
   feed from CHIPS and RTP? The RTP Operating Rules' finality wording and its support for pacs.009 were not confirmed
   from primary documents.
9. **Designation.** At what volume would FSOC designate the system or the activity
   ([12 USC 5463](https://www.law.cornell.edu/uscode/text/12/5463))? The PSR applies above $5bn a day regardless.
10. **Access and competition.** Mandatory mutual credit makes each admission a credit decision imposed on incumbents.
    Are the admission criteria and the tiers "objective, risk-based, and publicly disclosed"
    ([12 CFR 234.3(a)(18)](https://www.law.cornell.edu/cfr/text/12/234.3))? A Department of Justice business review
    ([28 CFR 50.6](https://www.law.cornell.edu/cfr/text/28/50.6)) is the usual route to comfort on consortium rules.
11. **Public chains.** Can a deposit token of a regulated bank exist on a public chain at all, given holder
    restrictions, sanctions screening and the public visibility of balances? The model keeps public spokes
    collateral-only and member-to-member, but the question is not technical.
12. **Prefund earmarking.** Off-hours credit relies on the attested RTP prefund being available to settle those
    payments. Can a rulebook earmark a member's RTP position for this purpose in a way that survives the member's
    failure?
