// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {CipherVault} from "../src/CipherVault.sol";

contract Reenterer {
    CipherVault public vault;

    function set(CipherVault v) external {
        vault = v;
    }

    receive() external payable {
        if (address(vault) != address(0) && address(vault).balance > 0) vault.distribute();
    }
}

contract CipherVaultTest is Test {
    CipherVault vault;
    address guardian = makeAddr("cph-guardian");
    address buyback = makeAddr("cph-buyback");
    address compute = makeAddr("cph-compute");
    address nodes = makeAddr("cph-nodes");
    address rnd = makeAddr("cph-rnd");
    address ballot = makeAddr("cph-ballot");
    address hunter = makeAddr("cph-hunter");

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new CipherVault(guardian, buyback, compute, nodes, rnd);
        vm.prank(guardian);
        vault.bindFirstBallot(ballot);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_defaultRouteBurn_split50_30_20() public {
        _fund(1 ether);
        vault.distribute();
        assertEq(buyback.balance, 0.5 ether, "sealed pot to buyback");
        assertEq(rnd.balance, 0.3 ether, "R&D");
        assertEq(vault.bountyPool(), 0.2 ether, "bounty pool kept");
        assertEq(address(vault).balance, 0.2 ether);
        assertEq(vault.pending(), 0);
        assertEq(vault.totalDistributed(), 1 ether);
    }

    function test_ballotRoutesSealedPot() public {
        vm.prank(ballot);
        assertTrue(vault.applyRoute(1, 1, keccak256("tally")));
        _fund(2 ether);
        vault.distribute();
        assertEq(compute.balance, 1 ether);
        vm.prank(ballot);
        vault.applyRoute(2, 2, bytes32(0));
        _fund(2 ether);
        vault.distribute();
        assertEq(nodes.balance, 1 ether);
    }

    function test_routeSwitchSettlesOldFeesFirst() public {
        _fund(1 ether); // earned under BURN
        vm.prank(ballot);
        vault.applyRoute(1, 1, bytes32(0));
        assertEq(buyback.balance, 0.5 ether, "old fees followed the old route");
        assertEq(compute.balance, 0);
        assertEq(vault.route(), 1);
    }

    function test_onlyBallotAppliesAndStaleEpochIgnored() public {
        vm.expectRevert(CipherVault.NotBallot.selector);
        vault.applyRoute(1, 1, bytes32(0));
        vm.startPrank(ballot);
        vm.expectRevert(CipherVault.BadRoute.selector);
        vault.applyRoute(1, 3, bytes32(0));
        assertTrue(vault.applyRoute(5, 2, bytes32(0)));
        assertFalse(vault.applyRoute(5, 1, bytes32(0)), "same epoch ignored");
        assertFalse(vault.applyRoute(4, 1, bytes32(0)), "older epoch ignored");
        vm.stopPrank();
        assertEq(vault.route(), 2);
    }

    function test_safeModeFreezesBurnAndIgnoresBallot() public {
        vm.prank(ballot);
        vault.applyRoute(1, 2, bytes32(0));
        _fund(1 ether);
        vm.prank(guardian);
        vault.setPaused(true);
        assertEq(nodes.balance, 0.5 ether, "pending settled under the old route");
        assertEq(vault.route(), 0, "back to BURN");
        vm.prank(ballot);
        assertFalse(vault.applyRoute(2, 1, bytes32(0)));
        assertEq(vault.route(), 0);
        vm.prank(guardian);
        vault.setPaused(false);
        vm.prank(ballot);
        assertTrue(vault.applyRoute(3, 1, bytes32(0)));
    }

    function test_bountiesFromPoolOnly() public {
        _fund(1 ether);
        vault.distribute(); // 0.2 ETH bounty pool
        vm.expectRevert(CipherVault.NotGuardian.selector);
        vault.payBounty(hunter, 0.1 ether, bytes32(0));
        vm.startPrank(guardian);
        vm.expectRevert(CipherVault.BountyTooLarge.selector);
        vault.payBounty(hunter, 0.21 ether, bytes32(0));
        vault.payBounty(hunter, 0.15 ether, keccak256("report"));
        vm.stopPrank();
        assertEq(hunter.balance, 0.15 ether);
        assertEq(vault.bountyPool(), 0.05 ether);
        assertEq(vault.pending(), 0, "paying bounties never creates new pending fees");
    }

    function test_recipientsTimelock() public {
        address newBuyback = makeAddr("cph-new-buyback");
        CipherVault.Recipients memory next = CipherVault.Recipients(newBuyback, compute, nodes, rnd);
        vm.startPrank(guardian);
        vault.proposeRecipients(next);
        vm.expectRevert(CipherVault.TooEarly.selector);
        vault.executeRecipients();
        vm.stopPrank();
        _fund(1 ether); // earned before the change
        vm.warp(block.timestamp + 48 hours);
        vm.prank(guardian);
        vault.executeRecipients();
        assertEq(buyback.balance, 0.5 ether, "fees earned before the change went to the old recipient");
        (address b,,,) = vault.recipients();
        assertEq(b, newBuyback);
    }

    function test_ballotChangeIsTimelocked() public {
        vm.prank(guardian);
        vm.expectRevert(CipherVault.TooEarly.selector);
        vault.bindFirstBallot(makeAddr("other"));
        address next = makeAddr("phase2-ballot");
        vm.startPrank(guardian);
        vault.proposeBallot(next);
        vm.expectRevert(CipherVault.TooEarly.selector);
        vault.executeBallot();
        vm.warp(block.timestamp + 48 hours);
        vault.executeBallot();
        vm.stopPrank();
        assertEq(vault.ballot(), next);
    }

    function test_guardianHandoverAndRenounce() public {
        address dao = makeAddr("dao");
        vm.startPrank(guardian);
        vault.proposeGuardian(dao);
        vault.cancelProposal(2);
        vm.expectRevert(CipherVault.NothingPending.selector);
        vault.executeGuardian();
        vault.proposeGuardian(dao);
        vm.warp(block.timestamp + 48 hours);
        vault.executeGuardian();
        vm.stopPrank();
        assertEq(vault.guardian(), dao);
        vm.startPrank(dao);
        vault.proposeGuardian(address(0));
        vm.warp(block.timestamp + 48 hours);
        vault.executeGuardian();
        vm.stopPrank();
        assertEq(vault.guardian(), address(0));
    }

    function test_reentrantRecipientCannotDoubleDistribute() public {
        Reenterer r = new Reenterer();
        CipherVault v = new CipherVault(guardian, address(r), compute, nodes, rnd);
        r.set(v);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(CipherVault.TransferFailed.selector);
        v.distribute();
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(CipherVault.ZeroAddress.selector);
        new CipherVault(address(0), buyback, compute, nodes, rnd);
        vm.expectRevert(CipherVault.ZeroAddress.selector);
        new CipherVault(guardian, buyback, address(0), nodes, rnd);
    }

    function testFuzz_splitAlwaysAddsUp(uint96 amount) public {
        vm.assume(amount > 0);
        _fund(amount);
        vault.distribute();
        assertEq(buyback.balance + rnd.balance + vault.bountyPool(), amount);
        assertEq(address(vault).balance, vault.bountyPool());
    }
}
