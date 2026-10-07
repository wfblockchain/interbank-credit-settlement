// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";

import { CrossChainMessenger } from "../../../src/crosschain/CrossChainMessenger.sol";
import { HubMessenger } from "../../../src/crosschain/HubMessenger.sol";
import { RemoteObligationToken } from "../../../src/crosschain/RemoteObligationToken.sol";
import { SpokeExposureGuard } from "../../../src/crosschain/SpokeExposureGuard.sol";
import { SpokeMessenger } from "../../../src/crosschain/SpokeMessenger.sol";
import { ICrossChainMessenger } from "../../../src/interfaces/ICrossChainMessenger.sol";
import { IExposureLedger } from "../../../src/interfaces/IExposureLedger.sol";
import { ISettlementBatches } from "../../../src/interfaces/ISettlementBatches.sol";
import { CreditFixture } from "../../credit/utils/CreditFixture.sol";

/// The home chain (domain 1) plus two spokes in one EVM: domain 2 PERMISSIONED, domain 3 PUBLIC.
/// Each chain has its own messenger; messages are collected from MessageSent logs into an outbox
/// and relayed by the test, signed by 5 attesters (strict majority 3) and, for a MINT, by the
/// issuing bank's own key. Every bank uses the same wallet and issuerOps on every chain.
abstract contract CrossChainFixture is CreditFixture {
    uint32 internal constant HOME = 1;
    uint32 internal constant PERM = 2;
    uint32 internal constant PUB = 3;
    uint256 internal constant BIG = 1_000_000_000 * MN;

    HubMessenger internal hub;
    mapping(uint32 => SpokeMessenger) internal spokeM;
    mapping(uint32 => SpokeExposureGuard) internal guardOf;
    mapping(uint32 => mapping(bytes32 => RemoteObligationToken)) internal rtok;
    uint32[2] internal spokeDomains = [PERM, PUB];

    uint256[] internal attKeys; // ascending by address
    address[] internal attAddrs;
    mapping(bytes32 => uint256) internal issuerKeyOf;

    struct Msg {
        uint32 dest;
        uint8 kind;
        bytes data;
    }

    Msg[] internal outbox;
    uint64 internal moveDeadline = 1 days;

    function _deployCrossChain() internal {
        _deployAll();
        _makeAttesters();
        hub = new HubMessenger(
            0, gov, HOME, address(ledger), address(batches), address(registry), guardian, operator, attAddrs, 3
        );
        _deploySpoke(PERM, IExposureLedger.DomainKind.PERMISSIONED);
        _deploySpoke(PUB, IExposureLedger.DomainKind.PUBLIC);

        vm.startPrank(gov);
        ledger.grantRole(ledger.MESSENGER_ROLE(), address(hub));
        ledger.setDomainKind(PERM, IExposureLedger.DomainKind.PERMISSIONED);
        ledger.setDomainKind(PUB, IExposureLedger.DomainKind.PUBLIC);
        batches.setCrossChain(address(hub));
        for (uint256 i = 0; i < banks.length; i++) {
            bytes32 id = banks[i];
            tok[id].grantRole(tok[id].MOVER_ROLE(), address(hub));
            tok[id].grantRole(tok[id].MESSENGER_ROLE(), address(hub));
            hub.setIssuerKey(id, vm.addr(issuerKeyOf[id]));
            for (uint256 k = 0; k < 2; k++) {
                hub.setRateLimit(spokeDomains[k], id, BIG, 0);
            }
        }
        vm.stopPrank();
        // A spoke guard starts OFF_HOURS like the home ledger; the tests run in the business window.
        vm.startPrank(operator);
        for (uint256 k = 0; k < 2; k++) {
            guardOf[spokeDomains[k]].setWindow(IExposureLedger.Window.BUSINESS);
        }
        vm.stopPrank();
        vm.recordLogs();
    }

    function _makeAttesters() internal {
        uint256[] memory keys = new uint256[](5);
        address[] memory addrs = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            keys[i] = uint256(keccak256(abi.encode("xcm-attester", i)));
            addrs[i] = vm.addr(keys[i]);
        }
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
        for (uint256 i = 0; i < 5; i++) {
            attKeys.push(keys[i]);
            attAddrs.push(addrs[i]);
        }
        for (uint256 i = 0; i < banks.length; i++) {
            issuerKeyOf[banks[i]] = uint256(keccak256(abi.encode("issuer-key", banks[i])));
        }
    }

    function _deploySpoke(uint32 d, IExposureLedger.DomainKind kind) internal {
        address pGuard = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        SpokeMessenger m = new SpokeMessenger(0, gov, d, HOME, pGuard, guardian, operator, attAddrs, 3);
        SpokeExposureGuard g = new SpokeExposureGuard(0, gov, d, kind, address(m), guardian, operator);
        assertEq(address(g), pGuard, "guard address prediction");
        spokeM[d] = m;
        guardOf[d] = g;
        string[3] memory names = ["Bank A deposit token", "Bank B deposit token", "Bank C deposit token"];
        string[3] memory symbols = ["A-dT", "B-dT", "C-dT"];
        for (uint256 i = 0; i < banks.length; i++) {
            bytes32 id = banks[i];
            rtok[d][id] = new RemoteObligationToken(0, gov, names[i], symbols[i], id, address(g), issuerAdmin[id], guardian);
        }
        vm.startPrank(gov);
        m.setRemote(HOME, address(hub));
        hub.setRemote(d, address(m));
        for (uint256 i = 0; i < banks.length; i++) {
            bytes32 id = banks[i];
            g.setMember(id, wallet[id], _opsOn(d, id), address(rtok[d][id]));
            g.setSupplyCap(id, BIG);
            m.setIssuerKey(id, vm.addr(issuerKeyOf[id]));
            m.setRateLimit(HOME, id, BIG, 0);
        }
        vm.stopPrank();
    }

    /// A bank's issuerOps on spoke `d`; the same key as at home unless a test overrides it.
    function _opsOn(uint32, bytes32 id) internal view virtual returns (address) {
        return ops[id];
    }

    // ------------------------------------------------------------ messengers and signatures

    function _messenger(uint32 d) internal view returns (CrossChainMessenger) {
        if (d == HOME) {
            return CrossChainMessenger(address(hub));
        }
        return CrossChainMessenger(address(spokeM[d]));
    }

    function _env(bytes memory data) internal pure returns (ICrossChainMessenger.Envelope memory) {
        return abi.decode(data, (ICrossChainMessenger.Envelope));
    }

    /// Signatures from the attesters at the given indices (ascending address order kept).
    function _attSigsOf(uint32 dest, bytes memory data, uint256[] memory which) internal view returns (bytes[] memory s) {
        bytes32 digest = _messenger(dest).messageDigest(data);
        s = new bytes[](which.length);
        for (uint256 i = 0; i < which.length; i++) {
            (uint8 v, bytes32 r, bytes32 ss) = vm.sign(attKeys[which[i]], digest);
            s[i] = abi.encodePacked(r, ss, v);
        }
    }

    function _attSigs(uint32 dest, bytes memory data, uint256 k) internal view returns (bytes[] memory) {
        uint256[] memory w = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            w[i] = i;
        }
        return _attSigsOf(dest, data, w);
    }

    function _signWith(uint256 key, uint32 dest, bytes memory data) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _messenger(dest).messageDigest(data));
        return abi.encodePacked(r, s, v);
    }

    function _issuerSig(uint32 dest, bytes memory data) internal view returns (bytes memory) {
        ICrossChainMessenger.Envelope memory e = _env(data);
        if (e.kind != 0) {
            return "";
        }
        return _signWith(issuerKeyOf[e.member], dest, data);
    }

    // ------------------------------------------------------------ relay

    /// Moves every MessageSent recorded since the last call into the outbox.
    function _collect() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != ICrossChainMessenger.MessageSent.selector) {
                continue;
            }
            bytes memory data = abi.decode(logs[i].data, (bytes));
            outbox.push(Msg({ dest: uint32(uint256(logs[i].topics[1])), kind: uint8(uint256(logs[i].topics[3])), data: data }));
        }
        vm.recordLogs();
    }

    function _removeAt(uint256 i) internal returns (Msg memory m) {
        m = outbox[i];
        for (uint256 k = i; k + 1 < outbox.length; k++) {
            outbox[k] = outbox[k + 1];
        }
        outbox.pop();
    }

    function _deliverData(uint32 dest, bytes memory data) internal {
        vm.recordLogs();
        _messenger(dest).receiveMessage(data, _attSigs(dest, data, 3), _issuerSig(dest, data));
        _collect();
    }

    /// Delivers the outbox in FIFO order, including whatever the deliveries send, until empty.
    function _deliverAll() internal {
        while (outbox.length > 0) {
            Msg memory m = _removeAt(0);
            _deliverData(m.dest, m.data);
        }
    }

    /// Delivers, FIFO, every message for `dest` (and what they cause, for `dest` only).
    function _deliverTo(uint32 dest) internal {
        uint256 i = 0;
        while (i < outbox.length) {
            if (outbox[i].dest == dest) {
                Msg memory m = _removeAt(i);
                _deliverData(m.dest, m.data);
                i = 0;
            } else {
                i++;
            }
        }
    }

    /// Delivers everything except messages to `skip` (and to it only).
    function _deliverAllExcept(uint32 skip) internal {
        uint256 i = 0;
        while (i < outbox.length) {
            if (outbox[i].dest != skip) {
                Msg memory m = _removeAt(i);
                _deliverData(m.dest, m.data);
                i = 0;
            } else {
                i++;
            }
        }
    }

    /// Removes and returns the first outbox message of `kind` to `dest`.
    function _take(uint32 dest, uint8 kind) internal returns (bytes memory) {
        for (uint256 i = 0; i < outbox.length; i++) {
            if (outbox[i].dest == dest && outbox[i].kind == kind) {
                return _removeAt(i).data;
            }
        }
        revert("no such message");
    }

    function _count(uint32 dest, uint8 kind) internal view returns (uint256 n) {
        for (uint256 i = 0; i < outbox.length; i++) {
            if (outbox[i].dest == dest && outbox[i].kind == kind) {
                n++;
            }
        }
    }

    // ------------------------------------------------------------ actions (each collects its messages)

    function _grant(uint32 d, bytes32 i, bytes32 h, uint256 amount) internal {
        vm.recordLogs();
        vm.prank(operator);
        hub.grantEnvelope(d, i, h, amount);
        _collect();
    }

    function _release(uint32 d, bytes32 i, bytes32 h, uint256 amount) internal {
        vm.recordLogs();
        vm.prank(operator);
        spokeM[d].releaseEnvelope(i, h, amount);
        _collect();
    }

    function _spokePay(uint32 d, bytes32 from, bytes32 to, uint256 amount) internal returns (uint256 seq) {
        vm.prank(ops[from]);
        seq = guardOf[d].pay(to, amount, keccak256(abi.encode("spoke-ref", d, from, to, amount)));
    }

    /// Home → spoke: the holder's wallet approves the hub messenger and sends.
    function _moveOut(uint32 d, bytes32 i, bytes32 h, uint256 amount) internal returns (uint64 nonce) {
        vm.prank(wallet[h]);
        tok[i].approve(address(hub), amount);
        vm.recordLogs();
        vm.prank(wallet[h]);
        nonce = hub.sendMint(i, h, amount, d, wallet[h], uint64(block.timestamp) + moveDeadline);
        _collect();
    }

    /// Spoke → home.
    function _moveHome(uint32 d, bytes32 i, bytes32 h, uint256 amount) internal returns (uint64 nonce) {
        vm.recordLogs();
        vm.prank(wallet[h]);
        nonce = spokeM[d].sendMint(i, h, amount, HOME, wallet[h], uint64(block.timestamp) + moveDeadline);
        _collect();
    }

    function _cutX(uint8 trigger) internal returns (uint64 b) {
        vm.recordLogs();
        b = _cut(trigger);
        _collect();
    }

    function _payAllLegs(uint64 b) internal {
        uint256 n = batches.legCount(b);
        for (uint32 k = 0; k < n; k++) {
            ISettlementBatches.Leg memory l = batches.leg(b, k);
            if (l.paid < l.amount) {
                _attestPay(b, k, CHIPS, l.amount - l.paid);
            }
        }
    }

    function _sendBurns(uint64 epoch) internal {
        vm.recordLogs();
        hub.sendBurns(epoch);
        _collect();
    }

    /// Cut, relay the cut and reports, plan, pay every leg, finalize, send and relay the burns.
    function _settleAll(uint8 trigger) internal returns (uint64 b) {
        b = _cutX(trigger);
        _deliverAll();
        _submitPlan(b);
        _payAllLegs(b);
        batches.finalize(b, 100);
        _sendBurns(batches.batch(b).epoch);
        _deliverAll();
    }

    function _sumSupply(bytes32 i) internal view returns (uint256 s) {
        s = tok[i].totalSupply();
        for (uint256 k = 0; k < 2; k++) {
            s += rtok[spokeDomains[k]][i].totalSupply();
        }
    }
}
