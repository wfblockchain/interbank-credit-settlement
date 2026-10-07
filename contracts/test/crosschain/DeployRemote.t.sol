// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { DeployHome } from "../../script/DeployHome.s.sol";
import { DeployRemote } from "../../script/DeployRemote.s.sol";
import { HubMessenger } from "../../src/crosschain/HubMessenger.sol";
import { ICrossChainMessenger } from "../../src/interfaces/ICrossChainMessenger.sol";
import { IExposureLedger } from "../../src/interfaces/IExposureLedger.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";

contract DeployRemoteTest is Test {
    DeployHome internal home;
    DeployRemote internal remote;
    uint256 internal deployerKey = uint256(keccak256("deployer"));
    address internal deployer;

    DeployHome.Deployment internal hd;
    DeployHome.Config internal hc;
    DeployRemote.Config internal rc;

    function setUp() public {
        home = new DeployHome();
        remote = new DeployRemote();
        deployer = vm.addr(deployerKey);
        hc = home.configFromEnv();
        hc.timelockDelay = 2 days;
        hd = home.deployAndVerify(hc, deployerKey);
        rc = remote.configFromEnv();
        rc.timelockDelay = 2 days;
    }

    function _refs() internal view returns (DeployRemote.HomeRefs memory) {
        return DeployRemote.HomeRefs({
            timelock: address(hd.timelock),
            ledger: address(hd.ledger),
            batches: address(hd.batches),
            registry: address(hd.registry)
        });
    }

    function _members() internal pure returns (DeployRemote.SpokeMember[3] memory m) {
        bytes32[3] memory ids = [bytes32("BNKAUS30"), bytes32("BNKBUS30"), bytes32("BNKCUS30")];
        for (uint256 i = 0; i < 3; i++) {
            m[i] = DeployRemote.SpokeMember({
                id: ids[i],
                wallet: vm.addr(uint256(keccak256(abi.encode("wallet", i)))),
                issuerOps: vm.addr(uint256(keccak256(abi.encode("ops", i)))),
                issuerKey: vm.addr(uint256(keccak256(abi.encode("issuer-key", i)))),
                supplyCap: 50_000_000e6,
                rateCapacity: 10_000_000e6
            });
        }
    }

    function _execute(TimelockController t, address gov, DeployRemote.Calls memory w) internal {
        uint256[] memory values = new uint256[](w.targets.length);
        vm.prank(gov);
        t.scheduleBatch(w.targets, values, w.payloads, bytes32(0), bytes32(0), 2 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(gov);
        t.executeBatch(w.targets, values, w.payloads, bytes32(0), bytes32(0));
    }

    function test_deploy_hubAndSpoke_wiredThroughTimelocks_suspendRelays() public {
        DeployRemote.Config memory hubCfg = rc;
        hubCfg.domain = 1;
        HubMessenger hub = remote.deployHub(hubCfg, _refs(), deployerKey);
        DeployRemote.Spoke memory s = remote.deploySpoke(rc, deployerKey);
        assertEq(s.messenger.defaultAdmin(), address(s.timelock));
        assertEq(s.timelock.getMinDelay(), 2 days);
        assertEq(uint8(s.guard.KIND()), uint8(IExposureLedger.DomainKind.PERMISSIONED));

        DeployRemote.SpokeMember[3] memory m = _members();
        // Admit the banks at home (registry wallets match the spoke's).
        for (uint256 i = 0; i < 3; i++) {
            bytes memory call = abi.encodeCall(
                IMemberRegistry.admit, (m[i].id, m[i].wallet, m[i].issuerOps, address(hd.tokens[i]), IMemberRegistry.Tier.CREDIT)
            );
            vm.prank(hc.governance);
            hd.timelock.schedule(address(hd.registry), 0, call, bytes32(0), bytes32(uint256(i)), 2 days);
        }
        vm.warp(block.timestamp + 2 days);
        for (uint256 i = 0; i < 3; i++) {
            bytes memory call = abi.encodeCall(
                IMemberRegistry.admit, (m[i].id, m[i].wallet, m[i].issuerOps, address(hd.tokens[i]), IMemberRegistry.Tier.CREDIT)
            );
            vm.prank(hc.governance);
            hd.timelock.execute(address(hd.registry), 0, call, bytes32(0), bytes32(uint256(i)));
        }

        uint32[] memory domains = new uint32[](1);
        domains[0] = rc.domain;
        IExposureLedger.DomainKind[] memory kinds = new IExposureLedger.DomainKind[](1);
        kinds[0] = IExposureLedger.DomainKind.PERMISSIONED;
        address[] memory messengers = new address[](1);
        messengers[0] = address(s.messenger);
        address[3] memory homeTokens = [address(hd.tokens[0]), address(hd.tokens[1]), address(hd.tokens[2])];
        _execute(hd.timelock, hc.governance, remote.hubWiring(hub, _refs(), homeTokens, domains, kinds, messengers, m));
        _execute(s.timelock, rc.governance, remote.spokeWiring(s, 1, address(hub), m));

        assertTrue(hd.ledger.hasRole(hd.ledger.MESSENGER_ROLE(), address(hub)));
        assertEq(address(hd.batches.crossChain()), address(hub));
        assertTrue(hd.tokens[0].hasRole(hd.tokens[0].MOVER_ROLE(), address(hub)));
        assertTrue(hub.isSpoke(rc.domain));
        assertEq(hub.remote(rc.domain), address(s.messenger));
        assertEq(s.messenger.remote(1), address(hub));
        assertEq(s.guard.member(m[0].id).token, address(s.tokens[0]));
        assertEq(s.messenger.issuerKey(m[1].id), m[1].issuerKey);
        assertEq(hub.rateAvailable(rc.domain, m[2].id), 10_000_000e6);

        // One attested message end to end: the guardian's SUSPEND reaches the spoke.
        vm.recordLogs();
        vm.prank(rc.guardian);
        hub.sendSuspend(m[0].id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory data;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ICrossChainMessenger.MessageSent.selector) {
                data = abi.decode(logs[i].data, (bytes));
            }
        }
        bytes32 digest = s.messenger.messageDigest(data);
        uint256[] memory keys = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            keys[i] = uint256(keccak256(abi.encode("dev-attester", i)));
        }
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) {
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            (uint8 v, bytes32 r, bytes32 ss) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, ss, v);
        }
        s.messenger.receiveMessage(data, sigs, "");
        assertTrue(s.guard.member(m[0].id).suspended);
        assertTrue(s.tokens[0].paused());
    }

    function test_verifySpoke_failsIfDeployerHoldsARole() public {
        DeployRemote.Spoke memory s = remote.deploySpoke(rc, deployerKey);
        bytes32 role = s.guard.GUARDIAN_ROLE();
        vm.prank(address(s.timelock));
        s.guard.grantRole(role, deployer);
        vm.expectRevert(bytes("deployer holds a role"));
        remote.verifySpoke(s, rc, deployer);
    }
}
