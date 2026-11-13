// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title EthPoolSwap — one exact-input swap in one Uniswap v4 ETH/token pool (no hooks), from inside this contract
/// @notice ETH (address 0) sorts first, so it is always currency0 against an ERC-20. The swap runs only from the
///         contract's own `_swap` (a transient flag), so nobody can make the PoolManager call back into it.
///         The caller of `_swap` checks the output against a minimum: the swap itself takes any price.
abstract contract EthPoolSwap is IUnlockCallback {
    IPoolManager public immutable poolManager;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    /// @dev The pool's ERC-20 side (USDG).
    address internal immutable _token;

    bytes32 private constant SWAPPING_SLOT = keccak256("idm.ethpoolswap.swapping");

    error OnlyPoolManager();
    error NotSwapping();
    error Reentrant();
    error TokenTransferFailed();

    constructor(IPoolManager poolManager_, address token_, uint24 fee_, int24 tickSpacing_) {
        require(token_ != address(0), "token");
        poolManager = poolManager_;
        _token = token_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(_token), fee, tickSpacing, IHooks(address(0)));
    }

    /// @dev Swaps `amountIn` (ETH when `ethIn`, else the token) for the other side, received here. Returns the output.
    function _swap(bool ethIn, uint256 amountIn) internal returns (uint256 out) {
        if (_swapping()) revert Reentrant();
        _setSwapping(true);
        out = abi.decode(poolManager.unlock(abi.encode(ethIn, amountIn)), (uint256));
        _setSwapping(false);
    }

    /// @dev Only the PoolManager, and only inside this contract's own `_swap`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_swapping()) revert NotSwapping();
        (bool ethIn, uint256 amount) = abi.decode(data, (bool, uint256));
        uint160 limit = ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = poolManager.swap(poolKey(), SwapParams(ethIn, -int256(amount), limit), "");
        uint256 got;
        if (ethIn) {
            uint256 paid = uint256(-int256(d.amount0()));
            got = uint256(int256(d.amount1()));
            poolManager.settle{value: paid}();
            poolManager.take(Currency.wrap(_token), address(this), got);
        } else {
            uint256 paid = uint256(-int256(d.amount1()));
            got = uint256(int256(d.amount0()));
            poolManager.sync(Currency.wrap(_token));
            _transferToken(_token, address(poolManager), paid);
            poolManager.settle();
            poolManager.take(Currency.wrap(address(0)), address(this), got);
        }
        return abi.encode(got);
    }

    /// @dev ERC-20 transfer that accepts tokens returning nothing, and reverts on a false return.
    function _transferToken(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
    }

    function _swapping() private view returns (bool on) {
        bytes32 slot = SWAPPING_SLOT;
        assembly ("memory-safe") {
            on := tload(slot)
        }
    }

    function _setSwapping(bool on) private {
        bytes32 slot = SWAPPING_SLOT;
        assembly ("memory-safe") {
            tstore(slot, on)
        }
    }
}
