// SPDX-License-Identifier: MIT
// Swarm audit 2026-11-13 (job 88d4aa11, findings 1 and 2): the auditors' proofs, on a local v4 pool, against the fix.
// A balance the pool cannot take inside the owner's band no longer holds back the other leg: the keeper pools the
// USDG (RewardFeeder) or sends the ETH (TreasuryFeeder) without swapping, and swaps the rest in slices.
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IDMRecords, IERC20Like, IBalanceOf} from "src/IDMRecords.sol";
import {RewardFeeder, IRecordsPot} from "src/RewardFeeder.sol";
import {TreasuryFeeder} from "src/TreasuryFeeder.sol";

/// @dev 6-decimal stand-in for USDG.
contract SliceUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Minimal liquidity provider for the local pool: pays ETH from its own balance and the token from the test.
contract SliceLp is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;
    SliceUSD immutable usd;

    constructor(IPoolManager pm_, SliceUSD usd_) {
        pm = pm_;
        usd = usd_;
    }

    receive() external payable {}

    function addLiquidity(PoolKey memory key, int24 lower, int24 upper, int256 amount) external {
        pm.unlock(abi.encode(key, lower, upper, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 lower, int24 upper, int256 amount) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        pm.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, amount, bytes32(0)), "");
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        pm.settle{value: uint256(-d0)}();
        pm.sync(key.currency1);
        usd.transfer(address(pm), uint256(-d1));
        pm.settle();
        return "";
    }
}

/// Finding: RewardFeeder.feed swaps the WHOLE ETH balance or nothing. When the balance is more than the pool absorbs
/// inside the owner's band, the floor check reverts the whole call, and with it the pooling of USDG that needs no swap
/// (the Stations splitter's quarter). The USDG stays in the feeder until the owner lowers the floor to the bad price.
/// Expected: a feed never leaves USDG unpooled because of the ETH held; ETH the band cannot absorb waits instead.
contract FeedAllOrNothingTest is Test {
    uint256 constant SIGNER_KEY = 0xA11CE;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address infra = makeAddr("infra");
    address alice = makeAddr("alice");

    PoolManager pm;
    SliceUSD usd;
    IDMRecords nft;
    RewardFeeder feeder;
    PoolKey key;
    /// @dev 3000 USDG per ETH: tick of 3000e6 / 1e18.
    int24 constant START_TICK = -196260;

    function setUp() public {
        pm = new PoolManager(address(this));
        usd = new SliceUSD();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usd)), 500, 10, IHooks(address(0)));
        pm.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));

        // Liquidity in a +-10000 tick range (about -63% / +170%): roughly 72 ETH and 215k USDG.
        SliceLp lp = new SliceLp(pm, usd);
        vm.deal(address(lp), 200 ether);
        usd.mint(address(lp), 1_000_000e6);
        lp.addLiquidity(key, START_TICK - 10000, START_TICK + 10000, 1e16);

        nft = new IDMRecords(
            "IDM Records", "RECORDS", address(this), vm.addr(SIGNER_KEY), IERC20Like(address(usd)),
            IBalanceOf(address(usd)), "https://x/", address(0), 0
        );
        nft.setMintableUpTo(1000);
        _mint(alice, 1);

        uint256 price = 3000e6;
        feeder = new RewardFeeder(pm, IRecordsPot(address(nft)), owner, keeper, infra, 500, 10, price * 3 / 4);
    }

    function _mint(address to, uint256 id) internal {
        IDMRecords.Voucher memory v =
            IDMRecords.Voucher(to, id, keccak256(abi.encode(id)), 1, 1, uint64(block.timestamp + 1 hours), 0);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, nft.voucherDigest(v));
        vm.prank(to);
        nft.mint(v, abi.encodePacked(r, s, vv));
    }

    /// The Stations splitter paid 500 USDG to the feeder; royalties left 80 ETH there (more than the pool takes
    /// inside the 25% band: the average price of swapping it all is about 2086 USDG/ETH against a 2250 floor).
    function test_usdgHeldIsPooledEvenWhenTheEthCannotBeSwappedInsideTheBand() public {
        usd.mint(address(feeder), 500e6);
        vm.deal(address(feeder), 80 ether);

        // The whole balance in one swap still fails the floor (the band holds)...
        vm.prank(keeper);
        vm.expectRevert();
        feeder.feed(type(uint256).max, 0);

        // ...but the keeper pools the USDG without swapping, and the ETH waits.
        vm.prank(keeper);
        (uint256 out, uint256 pooled) = feeder.feed(0, 0);
        assertEq(out, 0);
        assertEq(pooled, 500e6);
        assertEq(usd.balanceOf(address(feeder)), 0, "USDG the pot could take is still in the feeder");
        assertGe(nft.claimable(1), 500e6, "holder got none of the USDG held");
        assertEq(address(feeder).balance, 80 ether);
    }

    /// The fix's other half: the same 80 ETH goes in slices, each inside the floor.
    function test_aLargeBalanceIsFedInSlices() public {
        vm.deal(address(feeder), 80 ether);
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            vm.prank(keeper);
            (uint256 out,) = feeder.feed(5 ether, 0);
            assertGe(out * 1e18, 5 ether * feeder.minUsdgPerEth(), "slice under the floor");
            total += out;
        }
        assertEq(address(feeder).balance, 60 ether);
        assertEq(nft.claimable(1), total);
    }

    /// Sanity: the same USDG is pooled fine when the ETH balance is small enough for the band.
    function test_sanity_smallEthFeedsAndPools() public {
        usd.mint(address(feeder), 500e6);
        vm.deal(address(feeder), 1 ether);
        vm.prank(keeper);
        (uint256 out, uint256 pooled) = feeder.feed(type(uint256).max, 0);
        assertGt(out, 2250e6);
        assertEq(pooled, out + 500e6);
        assertEq(nft.claimable(1), pooled);
    }
}

/// @dev PulseTreasury stand-in: takes ETH.
contract TreasurySink {
    receive() external payable {}
}

/// Finding: TreasuryFeeder.swap swaps the WHOLE USDG balance or nothing. A USDG balance the pool cannot absorb inside
/// the owner's ceiling reverts the whole call, and with it the forwarding of the ETH held (ETH the Stations splitter
/// released, or ETH left by an earlier swap). Expected: the ETH held reaches the treasury; USDG the band cannot absorb waits.
contract TreasuryAllOrNothingTest is Test {
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address infra = makeAddr("infra");

    PoolManager pm;
    SliceUSD usd;
    TreasurySink treasury;
    TreasuryFeeder feeder;
    PoolKey key;
    int24 constant START_TICK = -196260; // 3000 USDG per ETH

    function setUp() public {
        pm = new PoolManager(address(this));
        usd = new SliceUSD();
        treasury = new TreasurySink();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usd)), 500, 10, IHooks(address(0)));
        pm.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));
        SliceLp lp = new SliceLp(pm, usd);
        vm.deal(address(lp), 200 ether);
        usd.mint(address(lp), 1_000_000e6);
        lp.addLiquidity(key, START_TICK - 10000, START_TICK + 10000, 1e16);

        uint256 price = 3000e6;
        feeder = new TreasuryFeeder(pm, address(usd), address(treasury), owner, keeper, infra, 500, 10, price * 5 / 4);
    }

    /// 1 ETH waits in the feeder; 300k USDG arrived (more than the pool takes inside the 25% ceiling).
    function test_ethHeldReachesTheTreasuryEvenWhenTheUsdgCannotBeSwappedInsideTheBand() public {
        vm.deal(address(feeder), 1 ether);
        usd.mint(address(feeder), 300_000e6);

        vm.prank(keeper);
        vm.expectRevert();
        feeder.swap(type(uint256).max, 0);

        vm.prank(keeper);
        (uint256 usdgIn,, uint256 sent) = feeder.swap(0, 0);
        assertEq(usdgIn, 0);
        assertEq(sent, 1 ether);
        assertEq(address(feeder).balance, 0, "ETH the treasury could take is still in the feeder");
        assertGe(address(treasury).balance, 1 ether, "treasury got none of the ETH held");

        // The USDG goes in slices, each inside the ceiling.
        vm.prank(keeper);
        (uint256 paid, uint256 ethOut,) = feeder.swap(15_000e6, 0);
        assertEq(paid, 15_000e6);
        assertLe(paid * 1e18, ethOut * feeder.maxUsdgPerEth(), "slice over the ceiling");
        assertEq(usd.balanceOf(address(feeder)), 285_000e6);
    }

    function test_sanity_smallUsdgSwapsAndSends() public {
        vm.deal(address(feeder), 1 ether);
        usd.mint(address(feeder), 3000e6);
        vm.prank(keeper);
        (uint256 usdgIn, uint256 ethOut, uint256 sent) = feeder.swap(type(uint256).max, 0);
        assertEq(usdgIn, 3000e6);
        assertGt(ethOut, 0.8 ether);
        assertEq(sent, ethOut + 1 ether);
        assertEq(address(treasury).balance, sent);
    }
}
