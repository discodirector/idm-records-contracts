// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IDMRecords, IERC20Like, IBalanceOf, ICreatorToken} from "../src/IDMRecords.sol";

/// @dev 6-decimal stablecoin stand-in (USDG).
contract MockUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external virtual returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external virtual returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// A stablecoin that can freeze an address (USDG is a Paxos token with a freeze list).
contract FreezableUSD is MockUSD {
    mapping(address => bool) public frozen;

    function freeze(address a, bool on) external {
        frozen[a] = on;
    }

    function transfer(address to, uint256 a) external override returns (bool) {
        require(!frozen[to] && !frozen[msg.sender], "frozen");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// A token that keeps 1% of every transferFrom.
contract FeeUSD is MockUSD {
    function transferFrom(address f, address to, uint256 a) external override returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a - a / 100;
        return true;
    }
}

/// A marketplace or lending escrow that holds records and knows nothing of USDG.
contract Escrow {}

contract Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract NotReceiver {}

contract BlockAll {
    function validateTransfer(address, address, address, uint256) external pure {
        revert("blocked");
    }
}

/// Lets transfers by the token's owner or by one marketplace through, as an ERC721-C validator's whitelist does, and
/// records the token type the collection registers.
contract OwnerOrMarket {
    address public market;
    mapping(address => uint16) public tokenTypeOf;

    constructor(address market_) {
        market = market_;
    }

    function validateTransfer(address caller, address from, address, uint256) external view {
        require(caller == from || caller == market, "not allowed");
    }

    function setTokenTypeOfCollection(address collection, uint16 tokenType) external {
        require(msg.sender == collection, "only the collection");
        tokenTypeOf[collection] = tokenType;
    }
}

contract IDMRecordsTest is Test {
    IDMRecords nft;
    MockUSD usd;
    /// $IDM stand-in, etched at the real $IDM address so it takes no deploy nonce (the pinned contract address holds).
    MockUSD idm = MockUSD(0x4Fe9f3823791c8b187B81aB8B7398d793FEd28f6);
    address owner = makeAddr("owner");
    uint256 signerKey = 0xA11CE;
    address signer;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address label = makeAddr("label");
    address royalty = makeAddr("royalty");

    function setUp() public {
        signer = vm.addr(signerKey);
        usd = new MockUSD();
        vm.etch(address(idm), type(MockUSD).runtimeCode);
        nft = new IDMRecords(
            "IDM Records", "RECORDS", owner, signer, IERC20Like(address(usd)), IBalanceOf(address(idm)), "https://theidm.fun/nft/", royalty, 500
        );
        usd.mint(label, 1_000_000e6);
        vm.prank(label);
        usd.approve(address(nft), type(uint256).max);
    }

    /// The bot's signer (bot/src/records/voucher.ts) signed this voucher with signerKey for this test's contract
    /// address and chain; bot/test/records.test.ts pins the same digest and signature. Both sides must agree.
    function test_TsSignedVoucher() public {
        assertEq(address(nft), 0x2e234DAe75C793f67A35089C9d99245E1C58470b);
        assertEq(block.chainid, 31337);
        IDMRecords.Voucher memory v = IDMRecords.Voucher(
            0x1111111111111111111111111111111111111111,
            42,
            0x1b7a2881a8d77059b710339d014008c2f24b5a4d5f12050059b47081639e91bb,
            3,
            1,
            2000000000,
            1_000_000e18
        );
        assertEq(nft.voucherDigest(v), 0x08531115b013b80a361b4d3f0d558648b98d7e65917c5c585fb16ba8a6e3e1ce);
        idm.mint(v.to, 1_000_000e18);
        _submit(
            v,
            hex"a6f3c5146c2174ce5eeeaf8b2ccf16318a248eb8d83e22322f3d0362b4550f5a5d3546e3610f827e73d00f2cdec5a003dacdd7b88f7af4be4a9de6b5e5dbaca81c"
        );
        assertEq(nft.ownerOf(42), v.to);
    }

    // ---------------------------------------------------------------- helpers

    function _voucher(address to, uint256 id, uint32 drop, uint32 limit) internal view returns (IDMRecords.Voucher memory) {
        return IDMRecords.Voucher(to, id, keccak256(abi.encode("track", id)), drop, limit, uint64(block.timestamp + 1 days), 0);
    }

    function _sign(IDMRecords.Voucher memory v, uint256 key) internal view returns (bytes memory) {
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(key, nft.voucherDigest(v));
        return abi.encodePacked(r, s, vv);
    }

    /// @dev Submits a voucher from its own wallet (`to`), the only sender the contract accepts.
    function _submit(IDMRecords.Voucher memory v, bytes memory sig) internal {
        vm.prank(v.to);
        nft.mint(v, sig);
    }

    function _mint(address to, uint256 id) internal {
        IDMRecords.Voucher memory v = _voucher(to, id, 1, 100);
        _submit(v, _sign(v, signerKey));
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _amts(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    // ---------------------------------------------------------------- mint

    function test_mint_goesToVoucherTo() public {
        IDMRecords.Voucher memory v = _voucher(alice, 7, 1, 1);
        _submit(v, _sign(v, signerKey));
        assertEq(nft.ownerOf(7), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalSupply(), 1);
        assertEq(nft.metadataHash(7), v.metadataHash);
        assertEq(nft.tokenURI(7), "https://theidm.fun/nft/7/metadata.json");
    }

    /// Audit 2026-11-13 (F1): a stranger with a valid voucher for someone else's wallet cannot submit it, so it can
    /// neither use up that wallet's mint for the drop nor push a record into a contract that cannot move it.
    function test_mint_onlyByVoucherTo() public {
        IDMRecords.Voucher memory v = _voucher(alice, 7, 1, 1);
        bytes memory sig = _sign(v, signerKey);
        vm.prank(bob);
        vm.expectRevert(IDMRecords.NotAuthorized.selector);
        nft.mint(v, sig);
        // The owner and the label cannot submit it either.
        vm.prank(owner);
        vm.expectRevert(IDMRecords.NotAuthorized.selector);
        nft.mint(v, sig);
        assertEq(nft.mintedInDrop(1, alice), 0);
        // Alice's own mint still works: nothing was used up.
        _submit(v, sig);
        assertEq(nft.ownerOf(7), alice);
    }

    /// A contract wallet (a Safe, a 7702 wallet) mints by calling from itself.
    function test_mint_contractWalletMintsForItself() public {
        Submitter w = new Submitter(nft);
        IDMRecords.Voucher memory v = _voucher(address(w), 9, 1, 1);
        w.submit(v, _sign(v, signerKey));
        assertEq(nft.ownerOf(9), address(w));
    }

    function test_mint_rejectsWrongSigner() public {
        IDMRecords.Voucher memory v = _voucher(alice, 1, 1, 1);
        bytes memory sig = _sign(v, 0xB0B);
        vm.expectRevert(IDMRecords.BadSignature.selector);
        _submit(v, sig);
    }

    function test_mint_rejectsTamperedVoucher() public {
        IDMRecords.Voucher memory v = _voucher(alice, 1, 1, 1);
        bytes memory sig = _sign(v, signerKey);
        v.to = bob;
        vm.expectRevert(IDMRecords.BadSignature.selector);
        _submit(v, sig);
    }

    function test_mint_rejectsExpired() public {
        IDMRecords.Voucher memory v = _voucher(alice, 1, 1, 1);
        bytes memory sig = _sign(v, signerKey);
        vm.warp(v.deadline + 1);
        vm.expectRevert(IDMRecords.Expired.selector);
        _submit(v, sig);
    }

    function test_mint_rejectsIdOutOfRange() public {
        IDMRecords.Voucher memory v0 = _voucher(alice, 0, 1, 1);
        bytes memory s0 = _sign(v0, signerKey);
        vm.expectRevert(IDMRecords.BadTokenId.selector);
        _submit(v0, s0);
        IDMRecords.Voucher memory v = _voucher(alice, 1001, 1, 1);
        bytes memory s = _sign(v, signerKey);
        vm.expectRevert(IDMRecords.BadTokenId.selector);
        _submit(v, s);
        _mint(alice, 1000); // the cap itself is fine
        assertEq(nft.ownerOf(1000), alice);
    }

    function test_mint_firstComeFirstServed() public {
        IDMRecords.Voucher memory va = _voucher(alice, 5, 1, 1);
        IDMRecords.Voucher memory vb = _voucher(bob, 5, 1, 1);
        bytes memory sa = _sign(va, signerKey);
        bytes memory sb = _sign(vb, signerKey);
        _submit(vb, sb);
        vm.expectRevert(IDMRecords.AlreadyMinted.selector);
        _submit(va, sa);
    }

    function test_mint_walletLimitPerDrop() public {
        IDMRecords.Voucher memory v1 = _voucher(alice, 1, 3, 1);
        IDMRecords.Voucher memory v2 = _voucher(alice, 2, 3, 1);
        IDMRecords.Voucher memory v3 = _voucher(alice, 2, 4, 1); // next drop
        bytes memory s1 = _sign(v1, signerKey);
        bytes memory s2 = _sign(v2, signerKey);
        bytes memory s3 = _sign(v3, signerKey);
        _submit(v1, s1);
        vm.expectRevert(IDMRecords.WalletLimit.selector);
        _submit(v2, s2);
        _submit(v3, s3);
        assertEq(nft.mintedInDrop(3, alice), 1);
        assertEq(nft.mintedInDrop(4, alice), 1);
    }

    function test_mint_rejectsHighS() public {
        IDMRecords.Voucher memory v = _voucher(alice, 1, 1, 1);
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(signerKey, nft.voucherDigest(v));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory flipped = abi.encodePacked(r, bytes32(n - uint256(s)), vv == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(IDMRecords.BadSignature.selector);
        _submit(v, flipped);
    }

    // ---------------------------------------------------------------- $IDM held at mint

    function _holdVoucher(address to, uint256 id, uint256 minHold) internal view returns (IDMRecords.Voucher memory v) {
        v = _voucher(to, id, 1, 1);
        v.minHold = minHold;
    }

    function test_mint_checksBalanceAtMint() public {
        IDMRecords.Voucher memory v = _holdVoucher(alice, 1, 1_000_000e18);
        bytes memory sig = _sign(v, signerKey);
        idm.mint(alice, 1_000_000e18 - 1);
        vm.expectRevert(IDMRecords.BalanceTooLow.selector);
        _submit(v, sig);
        idm.mint(alice, 1);
        _submit(v, sig); // exactly the minimum is enough
        assertEq(nft.ownerOf(1), alice);
    }

    /// The voucher was signed while the wallet held enough; it sold before the mint landed.
    function test_mint_soldAfterVoucher_reverts() public {
        idm.mint(alice, 2_000_000e18);
        IDMRecords.Voucher memory v = _holdVoucher(alice, 1, 1_000_000e18);
        bytes memory sig = _sign(v, signerKey);
        vm.prank(alice);
        idm.transfer(bob, 1_500_000e18);
        vm.expectRevert(IDMRecords.BalanceTooLow.selector);
        _submit(v, sig);
        assertEq(nft.mintedInDrop(1, alice), 0); // the revert undid the count
    }

    function test_mint_minHoldZero_noBalanceRead() public {
        vm.etch(address(idm), hex"fe"); // any balanceOf call would revert
        IDMRecords.Voucher memory v = _holdVoucher(alice, 1, 0);
        _submit(v, _sign(v, signerKey));
        assertEq(nft.ownerOf(1), alice);
    }

    function test_mint_minHoldIsSigned() public {
        IDMRecords.Voucher memory v = _holdVoucher(alice, 1, 1_000_000e18);
        bytes memory sig = _sign(v, signerKey);
        v.minHold = 0;
        vm.expectRevert(IDMRecords.BadSignature.selector);
        _submit(v, sig);
    }

    function test_holdTokenRequired() public {
        vm.expectRevert(IDMRecords.ZeroAddress.selector);
        new IDMRecords("IDM Records", "RECORDS", owner, signer, IERC20Like(address(usd)), IBalanceOf(address(0)), "", royalty, 500);
    }

    function test_signerRotation_waits48h() public {
        IDMRecords.Voucher memory v = _voucher(alice, 1, 1, 1);
        v.deadline = uint64(block.timestamp + 10 days);
        bytes memory sig = _sign(v, signerKey);
        bytes memory newSig = _sign(v, 0xB0B);
        vm.prank(owner);
        nft.setSigner(vm.addr(0xB0B));
        assertEq(nft.pendingSigner(), vm.addr(0xB0B));
        assertEq(nft.pendingSignerAt(), block.timestamp + 48 hours);
        assertEq(nft.signer(), signer); // nothing changes yet: the old signer still signs, the new one not yet
        vm.expectRevert(IDMRecords.BadSignature.selector);
        _submit(v, newSig);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IDMRecords.TooEarly.selector, uint64(block.timestamp + 48 hours)));
        nft.activateSigner();

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(alice);
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.activateSigner();
        vm.prank(owner);
        nft.activateSigner();
        assertEq(nft.signer(), vm.addr(0xB0B));
        assertEq(nft.pendingSigner(), address(0));
        vm.expectRevert(IDMRecords.BadSignature.selector);
        _submit(v, sig);
        _submit(v, newSig);
        vm.prank(owner);
        vm.expectRevert(IDMRecords.NoPendingSigner.selector);
        nft.activateSigner();
    }

    function test_signerProposal_lapsesAfterTheWindow() public {
        address next = vm.addr(0xB0B);
        vm.prank(owner);
        nft.setSigner(next);
        uint64 at = nft.pendingSignerAt();
        assertEq(nft.SIGNER_WINDOW(), 7 days);

        // Activatable from `at` up to and including `at + SIGNER_WINDOW`; one second later it has lapsed.
        vm.warp(at + 7 days + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IDMRecords.Lapsed.selector, at + 7 days));
        nft.activateSigner();
        assertEq(nft.signer(), signer);
        assertEq(nft.pendingSigner(), next); // stored, inert: only cancelSigner or a new proposal clears it

        // A new proposal restarts the wait and the window.
        vm.prank(owner);
        nft.setSigner(next);
        uint64 again = nft.pendingSignerAt();
        assertEq(again, uint64(block.timestamp) + 48 hours);
        vm.warp(again + 7 days);
        vm.prank(owner);
        nft.activateSigner(); // the last second of the window still works
        assertEq(nft.signer(), next);

        // cancelSigner clears a lapsed proposal too.
        vm.prank(owner);
        nft.setSigner(signer);
        vm.warp(nft.pendingSignerAt() + 7 days + 1);
        vm.prank(owner);
        vm.expectEmit(address(nft));
        emit IDMRecords.SignerProposed(address(0), 0);
        nft.cancelSigner();
        assertEq(nft.pendingSigner(), address(0));
        assertEq(nft.pendingSignerAt(), 0);
    }

    function test_revokeSigner_stopsVouchersAtOnce() public {
        IDMRecords.Voucher memory v = _voucher(alice, 1, 1, 1);
        bytes memory sig = _sign(v, signerKey);
        vm.prank(owner);
        nft.revokeSigner();
        assertEq(nft.signer(), address(0));
        vm.expectRevert(IDMRecords.BadSignature.selector);
        _submit(v, sig);
    }

    // ---------------------------------------------------------------- rewards

    function test_credit_beforeMint_goesToFirstMinter() public {
        vm.prank(label);
        nft.deposit(_ids(9), _amts(30e6));
        assertEq(nft.claimable(9), 0); // not minted yet
        _mint(alice, 9);
        assertEq(nft.claimable(9), 30e6);
        vm.prank(alice);
        nft.claim(_ids(9));
        assertEq(usd.balanceOf(alice), 30e6);
        assertEq(nft.claimable(9), 0);
    }

    function test_pool_sharedByMinted_lateMintGetsNone() public {
        _mint(alice, 1);
        _mint(bob, 2);
        vm.prank(label);
        nft.depositPool(100e6);
        _mint(bob, 3);
        assertEq(nft.claimable(1), 50e6);
        assertEq(nft.claimable(2), 50e6);
        assertEq(nft.claimable(3), 0);
        vm.prank(label);
        nft.depositPool(30e6);
        assertEq(nft.claimable(1), 60e6);
        assertEq(nft.claimable(3), 10e6);
    }

    function test_pool_revertsWithoutHolders() public {
        vm.prank(label);
        vm.expectRevert(IDMRecords.NoHolders.selector);
        nft.depositPool(1e6);
    }

    function test_rewards_moveWithNFT() public {
        _mint(alice, 4);
        vm.prank(label);
        nft.deposit(_ids(4), _amts(12e6));
        vm.prank(alice);
        nft.transferFrom(alice, bob, 4);
        vm.prank(alice);
        vm.expectRevert(IDMRecords.NotAuthorized.selector); // the old holder cannot claim any more
        nft.claim(_ids(4));
        vm.prank(bob);
        nft.claim(_ids(4));
        assertEq(usd.balanceOf(bob), 12e6);
        assertEq(usd.balanceOf(alice), 0);
    }

    function test_claim_keepsRemainder() public {
        _mint(alice, 1);
        _mint(bob, 2);
        _mint(bob, 3);
        vm.startPrank(label);
        nft.depositPool(1); // 1 unit over 3 holders: 0 each for now
        nft.depositPool(2); // 3 units in total: 1 each
        vm.stopPrank();
        assertEq(nft.claimable(1), 1);
        vm.prank(alice);
        nft.claim(_ids(1));
        assertEq(usd.balanceOf(alice), 1);
        assertEq(nft.claimable(1), 0);
    }

    function test_claim_unmintedReverts() public {
        vm.expectRevert(IDMRecords.NotMinted.selector);
        nft.claim(_ids(1));
    }

    /// Review PoC: anyone could push a token's rewards to a contract holder that cannot move USDG (an escrow).
    function test_Poc_claim_noForcedPushToContractHolder() public {
        _mint(alice, 1);
        vm.prank(label);
        nft.depositPool(100e6);
        Escrow e = new Escrow();
        vm.prank(alice);
        nft.transferFrom(alice, address(e), 1);
        vm.prank(bob);
        vm.expectRevert(IDMRecords.NotAuthorized.selector);
        nft.claim(_ids(1));
        assertEq(usd.balanceOf(address(e)), 0);
        assertEq(nft.claimable(1), 100e6); // waits on the token for whoever holds it next
    }

    function test_claim_byOperatorApprovedForAll() public {
        _mint(alice, 1);
        vm.prank(label);
        nft.depositPool(10e6);
        vm.prank(alice);
        nft.approve(bob, 1); // a single-token approval is not enough
        vm.prank(bob);
        vm.expectRevert(IDMRecords.NotAuthorized.selector);
        nft.claim(_ids(1));
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        nft.claim(_ids(1));
        assertEq(usd.balanceOf(alice), 10e6); // paid to the holder, not the operator
        assertEq(usd.balanceOf(bob), 0);
    }

    /// Review PoC: one frozen holder made a whole claim batch revert. Now that token keeps its rewards and the batch
    /// goes on; once unfrozen it claims everything.
    function test_Poc_claim_frozenHolderDoesNotBrickTheBatch() public {
        FreezableUSD f = new FreezableUSD();
        nft = new IDMRecords("IDM Records", "RECORDS", owner, signer, IERC20Like(address(f)), IBalanceOf(address(idm)), "x/", royalty, 500);
        f.mint(label, 1e12);
        vm.prank(label);
        f.approve(address(nft), type(uint256).max);
        _mint(alice, 1);
        _mint(bob, 2);
        vm.prank(label);
        nft.depositPool(100e6);
        vm.prank(label);
        nft.deposit(_ids(2), _amts(7e6));
        f.freeze(bob, true);
        vm.prank(alice);
        nft.setApprovalForAll(address(this), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(this), true);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 2);
        vm.expectEmit(true, true, false, true, address(nft));
        emit IDMRecords.ClaimFailed(2, bob, 57e6);
        nft.claim(ids);
        assertEq(f.balanceOf(alice), 50e6);
        assertEq(f.balanceOf(bob), 0);
        assertEq(nft.claimable(2), 57e6);
        assertEq(nft.trackCredit(2), 7e6);
        f.freeze(bob, false);
        vm.prank(label);
        nft.depositPool(2e6);
        nft.claim(ids);
        assertEq(f.balanceOf(bob), 58e6);
        assertEq(f.balanceOf(alice), 51e6);
        assertEq(nft.claimable(2), 0);
    }

    /// Fee-on-transfer safety: the pool shares what arrived; exact credits refuse a short transfer.
    function test_pull_countsWhatArrived() public {
        FeeUSD f = new FeeUSD();
        nft = new IDMRecords("IDM Records", "RECORDS", owner, signer, IERC20Like(address(f)), IBalanceOf(address(idm)), "x/", royalty, 500);
        f.mint(label, 1e12);
        vm.prank(label);
        f.approve(address(nft), type(uint256).max);
        _mint(alice, 1);
        vm.prank(label);
        nft.depositPool(100e6);
        assertEq(f.balanceOf(address(nft)), 99e6);
        assertEq(nft.claimable(1), 99e6);
        vm.prank(label);
        vm.expectRevert(abi.encodeWithSelector(IDMRecords.FeeOnTransfer.selector, 9.9e6, 10e6));
        nft.deposit(_ids(1), _amts(10e6));
        vm.prank(alice);
        nft.claim(_ids(1));
        assertEq(f.balanceOf(address(nft)), 0);
    }

    /// Review note (by design, not fixed): `minHold` is a spot check at the mint. $IDM borrowed for the transaction
    /// passes it; the real gate is the voucher service, which signs only for wallets whose LOWEST balance over 7 or
    /// 21 days is above the tier (docs/LAUNCH-PLAN.md), and a voucher names one wallet and one track.
    function test_minHold_isASpotCheck() public {
        IDMRecords.Voucher memory v = _voucher(alice, 5, 1, 1);
        v.minHold = 1000e18;
        bytes memory sig = _sign(v, signerKey);
        idm.mint(bob, 1000e18);
        vm.prank(bob);
        idm.transfer(alice, 1000e18);
        _submit(v, sig);
        vm.prank(alice);
        idm.transfer(bob, 1000e18);
        assertEq(nft.ownerOf(5), alice);
    }

    function test_deposit_validates() public {
        vm.startPrank(label);
        vm.expectRevert(IDMRecords.BadTokenId.selector);
        nft.deposit(_ids(1001), _amts(1));
        vm.expectRevert(IDMRecords.ZeroAmount.selector);
        nft.deposit(_ids(1), _amts(0));
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(IDMRecords.LengthMismatch.selector);
        nft.deposit(two, _amts(1));
        vm.stopPrank();
    }

    /// The pot never owes more than it holds.
    function testFuzz_solvent(uint32[6] memory pools, uint32[6] memory credits, uint8 mints) public {
        uint256 n = bound(mints, 1, 6);
        for (uint256 i = 1; i <= n; ++i) _mint(i % 2 == 0 ? alice : bob, i);
        vm.startPrank(label);
        for (uint256 i; i < 6; ++i) {
            if (pools[i] > 0) nft.depositPool(pools[i]);
            if (credits[i] > 0) nft.deposit(_ids(i + 1), _amts(credits[i]));
        }
        vm.stopPrank();
        uint256 owed;
        for (uint256 i = 1; i <= 6; ++i) owed += nft.claimable(i);
        uint256 unmintedCredit;
        for (uint256 i = n + 1; i <= 6; ++i) unmintedCredit += nft.trackCredit(i);
        assertLe(owed + unmintedCredit, usd.balanceOf(address(nft)));
        uint256[] memory all = new uint256[](n);
        for (uint256 i; i < n; ++i) all[i] = i + 1;
        // One operator approved by both holders claims the whole batch; each holder is paid.
        vm.prank(alice);
        nft.setApprovalForAll(address(this), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(this), true);
        nft.claim(all);
        assertEq(usd.balanceOf(alice) + usd.balanceOf(bob), owed);
    }

    // ---------------------------------------------------------------- ERC-721

    function test_approvals() public {
        _mint(alice, 1);
        vm.prank(bob);
        vm.expectRevert(IDMRecords.NotAuthorized.selector);
        nft.transferFrom(alice, bob, 1);
        vm.prank(alice);
        nft.approve(bob, 1);
        vm.prank(bob);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.getApproved(1), address(0));
        vm.expectRevert(IDMRecords.NotMinted.selector); // ERC-721: no approval for a token that does not exist
        nft.getApproved(2);
        vm.prank(bob);
        nft.setApprovalForAll(alice, true);
        vm.prank(alice);
        nft.transferFrom(bob, alice, 1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_safeTransfer() public {
        _mint(alice, 1);
        Receiver r = new Receiver();
        NotReceiver nr = new NotReceiver();
        vm.startPrank(alice);
        vm.expectRevert();
        nft.safeTransferFrom(alice, address(nr), 1);
        nft.safeTransferFrom(alice, address(r), 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), address(r));
    }

    function test_wrongFromAndZeroTo() public {
        _mint(alice, 1);
        vm.startPrank(alice);
        vm.expectRevert(IDMRecords.WrongFrom.selector);
        nft.transferFrom(bob, alice, 1);
        vm.expectRevert(IDMRecords.ZeroAddress.selector);
        nft.transferFrom(alice, address(0), 1);
        vm.stopPrank();
    }

    function test_interfacesAndRoyalty() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertTrue(nft.supportsInterface(0x5b5e139f));
        assertTrue(nft.supportsInterface(0x2a55205a));
        assertTrue(nft.supportsInterface(0x01ffc9a7));
        // ERC721-C, as Limit Break's creator token standards and OpenSea's docs define it.
        assertTrue(nft.supportsInterface(0xad0d7f6c));
        assertEq(type(ICreatorToken).interfaceId, bytes4(0xad0d7f6c));
        assertTrue(nft.supportsInterface(0xa07d229a));
        assertFalse(nft.supportsInterface(0xffffffff));
        (address to, uint256 amt) = nft.royaltyInfo(1, 1 ether);
        assertEq(to, royalty);
        assertEq(amt, 0.05 ether);
    }

    // ---------------------------------------------------------------- owner

    function test_ownerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.setSigner(alice);
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.activateSigner();
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.revokeSigner();
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.setBaseURI("x");
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.setRoyalty(alice, 1);
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.setTransferValidator(alice);
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.lockTransferValidator();
        vm.stopPrank();
    }

    function test_metadataFreeze() public {
        vm.startPrank(owner);
        nft.setBaseURI("ipfs://cid/");
        nft.freezeMetadata();
        vm.expectRevert(IDMRecords.Frozen.selector);
        nft.setBaseURI("https://evil/");
        vm.stopPrank();
        _mint(alice, 2);
        assertEq(nft.tokenURI(2), "ipfs://cid/2/metadata.json");
    }

    /// The release pipeline writes <records>/<n>/metadata.json; tokenURI must name that file. The same string is pinned
    /// in packages/stations-art/tests/records-layout.test.ts.
    function test_tokenURI_isThePipelinesFile() public {
        vm.prank(owner);
        nft.setBaseURI("https://theidm.fun/records/");
        _mint(alice, 42);
        assertEq(nft.tokenURI(42), "https://theidm.fun/records/42/metadata.json");
        vm.expectRevert(IDMRecords.NotMinted.selector);
        nft.tokenURI(43);
    }

    function test_royaltyCap() public {
        vm.prank(owner);
        vm.expectRevert(IDMRecords.RoyaltyTooHigh.selector);
        nft.setRoyalty(royalty, 1001);
    }

    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function test_creatorTokenSurface() public {
        assertEq(nft.getTransferValidator(), address(0));
        (bytes4 fn, bool isView) = nft.getTransferValidationFunction();
        assertEq(fn, bytes4(keccak256("validateTransfer(address,address,address,uint256)")));
        assertEq(fn, bytes4(0xcaee23ea));
        assertTrue(isView);

        address market = makeAddr("market");
        OwnerOrMarket v = new OwnerOrMarket(market);
        vm.expectEmit(address(nft));
        emit TransferValidatorUpdated(address(0), address(v));
        vm.prank(owner);
        nft.setTransferValidator(address(v));
        assertEq(nft.getTransferValidator(), address(v));
        assertEq(nft.transferValidator(), address(v));
        assertEq(v.tokenTypeOf(address(nft)), 721); // registered as ERC-721 with the validator

        BlockAll b = new BlockAll(); // has no setTokenTypeOfCollection: setting it still works
        vm.expectEmit(address(nft));
        emit TransferValidatorUpdated(address(v), address(b));
        vm.prank(owner);
        nft.setTransferValidator(address(b));
        assertEq(nft.getTransferValidator(), address(b));
    }

    function test_transferValidator_mustBeContract() public {
        vm.prank(owner);
        vm.expectRevert(IDMRecords.NotAContract.selector);
        nft.setTransferValidator(bob);
    }

    /// Owners move their own tokens and the allowed market sells them; any other operator is refused. Mints and
    /// claims never ask the validator.
    function test_transferValidator_enforces() public {
        address market = makeAddr("market");
        address stranger = makeAddr("stranger");
        OwnerOrMarket v = new OwnerOrMarket(market);
        vm.prank(owner);
        nft.setTransferValidator(address(v));

        _mint(alice, 1); // a mint is not a transfer
        vm.prank(label);
        nft.deposit(_ids(1), _amts(5e6));
        vm.prank(alice);
        nft.claim(_ids(1));
        assertEq(usd.balanceOf(alice), 5e6);

        vm.startPrank(alice);
        nft.setApprovalForAll(market, true);
        nft.setApprovalForAll(stranger, true);
        nft.transferFrom(alice, bob, 1); // OTC: the owner herself
        vm.stopPrank();
        assertEq(nft.ownerOf(1), bob);

        vm.prank(bob);
        nft.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        vm.expectRevert(bytes("not allowed"));
        nft.transferFrom(bob, alice, 1);

        vm.prank(bob);
        nft.setApprovalForAll(market, true);
        vm.prank(market);
        nft.safeTransferFrom(bob, alice, 1);
        assertEq(nft.ownerOf(1), alice);
    }

    /// As in ERC721-C: a transfer the validator itself makes (holder approved it) is not sent back to it.
    function test_transferValidator_ownTransfersSkipValidation() public {
        BlockAll b = new BlockAll();
        vm.prank(owner);
        nft.setTransferValidator(address(b));
        _mint(alice, 1);
        vm.prank(address(b));
        vm.expectRevert(IDMRecords.NotAuthorized.selector); // still needs the holder's approval
        nft.transferFrom(alice, bob, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(b), true);
        vm.prank(address(b));
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }

    function test_transferValidator_andLock() public {
        _mint(alice, 1);
        BlockAll b = new BlockAll();
        vm.prank(owner);
        nft.setTransferValidator(address(b));
        vm.prank(alice);
        vm.expectRevert(bytes("blocked"));
        nft.transferFrom(alice, bob, 1);
        vm.startPrank(owner);
        nft.setTransferValidator(address(0));
        nft.lockTransferValidator();
        vm.expectRevert(IDMRecords.Locked.selector);
        nft.setTransferValidator(address(b));
        vm.stopPrank();
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
    }

    function test_twoStepOwnership() public {
        vm.prank(owner);
        nft.transferOwnership(alice);
        assertEq(nft.owner(), owner);
        vm.prank(bob);
        vm.expectRevert(IDMRecords.NotOwner.selector);
        nft.acceptOwnership();
        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);
    }

    function test_ownerCannotMintWithoutSignature() public {
        IDMRecords.Voucher memory v = _voucher(owner, 1, 1, 1);
        vm.prank(owner);
        vm.expectRevert(IDMRecords.BadSignature.selector);
        nft.mint(v, new bytes(65));
    }
}

/// A contract wallet that submits its own voucher.
contract Submitter {
    IDMRecords immutable nft;

    constructor(IDMRecords nft_) {
        nft = nft_;
    }

    function submit(IDMRecords.Voucher calldata v, bytes calldata sig) external {
        nft.mint(v, sig);
    }
}
