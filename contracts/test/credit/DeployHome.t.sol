// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { DeployHome } from "../../script/DeployHome.s.sol";
import { IMemberRegistry } from "../../src/interfaces/IMemberRegistry.sol";

contract DeployHomeTest is Test {
    DeployHome internal script;
    DeployHome.Config internal c;
    uint256 internal deployerKey = uint256(keccak256("deployer"));
    address internal deployer;

    function setUp() public {
        script = new DeployHome();
        deployer = vm.addr(deployerKey);
        DeployHome.Config memory cfg = script.configFromEnv();
        c = cfg;
        c.timelockDelay = 2 days;
    }

    function test_deploy_timelockAdmin_deployerKeepsNoRole() public {
        DeployHome.Deployment memory d = script.deployAndVerify(c, deployerKey);
        assertEq(d.registry.defaultAdmin(), address(d.timelock));
        assertEq(d.tokens[0].symbol(), "A-dT");
        assertEq(d.tokens[2].issuer(), bytes32("BNKCUS30"));
        assertEq(d.timelock.getMinDelay(), 2 days);
        assertEq(d.attestor.threshold(), 3);
        assertEq(d.attestor.enabledCount(), 5);
    }

    function test_verifyRoles_failsIfDeployerHoldsARole() public {
        DeployHome.Deployment memory d = script.deployAndVerify(c, deployerKey);
        bytes32 role = d.registry.GUARDIAN_ROLE();
        vm.prank(address(d.timelock));
        d.registry.grantRole(role, deployer);
        vm.expectRevert(bytes("deployer holds a role"));
        script.verifyRoles(d, c, deployer);
    }

    /// Governance acts only through the timelock, after its delay.
    function test_governance_admitsThroughTimelock() public {
        DeployHome.Deployment memory d = script.deployAndVerify(c, deployerKey);
        bytes memory call = abi.encodeCall(
            IMemberRegistry.admit,
            (bytes32("BNKAUS30"), makeAddr("a-wallet"), makeAddr("a-ops"), address(d.tokens[0]), IMemberRegistry.Tier.CREDIT)
        );
        vm.prank(c.governance);
        vm.expectRevert();
        d.registry.admit(bytes32("BNKAUS30"), makeAddr("a-wallet"), makeAddr("a-ops"), address(d.tokens[0]), IMemberRegistry.Tier.CREDIT);

        vm.prank(c.governance);
        d.timelock.schedule(address(d.registry), 0, call, bytes32(0), bytes32(0), 2 days);
        vm.prank(c.governance);
        vm.expectRevert();
        d.timelock.execute(address(d.registry), 0, call, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 2 days);
        vm.prank(c.governance);
        d.timelock.execute(address(d.registry), 0, call, bytes32(0), bytes32(0));
        assertTrue(d.registry.goodStanding(bytes32("BNKAUS30")));
    }
}
