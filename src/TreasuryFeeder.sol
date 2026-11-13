// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {EthPoolSwap} from "./EthPoolSwap.sol";
import {KeeperOwned} from "./KeeperOwned.sol";

/// @title TreasuryFeeder — the $IDM quarter of Stations payments on Robinhood, USDG to ETH, into PulseTreasury
/// @notice The Robinhood Stations splitter pays its $IDM buy-and-burn quarter here in USDG. `swap` turns all the USDG
///         it holds into ETH in the ETH/USDG Uniswap v4 pool and sends every wei it holds to PulseTreasury, which can
///         only buy $IDM with it and burn it. ETH sent here goes the same way. No owner withdrawal, no upgrade.
///
///         Only the keeper swaps, with a `minOut` from a fresh quote (an open swap could be sandwiched). A ceiling the
///         keeper cannot change bounds the swap too: `maxUsdgPerEth`, set by the owner, so a leaked keeper key that
///         moves the pool first gets at most the gap between the market and the ceiling. The owner can replace a dead
///         or leaked keeper and move the ceiling, and nothing else. Any other token that lands here is swept by the keeper to
///         `sweepTo`, the infra wallet fixed at deploy (PulseTreasury cannot use tokens).
contract TreasuryFeeder is EthPoolSwap, KeeperOwned {
    /// @notice The token swapped to ETH (USDG).
    address public immutable usdg;
    /// @notice PulseTreasury: receives all the ETH. Fixed at deploy.
    address public immutable treasury;
    /// @notice Where `sweep` sends tokens other than USDG (infra). Fixed at deploy.
    address public immutable sweepTo;

    /// @notice Most USDG (6-decimal units) a swap may pay per 1 ETH on average. Owner only, never zero.
    uint256 public maxUsdgPerEth;
    /// @notice Least USDG (6 decimals: 0.01 USDG) swapped. Less waits for the next swap: v4 rounds the fee on a dust
    ///         input up to all of it, which would fail the ceiling and let 1 unit sent here hold back the ETH.
    uint256 public constant MIN_SWAP_IN = 1e4;

    event Swapped(uint256 usdgIn, uint256 ethOut, uint256 sent);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event CeilingSet(uint256 maxUsdgPerEth);

    error TooLittle(uint256 got, uint256 minOut);
    error AboveCeiling(uint256 usdgPaid, uint256 ethOut, uint256 maxUsdgPerEth);
    error ZeroCeiling();
    error NotSweepable();
    error SendFailed();

    constructor(
        IPoolManager poolManager_,
        address usdg_,
        address treasury_,
        address owner_,
        address keeper_,
        address sweepTo_,
        uint24 fee_,
        int24 tickSpacing_,
        uint256 maxUsdgPerEth_
    ) EthPoolSwap(poolManager_, usdg_, fee_, tickSpacing_) KeeperOwned(owner_, keeper_) {
        if (treasury_ == address(0) || sweepTo_ == address(0)) revert ZeroAddress();
        usdg = usdg_;
        treasury = treasury_;
        sweepTo = sweepTo_;
        _setCeiling(maxUsdgPerEth_);
    }

    /// @notice A new ceiling, e.g. after ETH moved a long way (swaps revert AboveCeiling while the market is over it).
    function setCeiling(uint256 maxUsdgPerEth_) external onlyOwner {
        _setCeiling(maxUsdgPerEth_);
    }

    function _setCeiling(uint256 c) private {
        if (c == 0) revert ZeroCeiling();
        maxUsdgPerEth = c;
        emit CeilingSet(c);
    }

    receive() external payable {}

    /// @notice Swaps all USDG held (if any) to ETH, then sends all ETH held to PulseTreasury. Keeper only.
    /// @param minOut Least ETH (wei) the swap may return; ignored when no USDG is swapped.
    function swap(uint256 minOut) external onlyKeeper returns (uint256 usdgIn, uint256 ethOut, uint256 sent) {
        usdgIn = IERC20Minimal(usdg).balanceOf(address(this));
        // Dust USDG waits; the ETH held still goes to the treasury.
        if (usdgIn < MIN_SWAP_IN) usdgIn = 0;
        if (usdgIn > 0) {
            ethOut = _swap(false, usdgIn);
            if (ethOut < minOut) revert TooLittle(ethOut, minOut);
            // A pool short of liquidity takes less than all of it; what is left waits for the next swap.
            usdgIn -= IERC20Minimal(usdg).balanceOf(address(this));
            if (usdgIn * 1e18 > ethOut * maxUsdgPerEth) revert AboveCeiling(usdgIn, ethOut, maxUsdgPerEth);
        }
        sent = address(this).balance;
        if (sent > 0) {
            (bool ok,) = treasury.call{value: sent}("");
            if (!ok) revert SendFailed();
        }
        emit Swapped(usdgIn, ethOut, sent);
    }

    /// @notice Sends this contract's whole balance of `token` (anything but USDG) to `sweepTo`.
    function sweep(address token) external onlyKeeper returns (uint256 amount) {
        if (token == usdg || token == address(0)) revert NotSweepable();
        amount = IERC20Minimal(token).balanceOf(address(this));
        if (amount > 0) _transferToken(token, sweepTo, amount);
        emit Swept(token, sweepTo, amount);
    }
}
