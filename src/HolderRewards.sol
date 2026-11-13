// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Rewards {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title HolderRewards — IDM Records holders' rewards on Base, in USDC
/// @notice The NFTs live on Robinhood Chain; the label's x402 money arrives here on Base (owner decision 2026-11-04:
///         holders are paid on Base, no bridge). Base cannot read who holds a record, so a keeper posts a Merkle root
///         of every minted token's CUMULATIVE rewards and the address that may receive them, computed off-chain from
///         Robinhood ownership, the sale log and the same pot rules as IDMRecords (docs/HOLDER-REWARDS.md):
///         - a track's own sales credit that track (a credit waits for its first minter);
///         - the rest (packs, Stations' holders quarter, anything else sent here) is shared by every token minted at
///           that moment;
///         - rewards belong to the token: what is not claimed moves with the NFT to its next holder.
///
///         Leaf: (tokenId, account, pushable, cumulative). `claim` pays `cumulative - claimed[tokenId]` to `account`.
///         `pushable` leaves (the holder is a plain wallet on Robinhood, whose key also controls the address on Base)
///         may be claimed by anyone for the account, so a bot can pay holders without them sending a transaction,
///         as long as the account has no code on Base. Other leaves (the holder is a contract there: a Safe, an
///         escrow, a marketplace), and accounts with code on Base, only by `account` itself.
///
///         What the keeper cannot do: pay out more than arrived. A root carries the sum of its leaves (`total`); a
///         root above the USDC ever received (balance + everything claimed) is refused, and claims stop at `total`.
///         A bad root could misdirect money but never overdraw; a root that gives a token less than it already took
///         leaves the others' claims paid in part up to `total`, the rest owed until a corrected root. Totals only grow, root to root. Every root waits
///         `rootDelay` (at least 1 h) before it pays, and the owner or the guardian (a watcher's key that can only
///         revoke) can revoke it in that time. The keeper cannot revoke: a revoke and a new root under the same epoch
///         number is how a leaked keeper key would swap an honest root for its own. The owner can rotate the keeper
///         and the guardian and nothing else: there is no withdrawal, no admin transfer of funds, no upgrade.
///
///         Only USDC counts. Anything else that lands here (ETH or another token, e.g. a splitter's release of
///         something that is not USDC) is swept by the keeper to `sweepTo`, the infra wallet fixed at deploy.
contract HolderRewards {
    struct Root {
        bytes32 root;
        /// @dev Sum of every leaf's cumulative amount.
        uint128 total;
        /// @dev 1, 2, 3... one per active root.
        uint32 epoch;
        /// @dev Claims use this root from this time on.
        uint64 validFrom;
        /// @dev SHA-256 of the published epoch file (inputs, leaves, state), so anyone can check what was posted.
        bytes32 dataHash;
    }

    struct Claim {
        uint256 tokenId;
        address account;
        bool pushable;
        uint256 cumulative;
        bytes32[] proof;
    }

    uint64 public constant MIN_ROOT_DELAY = 1 hours;
    uint64 public constant MAX_ROOT_DELAY = 7 days;

    IERC20Rewards public immutable usdc;
    uint64 public immutable rootDelay;
    /// @notice Where `sweep` sends ETH and tokens other than USDC (infra). Fixed at deploy.
    address public immutable sweepTo;

    address public owner;
    address public pendingOwner;
    address public keeper;
    /// @notice May revoke a pending root, nothing else (zero = none). Never the keeper.
    address public guardian;

    Root private _current;
    Root private _pending;

    /// @notice Paid out so far, all tokens.
    uint256 public totalClaimed;
    /// @notice Cumulative amount already paid for each token (to whoever held it).
    mapping(uint256 => uint256) public claimed;

    event RootProposed(uint32 indexed epoch, bytes32 root, uint256 total, bytes32 dataHash, uint64 validFrom);
    event RootActivated(uint32 indexed epoch, bytes32 root, uint256 total);
    event RootRevoked(uint32 indexed epoch, bytes32 root, address by);
    /// @dev `cumulative`: what the token has been paid in all, after this claim.
    event Claimed(uint256 indexed tokenId, address indexed account, uint256 amount, uint256 cumulative);
    /// @dev A batch skipped this leaf: its account may not be pushed to, or its USDC transfer failed. Still owed.
    event ClaimFailed(uint256 indexed tokenId, address indexed account, uint256 amount);
    event KeeperSet(address keeper);
    event GuardianSet(address guardian);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotKeeper();
    error NotRevoker();
    error KeeperIsGuardian();
    error NotSweepable();
    error ZeroAddress();
    error BadDelay();
    error BadRoot();
    error BadEpoch(uint32 expected);
    error TotalDecreased(uint256 total, uint256 current);
    error RootPending();
    error NoPendingRoot();
    error OverReceived(uint256 total, uint256 received);
    error NotAccount();
    error BadProof();
    error TransferFailed();

    constructor(
        IERC20Rewards usdc_,
        address owner_,
        address keeper_,
        address guardian_,
        uint64 rootDelay_,
        address sweepTo_
    ) {
        if (address(usdc_) == address(0) || owner_ == address(0) || keeper_ == address(0) || sweepTo_ == address(0)) {
            revert ZeroAddress();
        }
        if (guardian_ == keeper_) revert KeeperIsGuardian();
        if (rootDelay_ < MIN_ROOT_DELAY || rootDelay_ > MAX_ROOT_DELAY) revert BadDelay();
        usdc = usdc_;
        owner = owner_;
        keeper = keeper_;
        guardian = guardian_;
        rootDelay = rootDelay_;
        sweepTo = sweepTo_;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperSet(keeper_);
        emit GuardianSet(guardian_);
    }

    /// @notice ETH is accepted (a splitter's ETH release must not revert) and only ever swept to `sweepTo`.
    receive() external payable {}

    // ---------------------------------------------------------------- roots

    /// @notice The root claims use now (a pending root counts once its delay has passed).
    function currentRoot() public view returns (Root memory) {
        return _matured() ? _pending : _current;
    }

    /// @notice The root waiting for its delay, if any (zero root = none).
    function pendingRoot() external view returns (Root memory r) {
        if (!_matured()) r = _pending;
    }

    /// @notice USDC that ever arrived here: what is held plus what was paid out.
    function received() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + totalClaimed;
    }

    /// @notice Posts the next root; it pays from `block.timestamp + rootDelay`. One pending root at a time.
    function proposeRoot(uint32 epoch, bytes32 root, uint256 total, bytes32 dataHash) external {
        if (msg.sender != keeper) revert NotKeeper();
        _activate();
        if (_pending.root != bytes32(0)) revert RootPending();
        if (root == bytes32(0)) revert BadRoot();
        if (epoch != _current.epoch + 1) revert BadEpoch(_current.epoch + 1);
        // Cumulative: a root never promises less than the one before (so never less than what was paid out).
        if (total < _current.total) revert TotalDecreased(total, _current.total);
        uint256 got = received();
        if (total > got) revert OverReceived(total, got);
        uint64 validFrom = uint64(block.timestamp) + rootDelay;
        // total <= received <= USDC supply, far below 2^128.
        _pending = Root(root, uint128(total), epoch, validFrom, dataHash);
        emit RootProposed(epoch, root, total, dataHash, validFrom);
    }

    /// @notice Drops the pending root before it pays. Owner or guardian, never the keeper.
    function revokePending() external {
        if (msg.sender != owner && (msg.sender != guardian || guardian == address(0))) revert NotRevoker();
        _activate();
        if (_pending.root == bytes32(0)) revert NoPendingRoot();
        emit RootRevoked(_pending.epoch, _pending.root, msg.sender);
        delete _pending;
    }

    function _matured() private view returns (bool) {
        return _pending.root != bytes32(0) && block.timestamp >= _pending.validFrom;
    }

    function _activate() private {
        if (!_matured()) return;
        _current = _pending;
        delete _pending;
        emit RootActivated(_current.epoch, _current.root, _current.total);
    }

    // ---------------------------------------------------------------- claims

    /// @notice Pays a token's unclaimed rewards to the account the current root names for it. Anyone may push a
    ///         `pushable` leaf for a plain account; an account with code on Base (a contract, an escrow, a delegated
    ///         EIP-7702 wallet) is only paid when it claims itself, so USDC is never pushed into a contract that may
    ///         not move it (audit 2026-11-13, as IDMRecords.claim). When an earlier claim took more than a later root
    ///         gives that token (a keeper mistake), the root's total cannot cover every leaf: a claim pays what the
    ///         total still covers and the rest stays owed to the token, so one bad leaf never stops the others.
    /// @return amount Paid now (0 when nothing new).
    function claim(uint256 tokenId, address account, bool pushable, uint256 cumulative, bytes32[] calldata proof)
        public
        returns (uint256 amount)
    {
        _activate();
        if (msg.sender != account && (!pushable || account.code.length != 0)) revert NotAccount();
        amount = _owed(tokenId, account, pushable, cumulative, proof);
        if (amount == 0) return 0;
        _book(tokenId, amount);
        if (!_send(account, amount)) revert TransferFailed();
        emit Claimed(tokenId, account, amount, claimed[tokenId]);
    }

    /// @notice Pushes many claims. A leaf this call may not push (its account has code or is not pushable) or whose
    ///         USDC transfer fails (a frozen account, a paused token) is skipped with `ClaimFailed` and keeps its
    ///         rewards; the others are still paid. A bad proof still reverts the whole batch.
    function claimMany(Claim[] calldata claims) external returns (uint256 total) {
        _activate();
        for (uint256 i; i < claims.length; ++i) {
            Claim calldata c = claims[i];
            uint256 amount = _owed(c.tokenId, c.account, c.pushable, c.cumulative, c.proof);
            if (amount == 0) continue;
            if (msg.sender != c.account && (!c.pushable || c.account.code.length != 0)) {
                emit ClaimFailed(c.tokenId, c.account, amount);
                continue;
            }
            _book(c.tokenId, amount);
            if (!_send(c.account, amount)) {
                claimed[c.tokenId] -= amount;
                totalClaimed -= amount;
                emit ClaimFailed(c.tokenId, c.account, amount);
                continue;
            }
            emit Claimed(c.tokenId, c.account, amount, claimed[c.tokenId]);
            total += amount;
        }
    }

    /// @dev What a valid leaf of the current root may be paid now: its unclaimed part, at most what the root's total
    ///      still covers. Reverts on a bad proof.
    function _owed(uint256 tokenId, address account, bool pushable, uint256 cumulative, bytes32[] calldata proof)
        private
        view
        returns (uint256 amount)
    {
        Root storage r = _current;
        if (!_verify(proof, r.root, leaf(tokenId, account, pushable, cumulative))) revert BadProof();
        uint256 done = claimed[tokenId];
        if (cumulative <= done) return 0;
        amount = cumulative - done;
        // Totals never decrease root to root, so totalClaimed <= r.total.
        uint256 left = r.total - totalClaimed;
        if (amount > left) amount = left;
    }

    function _book(uint256 tokenId, uint256 amount) private {
        claimed[tokenId] += amount;
        totalClaimed += amount;
    }

    /// @notice The leaf hash, as the keeper builds it (OpenZeppelin StandardMerkleTree style: double keccak of the
    ///         ABI encoding, sorted pairs above it).
    function leaf(uint256 tokenId, address account, bool pushable, uint256 cumulative) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(tokenId, account, pushable, cumulative))));
    }

    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 h) private pure returns (bool) {
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            (bytes32 a, bytes32 b) = h < p ? (h, p) : (p, h);
            assembly ("memory-safe") {
                mstore(0x00, a)
                mstore(0x20, b)
                h := keccak256(0x00, 0x40)
            }
        }
        return root != bytes32(0) && h == root;
    }

    /// @notice Sends the whole balance of `token` (address 0 = ETH), anything but USDC, to `sweepTo`. Keeper only.
    function sweep(address token) external returns (uint256 amount) {
        if (msg.sender != keeper) revert NotKeeper();
        if (token == address(usdc)) revert NotSweepable();
        if (token == address(0)) {
            amount = address(this).balance;
            (bool ok,) = sweepTo.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            amount = IERC20Rewards(token).balanceOf(address(this));
            (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Rewards.transfer, (sweepTo, amount)));
            if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
        }
        emit Swept(token, sweepTo, amount);
    }

    /// @dev A USDC transfer; false when it reverts or returns false (nothing is sent then).
    function _send(address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(usdc).call(abi.encodeCall(IERC20Rewards.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
    }

    // ---------------------------------------------------------------- owner

    /// @notice A new keeper (the old key leaked or was lost). Drops the pending root, which the old key posted.
    function setKeeper(address k) external {
        if (msg.sender != owner) revert NotOwner();
        if (k == address(0)) revert ZeroAddress();
        if (k == guardian) revert KeeperIsGuardian();
        _activate();
        if (_pending.root != bytes32(0)) {
            emit RootRevoked(_pending.epoch, _pending.root, msg.sender);
            delete _pending;
        }
        keeper = k;
        emit KeeperSet(k);
    }

    /// @notice The watcher's revoke-only key (zero = none).
    function setGuardian(address g) external {
        if (msg.sender != owner) revert NotOwner();
        if (g == keeper) revert KeeperIsGuardian();
        guardian = g;
        emit GuardianSet(g);
    }

    function transferOwnership(address to) external {
        if (msg.sender != owner) revert NotOwner();
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
