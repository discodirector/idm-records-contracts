// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {EthPoolSwap} from "./EthPoolSwap.sol";
import {KeeperOwned} from "./KeeperOwned.sol";

interface IRecordsPot {
    function rewardToken() external view returns (address);
    function totalSupply() external view returns (uint256);
    function depositPool(uint256 amount) external;
}

/// @title RewardFeeder — the NFT holders' share on Robinhood, into the IDM Records reward pot's shared pool
/// @notice Receives the holders' share of label money paid on Robinhood: ETH from the royalty splitter, USDG from the
///         Stations splitter. `feed` swaps the ETH to the reward token (USDG) in one Uniswap v4 pool and deposits
///         everything it holds into the pot's shared pool. No per-track credits here: a track's own x402 sales are
///         paid on Base (HolderRewards). The reward token can only ever leave into the pot.
///
///         Only the keeper feeds, with a `minOut` from a fresh quote (a swap with a caller-chosen minimum could be
///         sandwiched, so it is never open to everyone). A floor the keeper cannot change bounds the swap too:
///         `minUsdgPerEth`, set by the owner, so a leaked keeper key that moves the pool first (a sandwich of its own
///         feed) gets at most the gap between the market and the floor, not the whole balance. The owner can replace
///         a dead or leaked keeper and move the floor, and nothing else: no withdrawal, no admin transfer of funds,
///         no upgrade. Any other token that lands here (royalties
///         paid in some other ERC-20) is swept by the keeper to `sweepTo`, the infra wallet fixed at deploy.
contract RewardFeeder is EthPoolSwap, KeeperOwned {
    IRecordsPot public immutable records;
    /// @notice The pot's reward token (USDG), the swap's output.
    address public immutable rewardToken;
    /// @notice Where `sweep` sends tokens other than the reward token (infra). Fixed at deploy.
    address public immutable sweepTo;

    /// @notice Read by the payout bot: a feed is due after a day even when little is waiting.
    uint64 public lastFeed;
    /// @notice Least USDG (6-decimal units) per 1 ETH a feed may get on average. Owner only, never zero.
    uint256 public minUsdgPerEth;

    event Fed(uint256 ethIn, uint256 swappedOut, uint256 pooled);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event FloorSet(uint256 minUsdgPerEth);

    error TooLittle(uint256 got, uint256 minOut);
    error BelowFloor(uint256 ethPaid, uint256 got, uint256 minUsdgPerEth);
    error ZeroFloor();
    error NotSweepable();

    constructor(
        IPoolManager poolManager_,
        IRecordsPot records_,
        address owner_,
        address keeper_,
        address sweepTo_,
        uint24 fee_,
        int24 tickSpacing_,
        uint256 minUsdgPerEth_
    ) EthPoolSwap(poolManager_, records_.rewardToken(), fee_, tickSpacing_) KeeperOwned(owner_, keeper_) {
        if (sweepTo_ == address(0)) revert ZeroAddress();
        records = records_;
        rewardToken = records_.rewardToken();
        sweepTo = sweepTo_;
        lastFeed = uint64(block.timestamp);
        _setFloor(minUsdgPerEth_);
    }

    /// @notice A new floor, e.g. after ETH moved a long way (feeds revert BelowFloor while the market is under it).
    function setFloor(uint256 minUsdgPerEth_) external onlyOwner {
        _setFloor(minUsdgPerEth_);
    }

    function _setFloor(uint256 f) private {
        if (f == 0) revert ZeroFloor();
        minUsdgPerEth = f;
        emit FloorSet(f);
    }

    receive() external payable {}

    /// @notice Swaps all ETH held (if any) to the reward token and pools everything held. Keeper only.
    /// @param minOut Least reward token the swap may return; ignored when there is no ETH.
    function feed(uint256 minOut) external onlyKeeper returns (uint256 swappedOut, uint256 pooled) {
        lastFeed = uint64(block.timestamp);
        uint256 ethIn = address(this).balance;
        if (ethIn > 0) {
            swappedOut = _swap(true, ethIn);
            if (swappedOut < minOut) revert TooLittle(swappedOut, minOut);
            // A pool short of liquidity takes less than all of it; the floor is checked on what was paid.
            uint256 paid = ethIn - address(this).balance;
            if (swappedOut * 1e18 < paid * minUsdgPerEth) revert BelowFloor(paid, swappedOut, minUsdgPerEth);
        }
        // The pool splits among tokens minted now; with none minted yet the money waits here for the first.
        IERC20Minimal token = IERC20Minimal(rewardToken);
        pooled = token.balanceOf(address(this));
        if (pooled > 0 && records.totalSupply() > 0) {
            token.approve(address(records), pooled);
            records.depositPool(pooled);
        } else {
            pooled = 0;
        }
        emit Fed(ethIn, swappedOut, pooled);
    }

    /// @notice Sends this contract's whole balance of `token` (anything but the reward token) to `sweepTo`.
    function sweep(address token) external onlyKeeper returns (uint256 amount) {
        if (token == rewardToken || token == address(0)) revert NotSweepable();
        amount = IERC20Minimal(token).balanceOf(address(this));
        if (amount > 0) _transferToken(token, sweepTo, amount);
        emit Swept(token, sweepTo, amount);
    }
}
