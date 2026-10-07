// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Script } from "forge-std/Script.sol";

import { HubMessenger } from "../src/crosschain/HubMessenger.sol";
import { RemoteObligationToken } from "../src/crosschain/RemoteObligationToken.sol";
import { SpokeExposureGuard } from "../src/crosschain/SpokeExposureGuard.sol";
import { SpokeMessenger } from "../src/crosschain/SpokeMessenger.sol";
import { ICrossChainMessenger } from "../src/interfaces/ICrossChainMessenger.sol";
import { IExposureLedger } from "../src/interfaces/IExposureLedger.sol";
import { ISettlementBatches } from "../src/interfaces/ISettlementBatches.sol";
import { ISpokeExposureGuard } from "../src/interfaces/ISpokeExposureGuard.sol";

/// Deploys the cross-chain contracts (design §4).
///
/// On the home chain (DOMAIN == HOME_DOMAIN): the HubMessenger, administered by the home
/// deployment's timelock. On a spoke: a TimelockController, the SpokeMessenger, the
/// SpokeExposureGuard and one RemoteObligationToken per bank, every contract administered by that
/// timelock. The deployer never holds a role; verify* checks that and the wiring.
///
/// Configuration that needs the admin (roles on the home contracts, remotes, members, issuer keys,
/// supply caps, rate limits) is returned as timelock batches (`hubWiring`, `spokeWiring`) for
/// governance to schedule and execute after the delay.
///
/// Environment: DOMAIN, HOME_DOMAIN (1), KIND (1 PERMISSIONED, 2 PUBLIC), DEPLOYER_KEY,
/// GOVERNANCE, GUARDIAN, OPERATOR, ATTESTERS (comma-separated), THRESHOLD (3), TIMELOCK_DELAY,
/// ADMIN_DELAY, ISSUER_ADMIN_A/B/C; on the home chain also HOME_TIMELOCK, LEDGER, BATCHES, REGISTRY.
contract DeployRemote is Script {
    struct Config {
        uint32 domain;
        uint32 homeDomain;
        IExposureLedger.DomainKind kind;
        address governance;
        address guardian;
        address operator;
        address[] attesters;
        uint8 threshold;
        uint256 timelockDelay;
        uint48 adminDelay;
        address[3] issuerAdmins;
    }

    struct HomeRefs {
        address timelock;
        address ledger;
        address batches;
        address registry;
    }

    struct Spoke {
        TimelockController timelock;
        SpokeMessenger messenger;
        SpokeExposureGuard guard;
        RemoteObligationToken[3] tokens;
    }

    /// What a spoke needs to know about each bank there.
    struct SpokeMember {
        bytes32 id;
        address wallet;
        address issuerOps;
        address issuerKey;
        uint256 supplyCap;
        uint256 rateCapacity;
    }

    /// A timelock batch.
    struct Calls {
        address[] targets;
        bytes[] payloads;
    }

    bytes32[3] internal ids = [bytes32("BNKAUS30"), bytes32("BNKBUS30"), bytes32("BNKCUS30")];
    string[3] internal names = ["Bank A deposit token", "Bank B deposit token", "Bank C deposit token"];
    string[3] internal symbols = ["A-dT", "B-dT", "C-dT"];

    uint256 internal constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        uint256 key = vm.envOr("DEPLOYER_KEY", ANVIL_KEY_0);
        Config memory c = configFromEnv();
        if (c.domain == c.homeDomain) {
            HomeRefs memory h = HomeRefs({
                timelock: vm.envAddress("HOME_TIMELOCK"),
                ledger: vm.envAddress("LEDGER"),
                batches: vm.envAddress("BATCHES"),
                registry: vm.envAddress("REGISTRY")
            });
            HubMessenger hub = deployHub(c, h, key);
            string memory o = "hub";
            vm.serializeUint(o, "chainId", block.chainid);
            vm.serializeUint(o, "domain", c.domain);
            string memory json = vm.serializeAddress(o, "HubMessenger", address(hub));
            _write(json, "hub");
        } else {
            Spoke memory s = deploySpoke(c, key);
            string memory o = "spoke";
            vm.serializeUint(o, "chainId", block.chainid);
            vm.serializeUint(o, "domain", c.domain);
            vm.serializeAddress(o, "timelock", address(s.timelock));
            vm.serializeAddress(o, "SpokeMessenger", address(s.messenger));
            vm.serializeAddress(o, "SpokeExposureGuard", address(s.guard));
            vm.serializeAddress(o, "A-dT", address(s.tokens[0]));
            vm.serializeAddress(o, "B-dT", address(s.tokens[1]));
            string memory json = vm.serializeAddress(o, "C-dT", address(s.tokens[2]));
            _write(json, string.concat("spoke-", vm.toString(uint256(c.domain))));
        }
    }

    function configFromEnv() public view returns (Config memory c) {
        c.domain = uint32(vm.envOr("DOMAIN", uint256(2)));
        c.homeDomain = uint32(vm.envOr("HOME_DOMAIN", uint256(1)));
        c.kind = IExposureLedger.DomainKind(uint8(vm.envOr("KIND", uint256(1))));
        c.governance = vm.envOr("GOVERNANCE", vm.addr(_anvilKey(1)));
        c.guardian = vm.envOr("GUARDIAN", vm.addr(_anvilKey(2)));
        c.operator = vm.envOr("OPERATOR", vm.addr(_anvilKey(3)));
        address[] memory def = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            def[i] = vm.addr(uint256(keccak256(abi.encode("dev-attester", i))));
        }
        c.attesters = vm.envOr("ATTESTERS", ",", def);
        c.threshold = uint8(vm.envOr("THRESHOLD", uint256(3)));
        c.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(0));
        c.adminDelay = uint48(vm.envOr("ADMIN_DELAY", uint256(1 days)));
        c.issuerAdmins[0] = vm.envOr("ISSUER_ADMIN_A", c.governance);
        c.issuerAdmins[1] = vm.envOr("ISSUER_ADMIN_B", c.governance);
        c.issuerAdmins[2] = vm.envOr("ISSUER_ADMIN_C", c.governance);
    }

    // ------------------------------------------------------------ hub

    function deployHub(Config memory c, HomeRefs memory h, uint256 key) public returns (HubMessenger hub) {
        vm.startBroadcast(key);
        hub = new HubMessenger(
            c.adminDelay, h.timelock, c.homeDomain, h.ledger, h.batches, h.registry, c.guardian, c.operator,
            c.attesters, c.threshold
        );
        vm.stopBroadcast();
        verifyHub(hub, c, h, vm.addr(key));
    }

    function verifyHub(HubMessenger hub, Config memory c, HomeRefs memory h, address deployer) public view {
        _noDeployerRoles(address(hub), deployer);
        require(hub.defaultAdmin() == h.timelock, "hub admin is not the home timelock");
        require(hub.LOCAL_DOMAIN() == c.homeDomain && hub.HOME_DOMAIN() == c.homeDomain, "hub domains");
        require(address(hub.ledger()) == h.ledger, "hub.ledger");
        require(address(hub.batches()) == h.batches, "hub.batches");
        require(address(hub.registry()) == h.registry, "hub.registry");
        require(hub.threshold() == c.threshold && hub.attesterCount() == c.attesters.length, "hub attesters");
        _has(address(hub), c.guardian, hub.GUARDIAN_ROLE());
        _has(address(hub), c.operator, hub.OPERATOR_ROLE());
    }

    /// The home timelock batch that connects the hub: ledger and token roles, domain kinds, the
    /// batches hook, and per spoke its remote, the issuer keys and the inbound rate limits.
    function hubWiring(
        HubMessenger hub,
        HomeRefs memory h,
        address[3] memory homeTokens,
        uint32[] memory spokeDomains,
        IExposureLedger.DomainKind[] memory kinds,
        address[] memory spokeMessengers,
        SpokeMember[3] memory members
    ) public pure returns (Calls memory w) {
        uint256 n = 2 + 2 * 3 + 3 + spokeDomains.length * (2 + 3);
        w.targets = new address[](n);
        w.payloads = new bytes[](n);
        uint256 k;
        (w.targets[k], w.payloads[k++]) =
            (h.ledger, abi.encodeCall(IAccessControl.grantRole, (keccak256("MESSENGER_ROLE"), address(hub))));
        (w.targets[k], w.payloads[k++]) = (h.batches, abi.encodeCall(ISettlementBatches.setCrossChain, (address(hub))));
        for (uint256 i = 0; i < 3; i++) {
            (w.targets[k], w.payloads[k++]) =
                (homeTokens[i], abi.encodeCall(IAccessControl.grantRole, (keccak256("MOVER_ROLE"), address(hub))));
            (w.targets[k], w.payloads[k++]) =
                (homeTokens[i], abi.encodeCall(IAccessControl.grantRole, (keccak256("MESSENGER_ROLE"), address(hub))));
            (w.targets[k], w.payloads[k++]) =
                (address(hub), abi.encodeCall(ICrossChainMessenger.setIssuerKey, (members[i].id, members[i].issuerKey)));
        }
        for (uint256 d = 0; d < spokeDomains.length; d++) {
            (w.targets[k], w.payloads[k++]) =
                (h.ledger, abi.encodeCall(IExposureLedger.setDomainKind, (spokeDomains[d], kinds[d])));
            (w.targets[k], w.payloads[k++]) = (
                address(hub), abi.encodeCall(ICrossChainMessenger.setRemote, (spokeDomains[d], spokeMessengers[d]))
            );
            for (uint256 i = 0; i < 3; i++) {
                (w.targets[k], w.payloads[k++]) = (
                    address(hub),
                    abi.encodeCall(
                        ICrossChainMessenger.setRateLimit, (spokeDomains[d], members[i].id, members[i].rateCapacity, 0)
                    )
                );
            }
        }
        require(k == n, "wiring size");
    }

    // ------------------------------------------------------------ spoke

    function deploySpoke(Config memory c, uint256 key) public returns (Spoke memory s) {
        address deployer = vm.addr(key);
        vm.startBroadcast(key);
        uint64 n = vm.getNonce(deployer);
        address[] memory gov = new address[](1);
        gov[0] = c.governance;
        s.timelock = new TimelockController(c.timelockDelay, gov, gov, address(0));
        address admin = address(s.timelock);
        address pGuard = vm.computeCreateAddress(deployer, n + 2);
        s.messenger =
            new SpokeMessenger(c.adminDelay, admin, c.domain, c.homeDomain, pGuard, c.guardian, c.operator, c.attesters, c.threshold);
        s.guard = new SpokeExposureGuard(c.adminDelay, admin, c.domain, c.kind, address(s.messenger), c.guardian, c.operator);
        require(address(s.guard) == pGuard, "address prediction");
        for (uint256 i = 0; i < 3; i++) {
            s.tokens[i] = new RemoteObligationToken(
                c.adminDelay, admin, names[i], symbols[i], ids[i], address(s.guard), c.issuerAdmins[i], c.guardian
            );
        }
        vm.stopBroadcast();
        verifySpoke(s, c, deployer);
    }

    function verifySpoke(Spoke memory s, Config memory c, address deployer) public view {
        TimelockController t = s.timelock;
        require(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(t)), "timelock not self-administered");
        require(!t.hasRole(t.DEFAULT_ADMIN_ROLE(), deployer), "deployer holds a role");
        require(t.hasRole(t.PROPOSER_ROLE(), c.governance), "governance not proposer");
        address[] memory all = new address[](5);
        all[0] = address(s.messenger);
        all[1] = address(s.guard);
        for (uint256 i = 0; i < 3; i++) {
            all[2 + i] = address(s.tokens[i]);
        }
        for (uint256 i = 0; i < all.length; i++) {
            _noDeployerRoles(all[i], deployer);
            require(SpokeMessenger(all[i]).defaultAdmin() == address(t), "default admin is not the timelock");
        }
        require(s.messenger.LOCAL_DOMAIN() == c.domain && s.messenger.HOME_DOMAIN() == c.homeDomain, "domains");
        require(address(s.messenger.guard()) == address(s.guard), "messenger.guard");
        require(s.guard.DOMAIN() == c.domain && s.guard.KIND() == c.kind, "guard domain");
        require(s.messenger.threshold() == c.threshold, "threshold");
        _has(address(s.guard), address(s.messenger), s.guard.MESSENGER_ROLE());
        _has(address(s.guard), c.guardian, s.guard.GUARDIAN_ROLE());
        _has(address(s.guard), c.operator, s.guard.OPERATOR_ROLE());
        _has(address(s.messenger), c.guardian, s.messenger.GUARDIAN_ROLE());
        _has(address(s.messenger), c.operator, s.messenger.OPERATOR_ROLE());
        for (uint256 i = 0; i < 3; i++) {
            RemoteObligationToken tok = s.tokens[i];
            require(tok.issuer() == ids[i], "token issuer");
            _has(address(tok), address(s.guard), tok.LEDGER_ROLE());
            _has(address(tok), address(s.guard), tok.MESSENGER_ROLE());
            _has(address(tok), c.guardian, tok.GUARDIAN_ROLE());
            _has(address(tok), c.issuerAdmins[i], tok.ISSUER_ADMIN_ROLE());
        }
    }

    /// The spoke timelock batch: the hub as its only remote, and per bank its member record,
    /// issuer key, supply cap and inbound rate limit.
    function spokeWiring(Spoke memory s, uint32 homeDomain, address hub, SpokeMember[3] memory members)
        public
        pure
        returns (Calls memory w)
    {
        uint256 n = 1 + 4 * 3;
        w.targets = new address[](n);
        w.payloads = new bytes[](n);
        uint256 k;
        (w.targets[k], w.payloads[k++]) =
            (address(s.messenger), abi.encodeCall(ICrossChainMessenger.setRemote, (homeDomain, hub)));
        for (uint256 i = 0; i < 3; i++) {
            SpokeMember memory m = members[i];
            (w.targets[k], w.payloads[k++]) = (
                address(s.guard),
                abi.encodeCall(ISpokeExposureGuard.setMember, (m.id, m.wallet, m.issuerOps, address(s.tokens[i])))
            );
            (w.targets[k], w.payloads[k++]) =
                (address(s.guard), abi.encodeCall(ISpokeExposureGuard.setSupplyCap, (m.id, m.supplyCap)));
            (w.targets[k], w.payloads[k++]) =
                (address(s.messenger), abi.encodeCall(ICrossChainMessenger.setIssuerKey, (m.id, m.issuerKey)));
            (w.targets[k], w.payloads[k++]) = (
                address(s.messenger),
                abi.encodeCall(ICrossChainMessenger.setRateLimit, (homeDomain, m.id, m.rateCapacity, 0))
            );
        }
    }

    // ------------------------------------------------------------ internals

    function _noDeployerRoles(address target, address deployer) internal view {
        bytes32[6] memory roles = [
            bytes32(0),
            keccak256("GUARDIAN_ROLE"),
            keccak256("OPERATOR_ROLE"),
            keccak256("LEDGER_ROLE"),
            keccak256("MESSENGER_ROLE"),
            keccak256("ISSUER_ADMIN_ROLE")
        ];
        for (uint256 r = 0; r < roles.length; r++) {
            require(!IAccessControl(target).hasRole(roles[r], deployer), "deployer holds a role");
        }
    }

    function _has(address target, address account, bytes32 role) internal view {
        require(IAccessControl(target).hasRole(role, account), "missing role");
    }

    function _write(string memory json, string memory name) internal {
        vm.createDir("./deployments", true);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), "-", name, ".json"));
    }

    function _anvilKey(uint256 i) internal pure returns (uint256) {
        uint256[4] memory k = [
            0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80,
            0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d,
            0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a,
            0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
        ];
        return k[i];
    }
}
