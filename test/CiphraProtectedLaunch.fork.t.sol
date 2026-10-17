// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {CipherVault} from "../src/CipherVault.sol";
import {CipherStake} from "../src/CipherStake.sol";
import {BlindBallot} from "../src/BlindBallot.sol";

interface IProtectedToken {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function walletTokenLimit() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IProtectedHook {
    function poolKey() external view returns (PoolKey memory);
    function feeVault() external view returns (address);
    function creatorBuyFeeBps() external view returns (uint16);
}

interface IProtectedInitializer {
    function initialize(address hook, address token, int24 startTick, address buyer, uint256 minTokenOut) external payable;
    function openingFdvUsd() external view returns (uint256);
}

interface IFeeVault {
    function creatorAccrued() external view returns (uint256);
    function creatorRecipient() external view returns (address);
    function claimCreator() external returns (uint256);
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice $CPH on Programmable's mandatory launch-protection package v1 (CLI 4.1.7), on a mainnet fork, with the
///         exact published bytecode of the initializer, token and hook and CipherVault as the immutable creator-fee
///         recipient. Then the full CIPHRA loop: trades, claimCreator -> vault, stake real $CPH, a sealed ballot,
///         the route switch, and the split. Run: ETH_RPC_URL=<rpc> forge test --match-contract CiphraProtectedLaunchForkTest -vv
contract CiphraProtectedLaunchForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    bytes32 constant FEED_HASH = 0x4b79b5c8aee6da0f7b393e8b53e6265ef7320a1d16184c65bd3841b5aa3d700d;
    address constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    bytes32 constant ROUTER_HASH = 0x41ccd905c8e4de29ce9536ff49233b79e3085a0987d490664e703ee1e7b1dc49;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint16 constant CREATOR_BPS = 200;

    struct PoolConfig {
        address token;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
        address initializer;
        address creatorFeeRecipient;
        uint16 creatorBuyFeeBps;
        uint16 creatorSellFeeBps;
        address module;
        uint24 maxModuleLpFeePips;
    }

    address dev = makeAddr("ciphra-dev");
    address alice = makeAddr("ciphra-holder-alice");
    address bob = makeAddr("ciphra-holder-bob");
    address guardian = makeAddr("ciphra-guardian-safe");
    address buyback = makeAddr("ciphra-buyback-safe");
    address compute = makeAddr("ciphra-compute-safe");
    address nodes = makeAddr("ciphra-nodes-safe");
    address rnd = makeAddr("ciphra-rnd-safe");
    bool forked;

    IProtectedInitializer initializer;
    IProtectedToken cph;
    IProtectedHook hook;
    CipherVault vault;
    int24 startTick;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vm.deal(alice, 20 ether);
        vm.deal(bob, 20 ether);
    }

    function _code(string memory name) internal view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(string.concat("test/fixtures/launch-protection/", name, ".artifact.json")), ".creationBytecode");
    }

    function _deploy(bytes memory initCode) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(a != address(0), "deploy failed");
    }

    function _fdvUsd(int24 tick, uint256 answer) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(FullMath.mulDiv(uint256(1) << 192, SUPPLY, uint256(sqrtP) * sqrtP), answer, 1 ether * 1e8);
    }

    /// @dev Highest 60-aligned tick whose opening FDV is still >= target (same search as the package helper).
    function _tickFor(uint256 targetUsd) internal view returns (int24) {
        (, int256 answer,,,) = IFeed(FEED).latestRoundData();
        int256 lo = -14786;
        int256 hi = 14786;
        while (lo < hi) {
            int256 mid = (lo + hi + 1) / 2;
            if (_fdvUsd(int24(mid * 60), uint256(answer)) >= targetUsd) lo = mid;
            else hi = mid - 1;
        }
        return int24(lo * 60);
    }

    function _hookArgs() internal view returns (bytes memory) {
        PoolConfig memory c = PoolConfig(address(cph), 0, 60, TickMath.getSqrtPriceAtTick(startTick), address(initializer),
            address(vault), CREATOR_BPS, CREATOR_BPS, address(0), 0);
        address[6] memory exempt;
        return abi.encode(PM, c, dev, ROUTER, ROUTER_HASH, exempt);
    }

    function _launch(uint256 initialBuy) internal {
        initializer = IProtectedInitializer(_deploy(abi.encodePacked(_code("ProtectedNativeInitializerV1"), abi.encode(PM, address(this), FEED, FEED_HASH))));
        cph = IProtectedToken(_deploy(abi.encodePacked(_code("ProtectedLaunchTokenV1"), abi.encode("CIPHRA", "CPH", SUPPLY, address(initializer), PM))));
        vault = new CipherVault(guardian, buyback, compute, nodes, rnd);
        startTick = _tickFor(20_000);
        bytes memory hookInit = abi.encodePacked(_code("ProtectedNative30HookV1"), _hookArgs());
        bytes32 initHash = keccak256(hookInit);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            if (uint160(vm.computeCreate2Address(salt, initHash, address(this))) & 0x3fff == 0x20cc) break;
        }
        address h;
        assembly ("memory-safe") {
            h := create2(0, add(hookInit, 0x20), mload(hookInit), salt)
        }
        require(h != address(0), "hook deploy failed");
        hook = IProtectedHook(h);
        vm.deal(address(this), initialBuy);
        initializer.initialize{value: initialBuy}(address(hook), address(cph), startTick, dev, 1);
    }

    function _swap(address who, bool buy, uint256 amount) internal {
        PoolSwapTest swapper = new PoolSwapTest(PM);
        PoolKey memory key = hook.poolKey();
        if (!buy) {
            vm.prank(who);
            cph.approve(address(swapper), amount);
        }
        vm.prank(who);
        swapper.swap{value: buy ? amount : 0}(
            key,
            SwapParams({zeroForOne: buy, amountSpecified: -int256(amount), sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_fork_ciphraFullLoop() public {
        if (!forked) return;
        _launch(0.03 ether);
        assertEq(cph.symbol(), "CPH");
        assertGe(initializer.openingFdvUsd(), 15_000, "USD floor");
        emit log_named_uint("opening FDV (USD)", initializer.openingFdvUsd());
        IFeeVault fees = IFeeVault(hook.feeVault());
        assertEq(fees.creatorRecipient(), address(vault), "creator fees go to the Cipher Vault");
        assertLe(cph.balanceOf(dev), cph.walletTokenLimit(), "opening buy within 2%");

        // After the 300-second protection window: holders buy, one sells
        vm.warp(block.timestamp + 301);
        _swap(alice, true, 5 ether);
        _swap(bob, true, 3 ether);
        _swap(bob, false, cph.balanceOf(bob) / 4);
        uint256 accrued = fees.creatorAccrued();
        emit log_named_uint("creator fees accrued (wei)", accrued);
        assertGt(accrued, 0.16 ether, "2% of > 8 ETH of volume");

        // Anyone claims into the vault; first distribution follows the default BURN route
        uint256 claimed = fees.claimCreator();
        assertEq(address(vault).balance, claimed);
        vault.distribute();
        assertEq(buyback.balance, claimed * 5000 / 10_000, "50% sealed pot -> buyback (BURN)");
        assertEq(rnd.balance, claimed * 3000 / 10_000, "30% R&D");
        assertEq(vault.bountyPool(), claimed - claimed * 5000 / 10_000 - claimed * 3000 / 10_000, "20% bounty pool");

        // Staking real $CPH and the Blind Ballot
        CipherStake stakeC = new CipherStake(address(cph));
        BlindBallot ballot = new BlindBallot(address(stakeC), address(vault), uint64(block.timestamp + 1 hours), 1_000);
        vm.prank(guardian);
        vault.bindFirstBallot(address(ballot));
        uint256 aliceStake = cph.balanceOf(alice) / 2;
        uint256 bobStake = cph.balanceOf(bob) / 2;
        vm.startPrank(alice);
        cph.approve(address(stakeC), aliceStake);
        stakeC.stake(aliceStake);
        vm.stopPrank();
        vm.startPrank(bob);
        cph.approve(address(stakeC), bobStake);
        stakeC.stake(bobStake);
        vm.stopPrank();

        vm.warp(ballot.genesis());
        uint64 e = ballot.currentEpoch();
        bytes32 aliceSeal = ballot.commitmentFor(1, "alice-salt", alice, e); // COMPUTE
        bytes32 bobSeal = ballot.commitmentFor(2, "bob-salt", bob, e); // NODES
        vm.prank(alice);
        ballot.commit(aliceSeal);
        vm.prank(bob);
        ballot.commit(bobSeal);
        vm.warp(ballot.epochStart(e) + 5 days);
        vm.prank(alice);
        ballot.reveal(1, "alice-salt");
        vm.prank(bob);
        ballot.reveal(2, "bob-salt");

        // More trading during the epoch, earned under BURN
        _swap(alice, true, 1 ether);
        uint256 claimed2 = fees.claimCreator();
        vm.warp(ballot.epochStart(e) + 7 days);
        ballot.finalize(e);
        uint8 expected = aliceStake > bobStake ? 1 : 2;
        assertEq(vault.route(), expected, "the heavier sealed vote won");
        assertEq(buyback.balance, (claimed + claimed2) * 5000 / 10_000, "fees earned before the switch went to BURN");

        // Fees after the switch follow the new route
        _swap(bob, true, 2 ether);
        uint256 claimed3 = fees.claimCreator();
        vault.distribute();
        address dest = expected == 1 ? compute : nodes;
        assertEq(dest.balance, claimed3 * 5000 / 10_000, "sealed pot follows the ballot");
        emit log_named_uint("alice stake", aliceStake / 1e18);
        emit log_named_uint("bob stake", bobStake / 1e18);
        emit log_named_uint("route after epoch 1", vault.route());
    }

    function test_fork_protectionWindowStillApplies() public {
        if (!forked) return;
        _launch(0.03 ether);
        PoolSwapTest swapper = new PoolSwapTest(PM);
        PoolKey memory key = hook.poolKey();
        vm.prank(alice);
        vm.expectRevert(); // buys inside 300 s must come through the canonical router
        swapper.swap{value: 0.1 ether}(key, SwapParams(true, -0.1 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), "");
    }
}
