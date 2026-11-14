// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Split {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETH9 {
    function withdraw(uint256 amount) external;
}

/// @title RevenueSplitter — the IDM label's money split, fixed forever
/// @notice Everything sent here is split between fixed payees by fixed shares (basis points of 10_000). No owner, no
///         admin, no upgrade. Anyone may trigger a release; payees get pushed their share of the whole balance.
///
///         One contract, two deployments (owner decision 2026-11-03, docs/X402-MUSIC.md):
///         - Robinhood Chain, the NFT royalty receiver: 50% RewardFeeder (→ USDG → IDM Records reward pot),
///           25% TreasuryFeeder (ETH, and USDG swapped to ETH, on to PulseTreasury: its ETH can only buy IDM,
///           and its IDM can only be burned), 25% infra.
///         - Base, the x402 LabelSplitter: 50% HolderRewards (holders paid in USDC on Base), 25% the burn wallet (the
///           bridge keeper moves it to Robinhood as ETH for PulseTreasury), 25% infra.
///         - Stations income, one per payment chain: four payees at 25% each (holders, $IDM burn, IMD burn, infra);
///           on Robinhood the $IDM quarter goes to TreasuryFeeder (USDG -> ETH -> PulseTreasury).
///         On Base, HolderRewards takes ETH and other tokens and sweeps them to infra (only USDC counts there).
///
///         A payee marked `ethOnly` cannot use tokens (PulseTreasury has no way to move them): WETH is unwrapped first
///         (`unwrapWeth`), and for any other token that payee's share goes to `tokenSink` instead of being lost.
contract RevenueSplitter {
    uint256 public constant BPS = 10_000;

    address[] private _accounts;
    uint16[] private _bps;
    bool[] private _ethOnly;

    /// @notice Unwrapped by `unwrapWeth`; never released as a token. Zero = none on this chain.
    address public immutable weth;
    /// @notice Receives the `ethOnly` payees' share of a token release.
    address public immutable tokenSink;

    bytes32 private constant LOCK_SLOT = keccak256("idm.revenuesplitter.lock");

    event Released(address indexed token, address indexed account, uint256 amount);

    error BadPayees();
    error NothingToRelease();
    error UseUnwrap();
    error PayFailed(address account);
    error Reentrant();

    constructor(address[] memory accounts, uint16[] memory bps, bool[] memory ethOnly, address weth_, address tokenSink_) {
        uint256 n = accounts.length;
        if (n == 0 || n != bps.length || n != ethOnly.length) revert BadPayees();
        uint256 total;
        bool anyEthOnly;
        for (uint256 i; i < n; ++i) {
            if (accounts[i] == address(0) || bps[i] == 0) revert BadPayees();
            for (uint256 j; j < i; ++j) {
                if (accounts[j] == accounts[i]) revert BadPayees();
            }
            total += bps[i];
            anyEthOnly = anyEthOnly || ethOnly[i];
        }
        if (total != BPS) revert BadPayees();
        // The sink must be able to take tokens itself, or a token release would just move the problem.
        if (anyEthOnly) {
            bool sinkOk;
            for (uint256 i; i < n; ++i) {
                if (accounts[i] == tokenSink_ && !ethOnly[i]) sinkOk = true;
            }
            if (!sinkOk) revert BadPayees();
        }
        _accounts = accounts;
        _bps = bps;
        _ethOnly = ethOnly;
        weth = weth_;
        tokenSink = tokenSink_;
    }

    receive() external payable {}

    function payees() external view returns (address[] memory accounts, uint16[] memory bps, bool[] memory ethOnly) {
        return (_accounts, _bps, _ethOnly);
    }

    /// @notice Pushes the whole ETH balance to the payees. Rounding dust goes to the last payee.
    function release() external nonReentrant {
        uint256 total = address(this).balance;
        if (total == 0) revert NothingToRelease();
        uint256 left = total;
        uint256 n = _accounts.length;
        for (uint256 i; i < n; ++i) {
            uint256 amount = i == n - 1 ? left : total * _bps[i] / BPS;
            left -= amount;
            (bool ok,) = _accounts[i].call{value: amount}("");
            if (!ok) revert PayFailed(_accounts[i]);
            emit Released(address(0), _accounts[i], amount);
        }
    }

    /// @notice Turns any WETH held into ETH (royalties paid from WETH offers), for `release`.
    function unwrapWeth() external nonReentrant {
        uint256 amount = weth == address(0) ? 0 : IERC20Split(weth).balanceOf(address(this));
        if (amount == 0) revert NothingToRelease();
        IWETH9(weth).withdraw(amount);
    }

    /// @notice Pushes the whole balance of `token` to the payees; `ethOnly` payees' shares go to `tokenSink`.
    function releaseToken(address token) external nonReentrant {
        if (token == weth && weth != address(0)) revert UseUnwrap();
        uint256 total = IERC20Split(token).balanceOf(address(this));
        if (total == 0) revert NothingToRelease();
        uint256 left = total;
        uint256 n = _accounts.length;
        for (uint256 i; i < n; ++i) {
            uint256 amount = i == n - 1 ? left : total * _bps[i] / BPS;
            left -= amount;
            address to = _ethOnly[i] ? tokenSink : _accounts[i];
            _transfer(token, to, amount);
            emit Released(token, to, amount);
        }
    }

    function _transfer(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Split.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert PayFailed(to);
    }

    modifier nonReentrant() {
        bytes32 slot = LOCK_SLOT;
        bool locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked) revert Reentrant();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }
}
