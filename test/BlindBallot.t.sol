// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {CipherVault} from "../src/CipherVault.sol";
import {CipherStake} from "../src/CipherStake.sol";
import {BlindBallot} from "../src/BlindBallot.sol";

contract MockCPH is ERC20("CIPHRA", "CPH", 18) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CipherStakeTest is Test {
    MockCPH cph;
    CipherStake stakeC;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        cph = new MockCPH();
        stakeC = new CipherStake(address(cph));
        cph.mint(alice, 1_000e18);
        vm.prank(alice);
        cph.approve(address(stakeC), type(uint256).max);
    }

    function test_checkpointsAndSnapshot() public {
        uint64 t0 = uint64(block.timestamp);
        vm.prank(alice);
        stakeC.stake(100e18);
        vm.warp(block.timestamp + 1 hours);
        uint64 t1 = uint64(block.timestamp);
        vm.prank(alice);
        stakeC.stake(50e18);
        vm.warp(block.timestamp + 1 hours);
        assertEq(stakeC.stakeAt(alice, t0), 0, "strictly before the first stake");
        assertEq(stakeC.stakeAt(alice, t0 + 1), 100e18);
        assertEq(stakeC.stakeAt(alice, t1), 100e18, "stake added at t1 does not count at t1");
        assertEq(stakeC.stakeAt(alice, t1 + 1), 150e18);
        assertEq(stakeC.totalAt(t1 + 1), 150e18);
        vm.expectRevert(CipherStake.FutureLookup.selector);
        stakeC.stakeAt(alice, uint64(block.timestamp + 1));
    }

    function test_unstakeCooldown() public {
        vm.startPrank(alice);
        stakeC.stake(100e18);
        vm.expectRevert(CipherStake.InsufficientStake.selector);
        stakeC.requestUnstake(101e18);
        stakeC.requestUnstake(40e18);
        assertEq(stakeC.stakeOf(alice), 60e18, "weight removed at once");
        assertEq(stakeC.totalStaked(), 60e18);
        vm.expectRevert(CipherStake.NotReady.selector);
        stakeC.withdraw();
        vm.warp(block.timestamp + 7 days);
        stakeC.withdraw();
        vm.stopPrank();
        assertEq(cph.balanceOf(alice), 940e18);
        vm.prank(alice);
        vm.expectRevert(CipherStake.ZeroAmount.selector);
        stakeC.withdraw();
    }
}

contract BlindBallotTest is Test {
    MockCPH cph;
    CipherStake stakeC;
    CipherVault vault;
    BlindBallot ballot;
    address guardian = makeAddr("bb-guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address late = makeAddr("late");
    uint64 genesis;

    function setUp() public {
        vm.warp(1_800_000_000);
        cph = new MockCPH();
        stakeC = new CipherStake(address(cph));
        vault = new CipherVault(guardian, makeAddr("bb-buyback"), makeAddr("bb-compute"), makeAddr("bb-nodes"), makeAddr("bb-rnd"));
        genesis = uint64(block.timestamp + 1 days);
        ballot = new BlindBallot(address(stakeC), address(vault), genesis, 1_000); // 10% quorum
        vm.prank(guardian);
        vault.bindFirstBallot(address(ballot));
        _stake(alice, 300e18);
        _stake(bob, 200e18);
        _stake(carol, 100e18);
        cph.mint(late, 10_000e18);
    }

    function _stake(address who, uint256 amount) internal {
        cph.mint(who, amount);
        vm.startPrank(who);
        cph.approve(address(stakeC), amount);
        stakeC.stake(amount);
        vm.stopPrank();
    }

    function _commit(address who, uint8 route, bytes32 salt) internal {
        uint64 e = ballot.currentEpoch();
        bytes32 c = ballot.commitmentFor(route, salt, who, e);
        vm.prank(who);
        ballot.commit(c);
    }

    function _toReveal() internal {
        vm.warp(ballot.epochStart(ballot.currentEpoch()) + 5 days);
    }

    function _toNextEpoch() internal {
        vm.warp(ballot.epochStart(ballot.currentEpoch()) + 7 days);
    }

    function test_fullEpochAppliesWinner() public {
        vm.warp(genesis);
        assertEq(ballot.currentEpoch(), 1);
        _commit(alice, 1, "a");
        _commit(bob, 2, "b");
        _commit(carol, 1, "c");
        _toReveal();
        vm.prank(alice);
        ballot.reveal(1, "a");
        vm.prank(bob);
        ballot.reveal(2, "b");
        vm.prank(carol);
        ballot.reveal(1, "c");
        vm.expectRevert(BlindBallot.EpochNotOver.selector);
        ballot.finalize(1);
        _toNextEpoch();
        ballot.finalize(1);
        assertEq(vault.route(), 1, "COMPUTE won 400 to 200");
        assertEq(vault.lastAppliedEpoch(), 1);
        uint256[3] memory t = ballot.tally(1);
        assertEq(t[1], 400e18);
        assertEq(t[2], 200e18);
        vm.expectRevert(BlindBallot.AlreadyFinalized.selector);
        ballot.finalize(1);
    }

    function test_lateStakeHasNoWeight() public {
        vm.warp(genesis);
        vm.startPrank(late);
        cph.approve(address(stakeC), type(uint256).max);
        stakeC.stake(10_000e18); // after the epoch opened
        vm.stopPrank();
        _commit(late, 2, "x");
        _toReveal();
        vm.prank(late);
        vm.expectRevert(BlindBallot.NoWeight.selector);
        ballot.reveal(2, "x");
    }

    function test_phases() public {
        vm.expectRevert(BlindBallot.NotStarted.selector);
        ballot.commit(bytes32(uint256(1)));
        vm.warp(genesis);
        _commit(alice, 1, "a");
        vm.prank(alice);
        vm.expectRevert(BlindBallot.WrongPhase.selector);
        ballot.reveal(1, "a");
        _toReveal();
        vm.prank(bob);
        vm.expectRevert(BlindBallot.WrongPhase.selector);
        ballot.commit(bytes32(uint256(1)));
        vm.prank(bob);
        vm.expectRevert(BlindBallot.NoCommitment.selector);
        ballot.reveal(1, "b");
        vm.prank(alice);
        vm.expectRevert(BlindBallot.CommitmentMismatch.selector);
        ballot.reveal(2, "a"); // a different route than sealed
        vm.prank(alice);
        ballot.reveal(1, "a");
        vm.prank(alice);
        vm.expectRevert(BlindBallot.AlreadyRevealed.selector);
        ballot.reveal(1, "a");
    }

    function test_noQuorumKeepsRoute() public {
        BlindBallot strict = new BlindBallot(address(stakeC), address(vault), genesis, 6_000); // 60%
        vm.prank(guardian);
        vault.proposeBallot(address(strict));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(guardian);
        vault.executeBallot();
        vm.warp(genesis + 7 days * 2); // epoch 3 (proposal took us past epoch 1)
        uint64 e = strict.currentEpoch();
        bytes32 c = strict.commitmentFor(2, "a", alice, e);
        vm.prank(alice);
        strict.commit(c); // alice holds 50% < 60% quorum
        vm.warp(strict.epochStart(e) + 5 days);
        vm.prank(alice);
        strict.reveal(2, "a");
        vm.warp(strict.epochStart(e) + 7 days);
        strict.finalize(e);
        assertEq(vault.route(), 0, "route stays BURN");
    }

    function test_tieKeepsCurrentRoute() public {
        vm.warp(genesis);
        _commit(alice, 1, "a"); // 300
        _commit(bob, 0, "b"); // 200
        _commit(carol, 0, "c"); // 100 -> BURN 300, COMPUTE 300
        _toReveal();
        vm.prank(alice);
        ballot.reveal(1, "a");
        vm.prank(bob);
        ballot.reveal(0, "b");
        vm.prank(carol);
        ballot.reveal(0, "c");
        _toNextEpoch();
        ballot.finalize(1);
        assertEq(vault.route(), 0, "tie keeps BURN");
    }

    function test_unrevealedVotesDoNotCount() public {
        vm.warp(genesis);
        _commit(alice, 2, "a");
        _commit(bob, 1, "b");
        _toReveal();
        vm.prank(bob);
        ballot.reveal(1, "b"); // alice never reveals
        _toNextEpoch();
        ballot.finalize(1);
        assertEq(vault.route(), 1);
    }

    function test_safeModeBlocksApplyButFinalizeStillCloses() public {
        vm.prank(guardian);
        vault.setPaused(true);
        vm.warp(genesis);
        _commit(alice, 2, "a");
        _toReveal();
        vm.prank(alice);
        ballot.reveal(2, "a");
        _toNextEpoch();
        ballot.finalize(1);
        assertTrue(ballot.finalized(1));
        assertEq(vault.route(), 0, "paused vault keeps BURN");
    }
}
