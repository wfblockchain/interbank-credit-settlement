// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { CollateralRegister } from "../../../src/credit/CollateralRegister.sol";
import { CreditLimits } from "../../../src/credit/CreditLimits.sol";
import { DefaultManager } from "../../../src/credit/DefaultManager.sol";
import { ExposureLedger } from "../../../src/credit/ExposureLedger.sol";
import { MemberRegistry } from "../../../src/credit/MemberRegistry.sol";
import { ObligationToken } from "../../../src/credit/ObligationToken.sol";
import { SettlementAttestor } from "../../../src/credit/SettlementAttestor.sol";
import { SettlementBatches } from "../../../src/credit/SettlementBatches.sol";
import { ICollateralRegister } from "../../../src/interfaces/ICollateralRegister.sol";
import { IExposureLedger } from "../../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../../src/interfaces/IMemberRegistry.sol";
import { ISettlementAttestor } from "../../../src/interfaces/ISettlementAttestor.sol";
import { ISettlementBatches } from "../../../src/interfaces/ISettlementBatches.sol";

/// Three banks A, B, C on the home chain, five listener signers (k = 3), the admin an EOA with
/// zero delay (the deployment uses a timelock; see DeployHome).
abstract contract CreditFixture is Test {
    bytes32 internal constant A = bytes32("BNKAUS30");
    bytes32 internal constant B = bytes32("BNKBUS30");
    bytes32 internal constant C = bytes32("BNKCUS30");
    bytes32 internal constant COLLATERAL = bytes32("COLLATERAL");
    bytes32 internal constant POOL = bytes32("POOL");
    uint256 internal constant USD = 1e6;
    uint256 internal constant MN = 1_000_000e6;

    uint8 internal constant CHIPS = 1;
    uint8 internal constant RTP = 2;

    address internal gov = makeAddr("gov");
    address internal guardian = makeAddr("guardian");
    address internal operator = makeAddr("operator");
    address internal messenger = makeAddr("messenger");
    address internal stranger = makeAddr("stranger");

    MemberRegistry internal registry;
    CollateralRegister internal register;
    CreditLimits internal limits;
    ExposureLedger internal ledger;
    SettlementAttestor internal attestor;
    SettlementBatches internal batches;
    DefaultManager internal dm;

    bytes32[] internal banks;
    mapping(bytes32 => ObligationToken) internal tok;
    mapping(bytes32 => address) internal wallet;
    mapping(bytes32 => address) internal ops;
    mapping(bytes32 => address) internal issuerAdmin;

    uint256[] internal signerKeys; // sorted by address
    address[] internal signerAddrs;

    uint64 internal fundingNonce;
    uint64 internal asOfClock;
    uint256 internal railCounter;

    function _deployAll() internal {
        _makeSigners();
        uint64 n = vm.getNonce(address(this));
        address pRegistry = vm.computeCreateAddress(address(this), n);
        address pRegister = vm.computeCreateAddress(address(this), n + 1);
        address pLimits = vm.computeCreateAddress(address(this), n + 2);
        address pLedger = vm.computeCreateAddress(address(this), n + 3);
        address pAttestor = vm.computeCreateAddress(address(this), n + 4);
        address pBatches = vm.computeCreateAddress(address(this), n + 5);
        address pDm = vm.computeCreateAddress(address(this), n + 6);

        registry = new MemberRegistry(0, gov, guardian, pDm);
        register = new CollateralRegister(0, gov, pAttestor, pLedger, pDm, pLimits);
        limits = new CreditLimits(0, gov, pRegistry, pRegister, guardian, operator);
        ledger = new ExposureLedger(0, gov, pRegistry, pLimits, pRegister, pBatches, operator);
        attestor = new SettlementAttestor(0, gov, pBatches, pRegister, guardian, signerAddrs, 3);
        batches = new SettlementBatches(0, gov, pRegistry, pLedger, pRegister, pAttestor, pDm, operator);
        dm = new DefaultManager(0, gov, pRegistry, pRegister, pLimits, pBatches);
        assertEq(address(dm), pDm, "address prediction");

        _addBank(A, "Bank A deposit token", "A-dT", IMemberRegistry.Tier.CREDIT);
        _addBank(B, "Bank B deposit token", "B-dT", IMemberRegistry.Tier.CREDIT);
        _addBank(C, "Bank C deposit token", "C-dT", IMemberRegistry.Tier.CREDIT);

        bytes32 messengerRole = ledger.MESSENGER_ROLE();
        vm.prank(gov);
        ledger.grantRole(messengerRole, messenger);
    }

    function _makeSigners() internal {
        uint256[] memory keys = new uint256[](5);
        address[] memory addrs = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            keys[i] = uint256(keccak256(abi.encode("listener-signer", i)));
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
        delete signerKeys;
        delete signerAddrs;
        for (uint256 i = 0; i < 5; i++) {
            signerKeys.push(keys[i]);
            signerAddrs.push(addrs[i]);
        }
    }

    function _newToken(bytes32 id, string memory name, string memory symbol) internal returns (ObligationToken t) {
        string memory label = string(abi.encodePacked(id));
        issuerAdmin[id] = makeAddr(string.concat(label, "-admin"));
        t = new ObligationToken(0, gov, name, symbol, id, address(ledger), address(batches), issuerAdmin[id], guardian);
    }

    function _addBank(bytes32 id, string memory name, string memory symbol, IMemberRegistry.Tier tier) internal {
        string memory label = string(abi.encodePacked(id));
        wallet[id] = makeAddr(string.concat(label, "-wallet"));
        ops[id] = makeAddr(string.concat(label, "-ops"));
        tok[id] = _newToken(id, name, symbol);
        vm.prank(gov);
        registry.admit(id, wallet[id], ops[id], address(tok[id]), tier);
        banks.push(id);
    }

    // ------------------------------------------------------------ standard setup

    /// Collateral $10M each (mandatory = min($5M, 10M / 2) = $5M); every bank grants every other
    /// an elective $95M, so each bilateral limit is $100M; business window open.
    function _standardLimits() internal {
        for (uint256 i = 0; i < banks.length; i++) {
            _fund(ICollateralRegister.Kind.COLLATERAL, banks[i], 10 * MN);
            for (uint256 j = 0; j < banks.length; j++) {
                if (i != j) {
                    _elective(banks[i], banks[j], 95 * MN);
                }
            }
        }
        _window(IExposureLedger.Window.BUSINESS);
    }

    function _window(IExposureLedger.Window w) internal {
        vm.prank(operator);
        ledger.setWindow(w);
    }

    function _elective(bytes32 grantor, bytes32 debtor, uint256 amount) internal {
        vm.prank(ops[grantor]);
        limits.setElective(debtor, amount);
    }

    // ------------------------------------------------------------ signatures

    function _sign(bytes32 digest, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The first k signers in ascending address order.
    function _sigs(bytes32 digest, uint256 k) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](k);
        for (uint256 i = 0; i < k; i++) {
            sigs[i] = _sign(digest, signerKeys[i]);
        }
    }

    function _fund(ICollateralRegister.Kind kind, bytes32 id, uint256 value) internal {
        ISettlementAttestor.Funding memory f = ISettlementAttestor.Funding({
            kind: uint8(kind),
            member: id,
            value: value,
            asOf: ++asOfClock,
            nonce: ++fundingNonce
        });
        attestor.attestFunding(f, _sigs(attestor.fundingDigest(f), 3));
    }

    function _payment(uint64 b, uint32 leg, uint8 rail, bytes32 payer, bytes32 payee, uint256 amount)
        internal
        returns (ISettlementBatches.Payment memory p)
    {
        p = ISettlementBatches.Payment({
            batch: b,
            leg: leg,
            rail: rail,
            railTxId: keccak256(abi.encode("rail-tx", ++railCounter)),
            payerAcct: wallet[payer],
            payer: payer,
            payee: payee,
            amount: amount,
            finalAt: uint64(block.timestamp)
        });
    }

    function _attest(ISettlementBatches.Payment memory p) internal {
        attestor.attestPayment(p, _sigs(attestor.paymentDigest(p), 3));
    }

    function _attestPay(uint64 b, uint32 leg, uint8 rail, uint256 amount) internal {
        ISettlementBatches.Leg memory l = batches.leg(b, leg);
        _attest(_payment(b, leg, rail, l.payer, l.payee, amount));
    }

    // ------------------------------------------------------------ payments and batches

    function _pay(bytes32 from, bytes32 to, uint256 amount) internal returns (uint256 seq) {
        vm.prank(ops[from]);
        seq = ledger.pay(to, amount, keccak256(abi.encode("ref", from, to, amount)));
    }

    function _cut(uint8 trigger) internal returns (uint64 b) {
        vm.prank(operator);
        b = batches.cut(trigger);
    }

    /// Multilateral net per member from the batch's pending pairs, then legs from the largest net
    /// debtor to the largest net creditor until all nets are zero.
    function _plan(uint64 b) internal view returns (ISettlementBatches.Leg[] memory legs) {
        bytes32[] memory ids = registry.memberIds();
        int256[] memory net = new int256[](ids.length);
        (bytes32[] memory is_, bytes32[] memory hs, uint256[] memory amts) = ledger.pendingPairs(batches.batch(b).epoch);
        for (uint256 k = 0; k < is_.length; k++) {
            net[_idx(ids, hs[k])] += int256(amts[k]);
            net[_idx(ids, is_[k])] -= int256(amts[k]);
        }
        ISettlementBatches.Leg[] memory tmp = new ISettlementBatches.Leg[](ids.length * ids.length);
        uint256 count;
        while (true) {
            uint256 d;
            uint256 c;
            int256 minNet;
            int256 maxNet;
            for (uint256 i = 0; i < ids.length; i++) {
                if (net[i] < minNet) {
                    minNet = net[i];
                    d = i;
                }
                if (net[i] > maxNet) {
                    maxNet = net[i];
                    c = i;
                }
            }
            if (minNet == 0) {
                break;
            }
            int256 amt = -minNet < maxNet ? -minNet : maxNet;
            tmp[count++] = ISettlementBatches.Leg({ payer: ids[d], payee: ids[c], amount: uint256(amt), paid: 0 });
            net[d] += amt;
            net[c] -= amt;
        }
        legs = new ISettlementBatches.Leg[](count);
        for (uint256 i = 0; i < count; i++) {
            legs[i] = tmp[i];
        }
    }

    function _submitPlan(uint64 b) internal returns (ISettlementBatches.Leg[] memory legs) {
        legs = _plan(b);
        vm.prank(operator);
        batches.submitPlan(b, legs, uint64(block.timestamp + 1 hours));
    }

    function _idx(bytes32[] memory ids, bytes32 id) internal pure returns (uint256) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == id) {
                return i;
            }
        }
        revert("not a member");
    }

    function _leg(bytes32 payer, bytes32 payee, uint256 amount) internal pure returns (ISettlementBatches.Leg memory) {
        return ISettlementBatches.Leg({ payer: payer, payee: payee, amount: amount, paid: 0 });
    }

    function _exposure(bytes32 i, bytes32 h) internal view returns (uint256) {
        return ledger.open(i, h) + ledger.pending(i, h);
    }
}
