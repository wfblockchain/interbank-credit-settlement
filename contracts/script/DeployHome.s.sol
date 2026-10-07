// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Script } from "forge-std/Script.sol";

import { CollateralRegister } from "../src/credit/CollateralRegister.sol";
import { CreditLimits } from "../src/credit/CreditLimits.sol";
import { DefaultManager } from "../src/credit/DefaultManager.sol";
import { ExposureLedger } from "../src/credit/ExposureLedger.sol";
import { MemberRegistry } from "../src/credit/MemberRegistry.sol";
import { ObligationToken } from "../src/credit/ObligationToken.sol";
import { SettlementAttestor } from "../src/credit/SettlementAttestor.sol";
import { SettlementBatches } from "../src/credit/SettlementBatches.sol";

/// Deploys the home-chain contracts with a TimelockController as every contract's default admin.
/// Contract-to-contract roles are granted in the constructors from precomputed addresses, so the
/// deployer never holds a role; verifyRoles checks that and the wiring.
///
/// Members are admitted afterwards by governance through the timelock (MemberRegistry.admit).
///
/// Environment (all optional; defaults are anvil's accounts 0–9):
///   DEPLOYER_KEY, GOVERNANCE, GUARDIAN, OPERATOR, SIGNERS (comma-separated, ascending not needed),
///   THRESHOLD (3), TIMELOCK_DELAY (seconds, 0), ADMIN_DELAY (seconds, 86400),
///   ISSUER_ADMIN_A/B/C (each bank's token admin; default GOVERNANCE)
contract DeployHome is Script {
    struct Config {
        address governance;
        address guardian;
        address operator;
        address[] signers;
        uint256 threshold;
        uint256 timelockDelay;
        uint48 adminDelay;
        address[3] issuerAdmins;
    }

    struct Deployment {
        TimelockController timelock;
        MemberRegistry registry;
        CollateralRegister register;
        CreditLimits limits;
        ExposureLedger ledger;
        SettlementAttestor attestor;
        SettlementBatches batches;
        DefaultManager defaultManager;
        ObligationToken[3] tokens;
    }

    bytes32[3] internal ids = [bytes32("BNKAUS30"), bytes32("BNKBUS30"), bytes32("BNKCUS30")];
    string[3] internal names = ["Bank A deposit token", "Bank B deposit token", "Bank C deposit token"];
    string[3] internal symbols = ["A-dT", "B-dT", "C-dT"];

    // anvil's well-known development key (account 0).
    uint256 internal constant ANVIL_KEY_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external returns (Deployment memory d) {
        uint256 key = vm.envOr("DEPLOYER_KEY", ANVIL_KEY_0);
        Config memory c = configFromEnv();
        d = deployAndVerify(c, key);
        _writeManifest(d);
    }

    function configFromEnv() public view returns (Config memory c) {
        c.governance = vm.envOr("GOVERNANCE", vm.addr(_anvilKey(1)));
        c.guardian = vm.envOr("GUARDIAN", vm.addr(_anvilKey(2)));
        c.operator = vm.envOr("OPERATOR", vm.addr(_anvilKey(3)));
        address[] memory def = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            def[i] = vm.addr(_anvilKey(4 + i));
        }
        c.signers = vm.envOr("SIGNERS", ",", def);
        c.threshold = vm.envOr("THRESHOLD", uint256(3));
        c.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(0));
        c.adminDelay = uint48(vm.envOr("ADMIN_DELAY", uint256(1 days)));
        c.issuerAdmins[0] = vm.envOr("ISSUER_ADMIN_A", c.governance);
        c.issuerAdmins[1] = vm.envOr("ISSUER_ADMIN_B", c.governance);
        c.issuerAdmins[2] = vm.envOr("ISSUER_ADMIN_C", c.governance);
    }

    function deployAndVerify(Config memory c, uint256 key) public returns (Deployment memory d) {
        address deployer = vm.addr(key);
        vm.startBroadcast(key);
        d = _deploy(c, deployer);
        vm.stopBroadcast();
        verifyRoles(d, c, deployer);
    }

    function _deploy(Config memory c, address deployer) internal returns (Deployment memory d) {
        uint64 n = vm.getNonce(deployer);
        address[] memory gov = new address[](1);
        gov[0] = c.governance;
        d.timelock = new TimelockController(c.timelockDelay, gov, gov, address(0));
        address admin = address(d.timelock);

        address pRegistry = vm.computeCreateAddress(deployer, n + 1);
        address pRegister = vm.computeCreateAddress(deployer, n + 2);
        address pLimits = vm.computeCreateAddress(deployer, n + 3);
        address pLedger = vm.computeCreateAddress(deployer, n + 4);
        address pAttestor = vm.computeCreateAddress(deployer, n + 5);
        address pBatches = vm.computeCreateAddress(deployer, n + 6);
        address pDm = vm.computeCreateAddress(deployer, n + 7);

        d.registry = new MemberRegistry(c.adminDelay, admin, c.guardian, pDm);
        d.register = new CollateralRegister(c.adminDelay, admin, pAttestor, pLedger, pDm, pLimits);
        d.limits = new CreditLimits(c.adminDelay, admin, pRegistry, pRegister, c.guardian, c.operator);
        d.ledger = new ExposureLedger(c.adminDelay, admin, pRegistry, pLimits, pRegister, pBatches, c.operator);
        d.attestor = new SettlementAttestor(c.adminDelay, admin, pBatches, pRegister, c.guardian, c.signers, c.threshold);
        d.batches = new SettlementBatches(c.adminDelay, admin, pRegistry, pLedger, pRegister, pAttestor, pDm, c.operator);
        d.defaultManager = new DefaultManager(c.adminDelay, admin, pRegistry, pRegister, pLimits, pBatches);
        require(address(d.defaultManager) == pDm, "address prediction");

        for (uint256 i = 0; i < 3; i++) {
            d.tokens[i] = new ObligationToken(
                c.adminDelay, admin, names[i], symbols[i], ids[i], pLedger, pBatches, c.issuerAdmins[i], c.guardian
            );
        }
    }

    /// Reverts unless the timelock is every contract's default admin, the deployer holds no role
    /// anywhere, and each contract-to-contract role is held by the right contract.
    function verifyRoles(Deployment memory d, Config memory c, address deployer) public view {
        TimelockController t = d.timelock;
        _none(address(t), deployer, t.DEFAULT_ADMIN_ROLE());
        _none(address(t), deployer, t.PROPOSER_ROLE());
        _none(address(t), deployer, t.EXECUTOR_ROLE());
        _none(address(t), deployer, t.CANCELLER_ROLE());
        require(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(t)), "timelock not self-administered");
        require(t.hasRole(t.PROPOSER_ROLE(), c.governance), "governance not proposer");
        require(t.hasRole(t.EXECUTOR_ROLE(), c.governance), "governance not executor");

        bytes32[10] memory roles = [
            bytes32(0),
            keccak256("GUARDIAN_ROLE"),
            keccak256("OPERATOR_ROLE"),
            keccak256("LEDGER_ROLE"),
            keccak256("BATCHES_ROLE"),
            keccak256("ATTESTOR_ROLE"),
            keccak256("MESSENGER_ROLE"),
            keccak256("MOVER_ROLE"),
            keccak256("DEFAULT_MANAGER_ROLE"),
            keccak256("ISSUER_ADMIN_ROLE")
        ];
        address[] memory all = _all(d);
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 r = 0; r < roles.length; r++) {
                _none(all[i], deployer, roles[r]);
            }
            require(_defaultAdmin(all[i]) == address(t), "default admin is not the timelock");
        }

        _has(address(d.registry), address(d.defaultManager), d.registry.DEFAULT_MANAGER_ROLE());
        _has(address(d.registry), c.guardian, d.registry.GUARDIAN_ROLE());
        _has(address(d.register), address(d.attestor), d.register.ATTESTOR_ROLE());
        _has(address(d.register), address(d.ledger), d.register.LEDGER_ROLE());
        _has(address(d.register), address(d.defaultManager), d.register.DEFAULT_MANAGER_ROLE());
        _has(address(d.limits), c.guardian, d.limits.GUARDIAN_ROLE());
        _has(address(d.limits), c.operator, d.limits.OPERATOR_ROLE());
        _has(address(d.ledger), address(d.batches), d.ledger.BATCHES_ROLE());
        _has(address(d.ledger), c.operator, d.ledger.OPERATOR_ROLE());
        _has(address(d.attestor), c.guardian, d.attestor.GUARDIAN_ROLE());
        _has(address(d.batches), address(d.attestor), d.batches.ATTESTOR_ROLE());
        _has(address(d.batches), address(d.defaultManager), d.batches.DEFAULT_MANAGER_ROLE());
        _has(address(d.batches), c.operator, d.batches.OPERATOR_ROLE());
        for (uint256 i = 0; i < 3; i++) {
            ObligationToken tok = d.tokens[i];
            _has(address(tok), address(d.ledger), tok.LEDGER_ROLE());
            _has(address(tok), address(d.batches), tok.BATCHES_ROLE());
            _has(address(tok), c.guardian, tok.GUARDIAN_ROLE());
            _has(address(tok), c.issuerAdmins[i], tok.ISSUER_ADMIN_ROLE());
        }
        require(address(d.batches.ledger()) == address(d.ledger), "batches.ledger");
        require(address(d.ledger.registry()) == address(d.registry), "ledger.registry");
        require(address(d.attestor.batches()) == address(d.batches), "attestor.batches");
        require(d.attestor.threshold() == c.threshold, "threshold");
    }

    function _all(Deployment memory d) internal pure returns (address[] memory a) {
        a = new address[](10);
        a[0] = address(d.registry);
        a[1] = address(d.register);
        a[2] = address(d.limits);
        a[3] = address(d.ledger);
        a[4] = address(d.attestor);
        a[5] = address(d.batches);
        a[6] = address(d.defaultManager);
        a[7] = address(d.tokens[0]);
        a[8] = address(d.tokens[1]);
        a[9] = address(d.tokens[2]);
    }

    function _none(address target, address account, bytes32 role) internal view {
        require(!IAccessControl(target).hasRole(role, account), "deployer holds a role");
    }

    function _has(address target, address account, bytes32 role) internal view {
        require(IAccessControl(target).hasRole(role, account), "missing role");
    }

    function _defaultAdmin(address target) internal view returns (address) {
        return MemberRegistry(target).defaultAdmin();
    }

    function _anvilKey(uint256 i) internal pure returns (uint256) {
        uint256[10] memory k = [
            0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80,
            0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d,
            0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a,
            0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6,
            0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a,
            0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba,
            0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e,
            0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356,
            0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97,
            0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6
        ];
        return k[i];
    }

    function _writeManifest(Deployment memory d) internal {
        string memory o = "home";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "timelock", address(d.timelock));
        vm.serializeAddress(o, "MemberRegistry", address(d.registry));
        vm.serializeAddress(o, "CollateralRegister", address(d.register));
        vm.serializeAddress(o, "CreditLimits", address(d.limits));
        vm.serializeAddress(o, "ExposureLedger", address(d.ledger));
        vm.serializeAddress(o, "SettlementAttestor", address(d.attestor));
        vm.serializeAddress(o, "SettlementBatches", address(d.batches));
        vm.serializeAddress(o, "DefaultManager", address(d.defaultManager));
        vm.serializeAddress(o, "A-dT", address(d.tokens[0]));
        vm.serializeAddress(o, "B-dT", address(d.tokens[1]));
        string memory json = vm.serializeAddress(o, "C-dT", address(d.tokens[2]));
        vm.createDir("./deployments", true);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), "-home.json"));
    }
}
