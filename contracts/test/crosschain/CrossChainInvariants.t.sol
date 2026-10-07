// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { CrossChainHandler } from "./utils/CrossChainHandler.sol";

/// Design §4.5 invariants 1–6 over the hub and both spokes, with messages relayed in random order.
/// afterInvariant asserts the run actually completed cross-chain batches (remote pairs burned on
/// a spoke) and moves both ways, so a green result cannot come from a run that settled nothing.
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
/// forge-config: default.invariant.fail-on-revert = true
contract CrossChainInvariantsTest is StdInvariant, Test {
    CrossChainHandler internal h;

    function setUp() public {
        h = new CrossChainHandler();
        bytes4[] memory sel = new bytes4[](36);
        uint256 n;
        sel[n++] = CrossChainHandler.homePay.selector;
        sel[n++] = CrossChainHandler.homePay.selector;
        sel[n++] = CrossChainHandler.homePay.selector;
        sel[n++] = CrossChainHandler.spokePay.selector;
        sel[n++] = CrossChainHandler.spokePay.selector;
        sel[n++] = CrossChainHandler.spokePay.selector;
        sel[n++] = CrossChainHandler.spokePay.selector;
        sel[n++] = CrossChainHandler.spokeDrain.selector;
        sel[n++] = CrossChainHandler.spokeCancel.selector;
        sel[n++] = CrossChainHandler.grant.selector;
        sel[n++] = CrossChainHandler.grant.selector;
        sel[n++] = CrossChainHandler.grant.selector;
        sel[n++] = CrossChainHandler.release.selector;
        sel[n++] = CrossChainHandler.moveOut.selector;
        sel[n++] = CrossChainHandler.moveOut.selector;
        sel[n++] = CrossChainHandler.moveHome.selector;
        sel[n++] = CrossChainHandler.moveHome.selector;
        sel[n++] = CrossChainHandler.relay.selector;
        sel[n++] = CrossChainHandler.relay.selector;
        sel[n++] = CrossChainHandler.relay.selector;
        sel[n++] = CrossChainHandler.expire.selector;
        sel[n++] = CrossChainHandler.advance.selector;
        sel[n++] = CrossChainHandler.advance.selector;
        sel[n++] = CrossChainHandler.advance.selector;
        sel[n++] = CrossChainHandler.advance.selector;
        sel[n++] = CrossChainHandler.advance.selector;
        sel[n++] = CrossChainHandler.advance.selector;
        sel[n++] = CrossChainHandler.forge.selector;
        sel[n++] = CrossChainHandler.replay.selector;
        sel[n++] = CrossChainHandler.suspendCycle.selector;
        sel[n++] = CrossChainHandler.warp.selector;
        sel[n++] = CrossChainHandler.release.selector;
        sel[n++] = CrossChainHandler.spokeDrain.selector;
        sel[n++] = CrossChainHandler.roundTrip.selector;
        sel[n++] = CrossChainHandler.roundTrip.selector;
        sel[n++] = CrossChainHandler.roundTrip.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        targetContract(address(h));
    }

    /// 1. Σ supply on all chains (escrow and locks included) = home open + home part of pending +
    ///    spoke open + spoke locked + pending-move escrow, per holder and per issuer.
    function invariant_1_supplyAccounted() public view {
        assertTrue(h.supplyAccounted(), "supply not accounted for");
        assertTrue(h.positionsConsistent(), "net positions inconsistent");
    }

    /// 2. used ≤ env on every spoke, env on the spoke ≤ envelope at the hub.
    function invariant_2_envelopesNested() public view {
        assertTrue(h.envelopesNested(), "envelope nesting broken");
    }

    /// 3. Every accepted credit-taking action (home pay, permissioned grant, public-spoke move
    ///    landing home) left every limit satisfied with envelopes counted as fully used.
    function invariant_3_limits() public view {
        assertEq(h.limitViolations(), 0, "limit broken");
    }

    /// 4. No mint without the attester majority and the issuer key; no nonce minted twice; a
    ///    cancelled nonce never mints; every honest message delivers.
    function invariant_4_mintAuthority() public view {
        assertEq(h.forgedAccepted(), 0, "forged MINT accepted");
        assertEq(h.replayAccepted(), 0, "replay accepted");
        assertTrue(h.movesExclusive(), "a move both minted and cancelled");
        assertEq(h.deliveryReverts(), 0, "an honest message failed to deliver");
    }

    /// 5. No SUSPEND raises a limit or unfreezes anything.
    function invariant_5_suspendRestrictOnly() public view {
        assertEq(h.suspendRaised(), 0, "SUSPEND raised something");
    }

    /// 6. A public-spoke envelope ≤ attested free collateral at grant time.
    function invariant_6_publicEnvelopeCollateral() public view {
        assertEq(h.publicCollateralViolations(), 0, "public envelope above free collateral");
    }

    /// 7. A nonzero home open position implies a nonzero epoch commitment (moves included).
    function invariant_7_openCommitted() public view {
        assertTrue(h.openImpliesEpochHash(), "open position outside the epoch commitment");
    }

    function afterInvariant() external {
        console2.log(
            string.concat(
                "xcov calls=", vm.toString(h.calls()),
                " homePays=", vm.toString(h.homePays()),
                " spokePays=", vm.toString(h.spokePays()),
                " spokeQueued=", vm.toString(h.spokeQueued()),
                " drained=", vm.toString(h.spokeDrained()),
                " qCancels=", vm.toString(h.spokeCancels()),
                " grantsPerm=", vm.toString(h.grantsPerm()),
                " grantsPub=", vm.toString(h.grantsPub()),
                " releases=", vm.toString(h.releases())
            )
        );
        console2.log(
            string.concat(
                "xcov movesOut=", vm.toString(h.movesOut()),
                " movesOutDone=", vm.toString(h.movesOutDone()),
                " movesHome=", vm.toString(h.movesHome()),
                " movesHomeDone=", vm.toString(h.movesHomeDone()),
                " cancelled=", vm.toString(h.movesCancelled()),
                " refused=", vm.toString(h.mintsRefused()),
                " expiries=", vm.toString(h.expiries()),
                " delivered=", vm.toString(h.delivered())
            )
        );
        console2.log(
            string.concat(
                "xcov cuts=", vm.toString(h.cuts()),
                " plans=", vm.toString(h.plans()),
                " legs=", vm.toString(h.legsPaid()),
                " finalized=", vm.toString(h.finalized()),
                " xBatches=", vm.toString(h.xBatches()),
                " remoteBurns=", vm.toString(h.remoteBurns()),
                " remoteBurnValue=", vm.toString(h.remoteBurnValue()),
                " homeBurnValue=", vm.toString(h.homeBurnValue()),
                " suspends=", vm.toString(h.suspends()),
                " forgedRejected=", vm.toString(h.forgedRejected()),
                " replaysRejected=", vm.toString(h.replaysRejected())
            )
        );
        string memory stats = vm.envOr("XINV_STATS_FILE", string(""));
        if (bytes(stats).length != 0) {
            vm.writeLine(
                stats,
                string.concat(
                    vm.toString(h.calls()), ",", vm.toString(h.spokePays()), ",", vm.toString(h.grantsPerm() + h.grantsPub()), ",",
                    vm.toString(h.releases()), ",", vm.toString(h.movesOutDone()), ",", vm.toString(h.movesHomeDone()), ",",
                    vm.toString(h.movesCancelled()), ",", vm.toString(h.expiries()), ",", vm.toString(h.finalized()), ",",
                    vm.toString(h.xBatches()), ",", vm.toString(h.remoteBurns()), ",", vm.toString(h.remoteBurnValue()), ",",
                    vm.toString(h.suspends()), ",", vm.toString(h.forgedRejected()), ",", vm.toString(h.replaysRejected())
                )
            );
        }
        assertGt(h.spokePays(), 0, "no spoke payment");
        assertGt(h.xBatches(), 0, "no completed cross-chain batch");
        assertGt(h.remoteBurns(), 0, "no settlement burn on a spoke");
        assertGt(h.remoteBurnValue(), 0, "no value burned on a spoke");
        assertGt(h.movesOutDone(), 0, "no completed home -> spoke move");
        assertGt(h.movesHomeDone(), 0, "no completed spoke -> home move");
    }
}
