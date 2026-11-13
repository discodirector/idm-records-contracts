// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title KeeperOwned — a bot key that acts, and an owner who can replace it
/// @notice The keeper (a server key) runs the contract's one money action, inside a price band the owner sets in the
///         contract itself. The owner (a hardware wallet or a Safe) can only replace the keeper, move that band and
///         hand ownership on, in two steps. A dead or leaked bot key is
///         replaced; nobody else is ever let in.
abstract contract KeeperOwned {
    address public owner;
    address public pendingOwner;
    address public keeper;

    event KeeperSet(address keeper);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotKeeper();
    error ZeroAddress();

    constructor(address owner_, address keeper_) {
        if (owner_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        owner = owner_;
        keeper = keeper_;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperSet(keeper_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    /// @notice A new keeper key (the old one died or leaked).
    function setKeeper(address k) external onlyOwner {
        if (k == address(0)) revert ZeroAddress();
        keeper = k;
        emit KeeperSet(k);
    }

    /// @notice Starts a handover; the zero address cancels one.
    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}
