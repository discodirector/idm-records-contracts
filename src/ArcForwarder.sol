// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Forward {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Circle CCTP V2 TokenMessengerV2 (github.com/circlefin/evm-cctp-contracts, src/v2/TokenMessengerV2.sol).
interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    function localMinter() external view returns (address);

    /// @dev The least `maxFee` a burn of `amount` must allow (0 while Circle's minimum fee is off).
    function getMinFeeAmount(uint256 amount) external view returns (uint256);
}

/// @dev Circle CCTP V2 TokenMinterV2: the largest amount one message may burn.
interface ITokenMinterV2 {
    function burnLimitsPerMessage(address token) external view returns (uint256);
}

/// @title ArcForwarder — the label's pay-to on Arc, sends every USDC it gets to the LabelSplitter on Base
/// @notice x402 sales paid on Arc (Circle's L1) land here. `forward()` burns the whole USDC balance with Circle CCTP V2
///         and names the LabelSplitter on Base as the only recipient of the mint, so the 50 / 25 / 25 split and the
///         holders' rewards stay one contract and one path on Base (owner decision 2026-11-05, docs/X402-MUSIC.md
///         section 5b). No owner, no admin, no upgrade, no way to send USDC anywhere else.
///
///         - Anyone may call `forward()` (the label's keeper does, bot/src/arc). It burns at most CCTP's per-message
///           limit and at least `minAmount`, so dust cannot spam messages.
///         - Standard finality (2000) only: a caller cannot buy a Fast Transfer. `maxFee` is exactly the minimum fee
///           Circle's TokenMessengerV2 asks for (`getMinFeeAmount`, 0 today: Standard Transfers from Arc are free),
///           so CCTP can never take more. If Circle's minimum ever passes `maxFeeBps` of the amount (a cap fixed at
///           deploy), forwards stop with `FeeAboveCap` and the USDC waits here until the minimum comes back down.
///         - `destinationCaller` is zero: anyone can finish a message on Base with Circle's public attestation
///           (MessageTransmitterV2.receiveMessage), so a stuck message never needs this contract or the label.
///         - `hookData` is the forward's sequence number (abi-encoded uint256). CCTP carries it to Base untouched and
///           runs no code for it; the rewards keeper reads it to match each mint on Base to its forward here.
///         Tokens other than USDC sent here cannot leave (there is no sweep): only USDC is ever expected.
contract ArcForwarder {
    /// @notice CCTP V2 "finalized" threshold: a Standard Transfer.
    uint32 public constant FINALITY_STANDARD = 2000;
    uint256 public constant BPS = 10_000;
    /// @notice The deploy may allow a fee of at most 1% of a forward.
    uint16 public constant MAX_FEE_BPS_LIMIT = 100;

    /// @notice USDC's ERC-20 interface on Arc.
    IERC20Forward public immutable usdc;
    ITokenMessengerV2 public immutable tokenMessenger;
    /// @notice CCTP domain of the destination chain (Base = 6).
    uint32 public immutable destinationDomain;
    /// @notice The LabelSplitter on Base, as CCTP's bytes32 recipient.
    bytes32 public immutable mintRecipient;
    /// @notice The smallest forward (USDC units, 6 decimals).
    uint256 public immutable minAmount;
    /// @notice The largest CCTP fee a forward may pay, in basis points of its amount: a cap on Circle's minimum fee.
    uint16 public immutable maxFeeBps;

    /// @notice Forwards so far; the next one carries `forwards + 1` in its hookData.
    uint64 public forwards;

    /// @param seq the forward's number (1, 2, 3...), also its hookData
    /// @param amount USDC burned on Arc; the LabelSplitter gets it on Base less the fee CCTP takes (0 for Standard)
    /// @param left USDC still here (above CCTP's per-message limit): the next forward sends it
    event Forwarded(uint64 indexed seq, uint256 amount, uint256 maxFee, uint256 left);

    error BadConfig();
    error TooLittle(uint256 balance, uint256 minAmount);
    error ApproveFailed();
    error FeeAboveCap(uint256 minFee, uint256 cap);

    constructor(
        address usdc_,
        address tokenMessenger_,
        uint32 destinationDomain_,
        address mintRecipient_,
        uint256 minAmount_,
        uint16 maxFeeBps_
    ) {
        if (usdc_ == address(0) || tokenMessenger_ == address(0) || mintRecipient_ == address(0)) revert BadConfig();
        if (minAmount_ == 0 || maxFeeBps_ > MAX_FEE_BPS_LIMIT) revert BadConfig();
        usdc = IERC20Forward(usdc_);
        tokenMessenger = ITokenMessengerV2(tokenMessenger_);
        destinationDomain = destinationDomain_;
        mintRecipient = bytes32(uint256(uint160(mintRecipient_)));
        minAmount = minAmount_;
        maxFeeBps = maxFeeBps_;
    }

    /// @notice The LabelSplitter on Base, as an address.
    function recipient() external view returns (address) {
        return address(uint160(uint256(mintRecipient)));
    }

    /// @notice What `forward()` would burn now, the fee it would allow (Circle's minimum) and the cap on that fee.
    ///         `amount` is 0 below `minAmount`.
    function forwardable() public view returns (uint256 amount, uint256 maxFee, uint256 cap) {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance < minAmount) return (0, 0, 0);
        amount = balance;
        uint256 limit = ITokenMinterV2(tokenMessenger.localMinter()).burnLimitsPerMessage(address(usdc));
        if (limit != 0 && amount > limit) amount = limit;
        cap = amount * maxFeeBps / BPS;
        try tokenMessenger.getMinFeeAmount(amount) returns (uint256 f) {
            maxFee = f;
        } catch {
            maxFee = 0; // no minimum-fee switch on this messenger
        }
    }

    /// @notice Burns the USDC balance (up to CCTP's per-message limit) for a mint to the LabelSplitter on Base.
    function forward() external returns (uint64 seq, uint256 amount) {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance < minAmount) revert TooLittle(balance, minAmount);
        uint256 maxFee;
        uint256 cap;
        (amount, maxFee, cap) = forwardable();
        if (maxFee > cap) revert FeeAboveCap(maxFee, cap);
        seq = ++forwards;
        if (!usdc.approve(address(tokenMessenger), amount)) revert ApproveFailed();
        tokenMessenger.depositForBurnWithHook(
            amount, destinationDomain, mintRecipient, address(usdc), bytes32(0), maxFee, FINALITY_STANDARD, abi.encode(seq)
        );
        emit Forwarded(seq, amount, maxFee, usdc.balanceOf(address(this)));
    }
}
