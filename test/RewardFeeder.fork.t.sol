// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IDMRecords, IERC20Like, IBalanceOf} from "../src/IDMRecords.sol";
import {RewardFeeder, IRecordsPot} from "../src/RewardFeeder.sol";
import {TreasuryFeeder} from "../src/TreasuryFeeder.sol";
import {KeeperOwned} from "../src/KeeperOwned.sol";
import {EthPoolSwap} from "../src/EthPoolSwap.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// Against Robinhood Chain itself: the real PoolManager, the real ETH/USDG 0.05% pool, the real PulseTreasury.
///   FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract FeederForkTest
/// Skipped without FORK_RPC (no network in ordinary runs).
contract FeederForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant IDM = 0x4Fe9f3823791c8b187B81aB8B7398d793FEd28f6;
    address payable constant TREASURY = payable(0xAb64b47daA0f68e50BDF776e73B4245D78575a6c);

    uint256 signerKey = 0xA11CE;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address infra = makeAddr("infra");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");
    IDMRecords nft;
    RewardFeeder feeder;
    TreasuryFeeder treasuryFeeder;
    RevenueSplitter splitter;
    /// @dev The pool's USDG (6 dec) per 1 ETH at the fork block.
    uint256 price;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        nft = new IDMRecords(
            "IDM Records", "RECORDS", address(this), vm.addr(signerKey), IERC20Like(USDG), IBalanceOf(IDM),
            "https://theidm.fun/records/", address(0), 0
        );
        nft.setMintableUpTo(1000);
        // The band the deploy scripts set: 25% either side of the pool's price now.
        price = _poolPrice();
        feeder = new RewardFeeder(PM, IRecordsPot(address(nft)), owner, keeper, infra, 500, 10, price * 3 / 4);
        treasuryFeeder = new TreasuryFeeder(PM, USDG, TREASURY, owner, keeper, infra, 500, 10, price * 5 / 4);
        address[] memory acc = new address[](3);
        (acc[0], acc[1], acc[2]) = (address(feeder), TREASURY, infra);
        uint16[] memory bps = new uint16[](3);
        (bps[0], bps[1], bps[2]) = (5000, 2500, 2500);
        bool[] memory only = new bool[](3);
        only[1] = true;
        splitter = new RevenueSplitter(acc, bps, only, WETH, infra);
    }

    modifier live() {
        if (address(nft) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _mint(address to, uint256 id) internal {
        IDMRecords.Voucher memory v = IDMRecords.Voucher(to, id, keccak256(abi.encode(id)), uint32(id), 1, uint64(block.timestamp + 1 hours), 0);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerKey, nft.voucherDigest(v));
        vm.prank(to);
        nft.mint(v, abi.encodePacked(r, s, vv));
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 500, 10, IHooks(address(0)));
    }

    function _poolPrice() internal view returns (uint256) {
        (uint160 sp,,,) = StateLibrary.getSlot0(PM, PoolIdLibrary.toId(_key()));
        uint256 x96 = FullMath.mulDiv(sp, sp, 1 << 96);
        return FullMath.mulDiv(x96, 1e18, 1 << 96);
    }

    // ---------------------------------------------------------------- RewardFeeder

    function test_RoyaltyToPot() public live {
        _mint(alice, 17);
        uint256 treasuryBefore = TREASURY.balance;
        vm.deal(address(splitter), 1 ether); // a royalty
        splitter.release();
        assertEq(TREASURY.balance - treasuryBefore, 0.25 ether);
        assertEq(address(feeder).balance, 0.5 ether);

        vm.prank(keeper);
        (uint256 out, uint256 pooled) = feeder.feed(500e6); // ~$1100 at ~$2250/ETH
        assertGt(out, 500e6);
        assertEq(pooled, out);
        assertEq(address(feeder).balance, 0);
        assertEq(IERC20View(USDG).balanceOf(address(feeder)), 0);
        assertEq(nft.claimable(17), out); // the only minted token takes the whole pool
    }

    function test_StationsUsdgIsPooledToo() public live {
        _mint(alice, 1);
        _mint(alice, 2);
        deal(USDG, address(feeder), 10e6); // the Stations splitter's holders' quarter
        vm.prank(keeper);
        (uint256 out, uint256 pooled) = feeder.feed(0);
        assertEq(out, 0);
        assertEq(pooled, 10e6);
        assertEq(nft.claimable(1), 5e6);
        assertEq(nft.claimable(2), 5e6);
    }

    function test_SlippageGuard() public live {
        vm.deal(address(feeder), 0.01 ether);
        vm.prank(keeper);
        vm.expectRevert();
        feeder.feed(1_000_000e6);
    }

    /// Review PoC (HIGH): after 7 days of keeper silence anyone could feed with ids/amounts of their choice and credit
    /// their own token with the whole balance, or sandwich their own minOut-0 swap. No caller chooses where the money
    /// goes any more (no ids/amounts), nobody but the keeper feeds however long it is silent, and the owner replaces a
    /// dead keeper instead.
    function test_Poc_SilentKeeperDoesNotOpenTheFeeder() public live {
        for (uint256 i = 1; i <= 10; ++i) _mint(i == 7 ? mallory : alice, i);
        vm.deal(address(feeder), 2 ether);
        deal(USDG, address(feeder), 1000e6);
        vm.warp(block.timestamp + 365 days);
        vm.prank(mallory);
        vm.expectRevert(KeeperOwned.NotKeeper.selector);
        feeder.feed(0);
        // The old ABI (ids, amounts) is gone: a call with it matches no function.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        vm.prank(mallory);
        (bool ok,) = address(feeder).call(abi.encodeWithSignature("feed(uint256,uint256[],uint256[])", 0, ids, ids));
        assertFalse(ok);

        // A dead bot: the owner names a new keeper, which feeds; everything goes to the shared pool.
        address next = makeAddr("new keeper");
        vm.prank(mallory);
        vm.expectRevert(KeeperOwned.NotOwner.selector);
        feeder.setKeeper(mallory);
        vm.prank(owner);
        feeder.setKeeper(next);
        vm.prank(keeper);
        vm.expectRevert(KeeperOwned.NotKeeper.selector);
        feeder.feed(0);
        vm.prank(next);
        (uint256 out, uint256 pooled) = feeder.feed(1);
        assertEq(pooled, out + 1000e6);
        assertEq(nft.claimable(7), nft.claimable(1)); // mallory's token gets one share in ten, like everyone
        assertApproxEqAbs(nft.claimable(7) * 10, pooled, 10);
    }

    function test_NoHoldersYet_MoneyWaits() public live {
        vm.deal(address(feeder), 0.01 ether);
        vm.prank(keeper);
        (uint256 out, uint256 pooled) = feeder.feed(0);
        assertEq(pooled, 0);
        assertEq(IERC20View(USDG).balanceOf(address(feeder)), out);
        _mint(alice, 1);
        vm.prank(keeper);
        (, pooled) = feeder.feed(0);
        assertEq(pooled, out);
    }

    function test_SweepOtherTokensToInfra() public live {
        deal(WETH, address(feeder), 1e15); // a royalty paid in some other token
        deal(USDG, address(feeder), 5e6);
        vm.prank(mallory);
        vm.expectRevert(KeeperOwned.NotKeeper.selector);
        feeder.sweep(WETH);
        vm.startPrank(keeper);
        vm.expectRevert(RewardFeeder.NotSweepable.selector);
        feeder.sweep(USDG); // the holders' money never leaves except into the pot
        vm.expectRevert(RewardFeeder.NotSweepable.selector);
        feeder.sweep(address(0));
        assertEq(feeder.sweep(WETH), 1e15);
        vm.stopPrank();
        assertEq(IERC20View(WETH).balanceOf(infra), 1e15);
        assertEq(IERC20View(USDG).balanceOf(address(feeder)), 5e6);
    }

    function test_CallbackOnlyFromOwnFeed() public live {
        vm.expectRevert(EthPoolSwap.OnlyPoolManager.selector);
        feeder.unlockCallback(abi.encode(true, uint256(1)));
        vm.prank(address(PM));
        vm.expectRevert(EthPoolSwap.NotSwapping.selector);
        feeder.unlockCallback(abi.encode(true, uint256(1)));
    }

    function test_OwnershipTwoStep() public live {
        address next = makeAddr("next owner");
        vm.prank(owner);
        feeder.transferOwnership(next);
        assertEq(feeder.owner(), owner);
        vm.prank(mallory);
        vm.expectRevert(KeeperOwned.NotOwner.selector);
        feeder.acceptOwnership();
        vm.prank(next);
        feeder.acceptOwnership();
        assertEq(feeder.owner(), next);
        vm.prank(next);
        vm.expectRevert(KeeperOwned.ZeroAddress.selector);
        feeder.setKeeper(address(0));
    }

    // ---------------------------------------------------------------- TreasuryFeeder

    /// The $IDM quarter of Stations payments on Robinhood: USDG in, ETH out, all of it to PulseTreasury.
    function test_TreasuryFeederSwapsUsdgToEthForTheTreasury() public live {
        deal(USDG, address(treasuryFeeder), 100e6);
        vm.deal(address(treasuryFeeder), 0.001 ether); // ETH sent here goes along
        uint256 before = TREASURY.balance;
        vm.prank(keeper);
        (uint256 usdgIn, uint256 ethOut, uint256 sent) = treasuryFeeder.swap(0.03 ether); // $100 is ~0.044 ETH
        assertEq(usdgIn, 100e6);
        assertGt(ethOut, 0.03 ether);
        assertEq(sent, ethOut + 0.001 ether);
        assertEq(TREASURY.balance - before, sent);
        assertEq(address(treasuryFeeder).balance, 0);
        assertEq(IERC20View(USDG).balanceOf(address(treasuryFeeder)), 0);
    }

    function test_TreasuryFeederGuards() public live {
        deal(USDG, address(treasuryFeeder), 10e6);
        vm.prank(mallory);
        vm.expectRevert(KeeperOwned.NotKeeper.selector);
        treasuryFeeder.swap(0);
        vm.prank(keeper);
        vm.expectRevert(); // TooLittle: $10 never buys 1 ETH
        treasuryFeeder.swap(1 ether);
        vm.prank(keeper);
        vm.expectRevert(TreasuryFeeder.NotSweepable.selector);
        treasuryFeeder.sweep(USDG);
        deal(WETH, address(treasuryFeeder), 1e15);
        vm.prank(keeper);
        treasuryFeeder.sweep(WETH);
        assertEq(IERC20View(WETH).balanceOf(infra), 1e15);
        // Nothing to swap: it just forwards whatever ETH it holds.
        deal(USDG, address(treasuryFeeder), 0);
        vm.deal(address(treasuryFeeder), 1 wei);
        vm.prank(keeper);
        (uint256 usdgIn,, uint256 sent) = treasuryFeeder.swap(0);
        assertEq(usdgIn, 0);
        assertEq(sent, 1);
        // The owner replaces the keeper.
        vm.prank(owner);
        treasuryFeeder.setKeeper(alice);
        vm.prank(keeper);
        vm.expectRevert(KeeperOwned.NotKeeper.selector);
        treasuryFeeder.swap(0);
        vm.expectRevert(EthPoolSwap.OnlyPoolManager.selector);
        treasuryFeeder.unlockCallback(abi.encode(false, uint256(1)));
    }

    // ---------------------------------------------------------------- the price band (audit 2026-11-13)

    receive() external payable {}

    /// Audit PoC (MEDIUM): a leaked keeper key dumped 250 ETH into the pool, fed with minOut 0 and bought back,
    /// leaving holders $1.45 of 5 ETH. The owner's floor makes that feed revert; the ETH waits for an honest feed.
    function test_Poc_LeakedKeeperSandwichHitsTheFloor() public live {
        _mint(alice, 1);
        PoolRouter router = new PoolRouter(PM);
        vm.deal(address(router), 250 ether);
        router.swap(_key(), SwapParams(true, -int256(250 ether), TickMath.MIN_SQRT_PRICE + 1));
        assertLt(_poolPrice(), feeder.minUsdgPerEth());
        vm.deal(address(feeder), 5 ether);
        vm.prank(keeper);
        vm.expectPartialRevert(RewardFeeder.BelowFloor.selector);
        feeder.feed(0);
        assertEq(address(feeder).balance, 5 ether);
    }

    /// A small move inside the band still feeds.
    function test_FeedInsideTheBand() public live {
        _mint(alice, 1);
        vm.deal(address(feeder), 0.5 ether);
        vm.prank(keeper);
        (uint256 out,) = feeder.feed(0);
        assertGe(out * 1e18, 0.5 ether * feeder.minUsdgPerEth());
    }

    /// The same for TreasuryFeeder: pushing ETH up past the ceiling before its USDG -> ETH swap reverts it.
    function test_Poc_LeakedKeeperSandwichHitsTheCeiling() public live {
        PoolRouter router = new PoolRouter(PM);
        deal(USDG, address(this), 2_000_000e6);
        IERC20View(USDG).approve(address(router), type(uint256).max);
        router.swap(_key(), SwapParams(false, -int256(2_000_000e6), TickMath.MAX_SQRT_PRICE - 1));
        assertGt(_poolPrice(), treasuryFeeder.maxUsdgPerEth());
        deal(USDG, address(treasuryFeeder), 10_000e6);
        vm.prank(keeper);
        vm.expectPartialRevert(TreasuryFeeder.AboveCeiling.selector);
        treasuryFeeder.swap(0);
    }

    /// Swarm audit 2026-11-13 (finding 3): 1 wei sent to RewardFeeder used to swap for 0 USDG, fail the floor and
    /// hold back the USDG it pools. Dust ETH now waits for the next feed; the USDG is pooled. Mirror: 1 unit of USDG
    /// sent to TreasuryFeeder no longer holds back the ETH it forwards.
    function test_Poc_DustDoesNotBlockTheFeeders() public live {
        _mint(alice, 1);
        deal(USDG, address(feeder), 1000e6);
        vm.deal(address(feeder), 1);
        vm.prank(keeper);
        (uint256 out, uint256 pooled) = feeder.feed(0);
        assertEq(out, 0);
        assertEq(pooled, 1000e6);
        assertEq(address(feeder).balance, 1); // waits for the next royalty

        vm.deal(address(treasuryFeeder), 1 ether);
        deal(USDG, address(treasuryFeeder), 1);
        uint256 before = TREASURY.balance;
        vm.prank(keeper);
        (uint256 usdgIn,, uint256 sent) = treasuryFeeder.swap(0);
        assertEq(usdgIn, 0);
        assertEq(sent, 1 ether);
        assertEq(TREASURY.balance - before, 1 ether);
        assertEq(IERC20View(USDG).balanceOf(address(treasuryFeeder)), 1);

        // Just above the threshold the swap runs and clears the band.
        vm.deal(address(feeder), 1e4 * 1e18 / feeder.minUsdgPerEth() + 1);
        vm.prank(keeper);
        (out,) = feeder.feed(0);
        assertGt(out, 0);
        deal(USDG, address(treasuryFeeder), treasuryFeeder.MIN_SWAP_IN());
        vm.prank(keeper);
        (usdgIn,,) = treasuryFeeder.swap(0);
        assertEq(usdgIn, treasuryFeeder.MIN_SWAP_IN());
    }

    /// Only the owner moves the band, never to zero; the keeper cannot.
    function test_BandOwnerOnly() public live {
        vm.prank(keeper);
        vm.expectRevert(KeeperOwned.NotOwner.selector);
        feeder.setFloor(1);
        vm.prank(keeper);
        vm.expectRevert(KeeperOwned.NotOwner.selector);
        treasuryFeeder.setCeiling(type(uint256).max);
        vm.startPrank(owner);
        vm.expectRevert(RewardFeeder.ZeroFloor.selector);
        feeder.setFloor(0);
        vm.expectRevert(TreasuryFeeder.ZeroCeiling.selector);
        treasuryFeeder.setCeiling(0);
        feeder.setFloor(price / 2);
        treasuryFeeder.setCeiling(price * 2);
        vm.stopPrank();
        assertEq(feeder.minUsdgPerEth(), price / 2);
        assertEq(treasuryFeeder.maxUsdgPerEth(), price * 2);
        // A floor over the market stops feeds until the owner lowers it.
        vm.prank(owner);
        feeder.setFloor(price * 2);
        _mint(alice, 1);
        vm.deal(address(feeder), 0.1 ether);
        vm.prank(keeper);
        vm.expectPartialRevert(RewardFeeder.BelowFloor.selector);
        feeder.feed(0);
    }
}
