// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ERC-20 surface the reward pot needs (USDG on Robinhood Chain).
interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice The $IDM balance read at mint.
interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @notice ERC721-C (Limit Break creator token standards): the surface marketplaces read to find the collection's
///         transfer validator. Interface id 0xad0d7f6c.
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
    function setTransferValidator(address validator) external;
}

/// @notice The older ERC721-C surface (no getTransferValidationFunction), still answered. Interface id 0xa07d229a.
interface ICreatorTokenLegacy {
    function getTransferValidator() external view returns (address validator);
    function setTransferValidator(address validator) external;
}

/// @notice ERC721-C transfer validator (Limit Break's Creator Token Transfer Validator).
interface ITransferValidator {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}

/// @notice Limit Break's validators keep each collection's token type (721 here); other validators may lack it.
interface ITransferValidatorSetTokenType {
    function setTokenTypeOfCollection(address collection, uint16 tokenType) external;
}

/// @title IDMRecords
/// @notice IDM Records: each finished station track is one NFT, one of one. Token id = the label's global catalog
///         number (1…1000). The art is drawn from the track's own data (packages/stations-art), so it exists before
///         the mint and no minter shapes it. Minting is free (gas only) and happens in drops, by vouchers the
///         label's server signs (the signer key holds no funds). Only the voucher's `to` may submit it, from its
///         own wallet (an EOA, an EIP-7702 wallet or a contract wallet such as a Safe): nobody can mint into another
///         wallet or use up its mint.
///
///         Reward pot (USDG): the label's money paid on Robinhood (royalties, the Stations holders' quarter) arrives
///         here through RewardFeeder.
///         - `depositPool(amount)` is shared by every token minted at that moment; a later mint gets none of it.
///         - `deposit(ids, amounts)` credits a track from the caller's own tokens (anyone may gift one). A track that is
///           not minted yet keeps its credit; its first minter gets it. The label's per-track sale credits are paid on
///           Base (HolderRewards), not here.
///         - `claim(ids)` pays each token's rewards to its current holder. Only the holder, or an operator it approved
///           for all its tokens, may call it: a contract holder (an escrow, a vault) is never paid tokens it cannot
///           move. A transfer that fails (a frozen address) leaves that token's rewards on it and the rest of the batch
///           goes on. Unclaimed rewards move with the NFT.
///
///         Holding at mint: a voucher carries `minHold`, and `mint` checks that `to` holds at least that much $IDM
///         (`holdToken`) at that moment, on top of the holding rules the server checked before signing.
///
///         Royalty: ERC-2981 (receiver and bps), enforced by an ERC721-C transfer validator once one is set
///         (`getTransferValidator`, ICreatorToken). Mints and claims never call the validator. What the validator
///         allows is set on the validator, not here: Limit Break's v5 keeps the collection's ruleset, options and
///         lists under this contract's address, changed by its `owner()`. `lockTransferValidator` fixes only which
///         validator is asked; the rules on it stay with the owner (and list 0 with Limit Break). With the
///         deploy's options 6 (owner decision 2026-11-04: Safe and EIP-7702 wallets may move their own records),
///         any contract that holds a record (an escrow, a wrapper, a contract wallet) can move it itself, so a sale
///         through such a contract pays no royalty. Sales on listed marketplaces (Payment Processor, OpenSea through
///         its SignedZone) still pay it, and an unlisted marketplace acting as an approved operator is still refused.
///         docs/DEPLOY.md section 10.
///
///         Trust: the signer key can mint every unminted track (to any wallet), and the owner can name a new signer,
///         so the owner can too, but only in the open: a new signer takes effect `SIGNER_DELAY` (48 h) after the owner
///         proposes it (`setSigner`, then `activateSigner` within `SIGNER_WINDOW`, 7 days, after that; later the
///         proposal lapses). If the signer key leaks, `revokeSigner` stops every voucher at once. The owner also sets
///         the metadata base URI (until frozen), the royalty (≤ 10%) and the transfer validator (until locked).
///         Nobody can touch the reward pot.
contract IDMRecords is ICreatorToken {
    // ---------------------------------------------------------------- constants

    uint256 public constant MAX_SUPPLY = 1000;
    uint96 public constant MAX_ROYALTY_BPS = 1000;
    /// @notice A new voucher signer works this long after the owner proposed it.
    uint64 public constant SIGNER_DELAY = 48 hours;
    /// @notice ...and must be activated within this long after that, or the proposal lapses (propose again).
    uint64 public constant SIGNER_WINDOW = 7 days;
    uint256 private constant PRECISION = 1e18;
    /// @dev Limit Break's token type for ERC-721 collections (validator's setTokenTypeOfCollection).
    uint16 private constant TOKEN_TYPE_ERC721 = 721;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(address to,uint256 tokenId,bytes32 metadataHash,uint32 dropId,uint32 walletLimit,uint64 deadline,uint256 minHold)"
    );

    struct Voucher {
        address to;
        uint256 tokenId;
        /// @dev SHA-256 of the record's track.json as published (identity, facts, trace, the audio's SHA-256 and
        ///      the art generator version; no URLs, so the media can move hosts), kept onchain as provenance.
        bytes32 metadataHash;
        uint32 dropId;
        /// @dev Most tokens one wallet may mint in this drop.
        uint32 walletLimit;
        uint64 deadline;
        /// @dev Least `holdToken` balance (token units, 18 decimals for $IDM) `to` must have at the mint; 0 = no check.
        uint256 minHold;
    }

    // ---------------------------------------------------------------- ERC-721 state

    string public name;
    string public symbol;
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _approved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    uint256 public totalSupply;

    // ---------------------------------------------------------------- label state

    address public owner;
    address public pendingOwner;
    /// @notice Signs vouchers; zero = revoked (no mint until a new signer is activated).
    address public signer;
    /// @notice The signer the owner proposed, and when it may be activated (0 = none).
    address public pendingSigner;
    uint64 public pendingSignerAt;
    string public baseURI;
    bool public metadataFrozen;
    address public royaltyReceiver;
    uint96 public royaltyBps;
    address public transferValidator;
    bool public validatorLocked;

    mapping(uint256 => bytes32) public metadataHash;
    mapping(uint256 => mapping(address => uint256)) public mintedInDrop;

    // ---------------------------------------------------------------- reward pot

    IERC20Like public immutable rewardToken;
    /// @notice The token `minHold` is counted in: $IDM.
    IBalanceOf public immutable holdToken;
    bytes32 private immutable _domainSeparator;
    uint256 private immutable _chainId;

    /// @notice Per-track credits not yet claimed (minted or not).
    mapping(uint256 => uint256) public trackCredit;
    /// @notice Pool rewards per minted token, scaled by 1e18.
    uint256 public poolPerToken;
    /// @dev poolPerToken a token was last settled at (its mint, or its last claim).
    mapping(uint256 => uint256) private _poolDebt;
    /// @dev Scaled remainder of the last pool deposit, carried into the next one.
    uint256 private _poolRemainder;

    // ---------------------------------------------------------------- events / errors

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Minted(uint256 indexed tokenId, address indexed to, uint32 indexed dropId, bytes32 metadataHash);
    event TrackCredited(uint256 indexed tokenId, address indexed from, uint256 amount);
    event PoolDeposited(address indexed from, uint256 amount, uint256 holders);
    event Claimed(uint256 indexed tokenId, address indexed to, uint256 amount);
    event ClaimFailed(uint256 indexed tokenId, address indexed to, uint256 amount);
    event SignerSet(address signer);
    event SignerProposed(address signer, uint64 validFrom);
    event BaseURISet(string baseURI);
    event MetadataFrozen();
    event RoyaltySet(address receiver, uint96 bps);
    event TransferValidatorLocked();
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroAddress();
    error BadSignature();
    error Expired();
    error BadTokenId();
    error AlreadyMinted();
    error WalletLimit();
    error NotMinted();
    error NotAuthorized();
    error WrongFrom();
    error UnsafeRecipient();
    error Frozen();
    error Locked();
    error RoyaltyTooHigh();
    error LengthMismatch();
    error NoHolders();
    error BalanceTooLow();
    error NotAContract();
    error ZeroAmount();
    error TokenTransferFailed();
    error FeeOnTransfer(uint256 received, uint256 amount);
    error NoPendingSigner();
    error TooEarly(uint64 validFrom);
    error Lapsed(uint64 lapsedAt);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address signer_,
        IERC20Like rewardToken_,
        IBalanceOf holdToken_,
        string memory baseURI_,
        address royaltyReceiver_,
        uint96 royaltyBps_
    ) {
        if (
            owner_ == address(0) || signer_ == address(0) || address(rewardToken_) == address(0)
                || address(holdToken_) == address(0)
        ) revert ZeroAddress();
        if (royaltyBps_ > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        if (royaltyBps_ > 0 && royaltyReceiver_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        owner = owner_;
        signer = signer_;
        rewardToken = rewardToken_;
        holdToken = holdToken_;
        baseURI = baseURI_;
        royaltyReceiver = royaltyReceiver_;
        royaltyBps = royaltyBps_;
        _chainId = block.chainid;
        _domainSeparator = _buildDomainSeparator();
        emit OwnershipTransferred(address(0), owner_);
        emit SignerSet(signer_);
    }

    // ---------------------------------------------------------------- mint

    /// @notice Mints `v.tokenId` to `v.to`. Only `v.to` itself may submit: the voucher service signs for any address
    ///         that qualifies, so a voucher anyone could submit would let a stranger spend another wallet's mint for
    ///         the drop (its wallet limit) on a record it did not choose, or mint into a contract that cannot move it.
    function mint(Voucher calldata v, bytes calldata signature) external {
        if (msg.sender != v.to) revert NotAuthorized();
        if (block.timestamp > v.deadline) revert Expired();
        if (v.tokenId == 0 || v.tokenId > MAX_SUPPLY) revert BadTokenId();
        if (v.to == address(0)) revert ZeroAddress();
        if (_ownerOf[v.tokenId] != address(0)) revert AlreadyMinted();
        if (_recover(voucherDigest(v), signature) != signer) revert BadSignature();
        if (++mintedInDrop[v.dropId][v.to] > v.walletLimit) revert WalletLimit();
        // The floor must still be in the wallet when it mints.
        if (v.minHold != 0 && holdToken.balanceOf(v.to) < v.minHold) revert BalanceTooLow();

        metadataHash[v.tokenId] = v.metadataHash;
        _poolDebt[v.tokenId] = poolPerToken;
        unchecked {
            totalSupply++;
            _balanceOf[v.to]++;
        }
        _ownerOf[v.tokenId] = v.to;
        emit Transfer(address(0), v.to, v.tokenId);
        emit Minted(v.tokenId, v.to, v.dropId, v.metadataHash);
    }

    function voucherDigest(Voucher calldata v) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                VOUCHER_TYPEHASH, v.to, v.tokenId, v.metadataHash, v.dropId, v.walletLimit, v.deadline, v.minHold
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _chainId ? _domainSeparator : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256("1"), block.chainid, address(this)));
    }

    /// @dev 65-byte (r, s, v) signatures only; rejects high-s and bad v.
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address signer_) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) revert BadSignature();
        if (v != 27 && v != 28) revert BadSignature();
        signer_ = ecrecover(digest, v, r, s);
        if (signer_ == address(0)) revert BadSignature();
    }

    // ---------------------------------------------------------------- reward pot

    /// @notice Credits tracks with reward tokens pulled from the caller. Works for tokens not minted yet.
    function deposit(uint256[] calldata tokenIds, uint256[] calldata amounts) external {
        if (tokenIds.length != amounts.length) revert LengthMismatch();
        uint256 total;
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (id == 0 || id > MAX_SUPPLY) revert BadTokenId();
            total += amounts[i];
        }
        if (total == 0) revert ZeroAmount();
        // Exact credits need exact money: a token that takes a fee on transfer would credit more than arrived.
        uint256 received = _pull(total);
        if (received != total) revert FeeOnTransfer(received, total);
        for (uint256 i; i < tokenIds.length; ++i) {
            trackCredit[tokenIds[i]] += amounts[i];
            emit TrackCredited(tokenIds[i], msg.sender, amounts[i]);
        }
    }

    /// @notice Shares `amount` (what actually arrives of it) among every token minted now.
    function depositPool(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 holders = totalSupply;
        if (holders == 0) revert NoHolders();
        uint256 received = _pull(amount);
        if (received == 0) revert ZeroAmount();
        uint256 scaled = received * PRECISION + _poolRemainder;
        poolPerToken += scaled / holders;
        _poolRemainder = scaled % holders;
        emit PoolDeposited(msg.sender, received, holders);
    }

    function claimable(uint256 tokenId) public view returns (uint256) {
        if (_ownerOf[tokenId] == address(0)) return 0;
        return trackCredit[tokenId] + (poolPerToken - _poolDebt[tokenId]) / PRECISION;
    }

    /// @notice Pays each token's rewards to its holder. Only the holder, or an operator it approved for all, may
    ///         call: rewards are never pushed to a contract that did not ask (it may be unable to move them). A token
    ///         whose transfer fails keeps its rewards (`ClaimFailed`); the other tokens are still paid.
    function claim(uint256[] calldata tokenIds) external {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            address holder = _ownerOf[id];
            if (holder == address(0)) revert NotMinted();
            if (msg.sender != holder && !isApprovedForAll[holder][msg.sender]) revert NotAuthorized();
            uint256 amount = claimable(id);
            if (amount == 0) continue;
            uint256 credit = trackCredit[id];
            uint256 debt = _poolDebt[id];
            trackCredit[id] = 0;
            // Keep the sub-unit remainder on the token instead of losing it.
            _poolDebt[id] = poolPerToken - (poolPerToken - debt) % PRECISION;
            if (_trySend(holder, amount)) {
                emit Claimed(id, holder, amount);
            } else {
                (trackCredit[id], _poolDebt[id]) = (credit, debt);
                emit ClaimFailed(id, holder, amount);
            }
        }
    }

    /// @dev Pulls `amount` from the caller; returns what actually arrived.
    function _pull(uint256 amount) private returns (uint256 received) {
        uint256 before = rewardToken.balanceOf(address(this));
        (bool ok, bytes memory ret) = address(rewardToken).call(
            abi.encodeCall(IERC20Like.transferFrom, (msg.sender, address(this), amount))
        );
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
        received = rewardToken.balanceOf(address(this)) - before;
    }

    function _trySend(address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = address(rewardToken).call(abi.encodeCall(IERC20Like.transfer, (to, amount)));
        return ok && (ret.length == 0 ? address(rewardToken).code.length != 0 : (ret.length == 32 && abi.decode(ret, (bool))));
    }

    // ---------------------------------------------------------------- ERC-721

    function ownerOf(uint256 id) public view returns (address o) {
        if ((o = _ownerOf[id]) == address(0)) revert NotMinted();
    }

    function balanceOf(address o) external view returns (uint256) {
        if (o == address(0)) revert ZeroAddress();
        return _balanceOf[o];
    }

    /// @notice Reverts for a token not minted (ERC-721).
    function getApproved(uint256 id) external view returns (address) {
        ownerOf(id);
        return _approved[id];
    }

    function approve(address spender, uint256 id) external {
        address o = ownerOf(id);
        if (msg.sender != o && !isApprovedForAll[o][msg.sender]) revert NotAuthorized();
        _approved[id] = spender;
        emit Approval(o, spender, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        if (from != _ownerOf[id]) revert WrongFrom();
        if (to == address(0)) revert ZeroAddress();
        if (msg.sender != from && !isApprovedForAll[from][msg.sender] && msg.sender != _approved[id]) {
            revert NotAuthorized();
        }
        address validator = transferValidator;
        // As in Limit Break's ERC721-C: the validator's own transfers (it needs the holder's approval for them) are
        // checked by the validator itself.
        if (validator != address(0) && msg.sender != validator) {
            ITransferValidator(validator).validateTransfer(msg.sender, from, to, id);
        }
        unchecked {
            _balanceOf[from]--;
            _balanceOf[to]++;
        }
        _ownerOf[id] = to;
        delete _approved[id];
        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (
            to.code.length != 0
                && IERC721Receiver(to).onERC721Received(msg.sender, from, id, data)
                    != IERC721Receiver.onERC721Received.selector
        ) revert UnsafeRecipient();
    }

    /// @notice `<baseURI><id>/metadata.json`: the file the release pipeline writes (packages/stations-art,
    ///         src/records/layout.ts), so a plain copy of the records folder serves it, on a web server or IPFS.
    function tokenURI(uint256 id) external view returns (string memory) {
        ownerOf(id);
        return string.concat(baseURI, _toString(id), "/metadata.json");
    }

    /// @notice ERC-2981.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (royaltyReceiver, salePrice * royaltyBps / 10_000);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 // ERC-165
            || id == 0x80ac58cd // ERC-721
            || id == 0x5b5e139f // ERC-721 Metadata
            || id == 0x2a55205a // ERC-2981
            || id == type(ICreatorToken).interfaceId // 0xad0d7f6c
            || id == type(ICreatorTokenLegacy).interfaceId; // 0xa07d229a
    }

    // ---------------------------------------------------------------- ERC721-C

    /// @notice The contract every transfer is checked by; zero = none (royalties are then not enforced).
    function getTransferValidator() external view returns (address) {
        return transferValidator;
    }

    /// @notice What `transferFrom` calls on the validator: validateTransfer(address,address,address,uint256), a view.
    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        return (ITransferValidator.validateTransfer.selector, true);
    }

    // ---------------------------------------------------------------- owner

    /// @notice Proposes a new voucher signer; `activateSigner` makes it the signer `SIGNER_DELAY` later, within
    ///         `SIGNER_WINDOW` after that (a proposal nobody activated in time lapses, so an old one cannot be
    ///         activated quietly months later). A second proposal replaces the first and restarts the wait.
    function setSigner(address s) external onlyOwner {
        if (s == address(0)) revert ZeroAddress();
        uint64 at = uint64(block.timestamp) + SIGNER_DELAY;
        (pendingSigner, pendingSignerAt) = (s, at);
        emit SignerProposed(s, at);
    }

    function activateSigner() external onlyOwner {
        address s = pendingSigner;
        if (s == address(0)) revert NoPendingSigner();
        uint64 at = pendingSignerAt;
        if (block.timestamp < at) revert TooEarly(at);
        if (block.timestamp > at + SIGNER_WINDOW) revert Lapsed(at + SIGNER_WINDOW);
        signer = s;
        (pendingSigner, pendingSignerAt) = (address(0), 0);
        emit SignerSet(s);
    }

    /// @notice Drops a proposed signer before it is activated, or a lapsed proposal.
    function cancelSigner() external onlyOwner {
        if (pendingSigner == address(0)) revert NoPendingSigner();
        (pendingSigner, pendingSignerAt) = (address(0), 0);
        emit SignerProposed(address(0), 0);
    }

    /// @notice Stops every voucher at once (a leaked signer key); a proposed signer, if any, stays proposed.
    function revokeSigner() external onlyOwner {
        signer = address(0);
        emit SignerSet(address(0));
    }

    function setBaseURI(string calldata uri) external onlyOwner {
        if (metadataFrozen) revert Frozen();
        baseURI = uri;
        emit BaseURISet(uri);
    }

    function freezeMetadata() external onlyOwner {
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        if (bps > 0 && receiver == address(0)) revert ZeroAddress();
        royaltyReceiver = receiver;
        royaltyBps = bps;
        emit RoyaltySet(receiver, bps);
    }

    /// @notice Zero turns enforcement off. A validator must be a contract: a wallet address would block every transfer.
    function setTransferValidator(address validator) external onlyOwner {
        if (validatorLocked) revert Locked();
        if (validator != address(0) && validator.code.length == 0) revert NotAContract();
        emit TransferValidatorUpdated(transferValidator, validator);
        transferValidator = validator;
        if (validator != address(0)) {
            // Registers the collection as ERC-721 with Limit Break's validator, as ERC721-C does; ignored elsewhere.
            try ITransferValidatorSetTokenType(validator).setTokenTypeOfCollection(address(this), TOKEN_TYPE_ERC721) {}
                catch {}
        }
    }

    /// @notice Fixes the validator address for good. It does not fix the validator's rules for this collection
    ///         (ruleset, options, lists): those stay changeable by `owner()` on the validator, and Limit Break edits
    ///         list 0. So a lock does not freeze royalty enforcement as it is.
    function lockTransferValidator() external onlyOwner {
        validatorLocked = true;
        emit TransferValidatorLocked();
    }

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

    // ---------------------------------------------------------------- utils

    function _toString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) ++len;
        bytes memory b = new bytes(len);
        while (v != 0) {
            b[--len] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(b);
    }
}
