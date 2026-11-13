// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HolderRewards, IERC20Rewards} from "../src/HolderRewards.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";

contract MockUsdc {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public frozen;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function freeze(address a) external {
        frozen[a] = true;
    }

    function unfreeze(address a) external {
        frozen[a] = false;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!frozen[to], "frozen");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Builds the same tree as bot/src/rewards/tree.ts: leaves sorted, pairs hashed sorted, an odd node moves up as is.
library MerkleTestLib {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory layer = leaves;
        while (layer.length > 1) layer = _up(layer);
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory p) {
        bytes32[] memory tmp = new bytes32[](32);
        uint256 n;
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 sib = index ^ 1;
            if (sib < layer.length) tmp[n++] = layer[sib];
            layer = _up(layer);
            index /= 2;
        }
        p = new bytes32[](n);
        for (uint256 i; i < n; ++i) p[i] = tmp[i];
    }

    function _up(bytes32[] memory layer) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((layer.length + 1) / 2);
        for (uint256 i; i < layer.length; i += 2) {
            next[i / 2] = i + 1 < layer.length ? hashPair(layer[i], layer[i + 1]) : layer[i];
        }
    }
}

/// @dev A contract account on Base with no way to move USDC.
contract Escrow {}

abstract contract RewardsFixture is Test {
    MockUsdc usdc;
    HolderRewards rewards;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address safe = makeAddr("a Safe on Robinhood");
    address stranger = makeAddr("stranger");
    address guardian = makeAddr("guardian (watcher)");
    address infra = makeAddr("infra");
    uint64 constant DELAY = 12 hours;

    struct L {
        uint256 tokenId;
        address account;
        bool pushable;
        uint256 cumulative;
    }

    L[] internal _leaves;

    function setUp() public virtual {
        usdc = new MockUsdc();
        rewards = new HolderRewards(IERC20Rewards(address(usdc)), owner, keeper, guardian, DELAY, infra);
    }

    /// The contract's leaf, computed here so that no extra call sits between vm.expectRevert and the claim.
    function _leaf(uint256 id, address a, bool push, uint256 cum) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, a, push, cum))));
    }

    function _hashes() internal view returns (bytes32[] memory h) {
        h = new bytes32[](_leaves.length);
        for (uint256 i; i < _leaves.length; ++i) {
            L memory l = _leaves[i];
            h[i] = _leaf(l.tokenId, l.account, l.pushable, l.cumulative);
        }
    }

    /// Posts the leaves set with `_set` as the next root (total = their sum) and waits out the delay.
    function _post() internal returns (bytes32 r) {
        r = _propose();
        vm.warp(block.timestamp + DELAY);
    }

    function _propose() internal returns (bytes32 r) {
        r = MerkleTestLib.root(_hashes());
        uint256 total;
        for (uint256 i; i < _leaves.length; ++i) total += _leaves[i].cumulative;
        uint32 epoch = rewards.currentRoot().epoch + 1;
        vm.prank(keeper);
        rewards.proposeRoot(epoch, r, total, keccak256(abi.encode("epoch", epoch)));
    }

    function _set(L[] memory ls) internal {
        delete _leaves;
        for (uint256 i; i < ls.length; ++i) _leaves.push(ls[i]);
    }

    function _one(uint256 id, address a, bool push, uint256 cum) internal pure returns (L[] memory ls) {
        ls = new L[](1);
        ls[0] = L(id, a, push, cum);
    }

    function _two(L memory x, L memory y) internal pure returns (L[] memory ls) {
        ls = new L[](2);
        (ls[0], ls[1]) = (x, y);
    }

    function _claim(address caller, uint256 i) internal returns (uint256) {
        L memory l = _leaves[i];
        bytes32[] memory p = MerkleTestLib.proof(_hashes(), i);
        vm.prank(caller);
        return rewards.claim(l.tokenId, l.account, l.pushable, l.cumulative, p);
    }
}

contract HolderRewardsTest is RewardsFixture {
    function test_ConstructorChecks() public {
        IERC20Rewards u = IERC20Rewards(address(usdc));
        vm.expectRevert(HolderRewards.ZeroAddress.selector);
        new HolderRewards(IERC20Rewards(address(0)), owner, keeper, guardian, DELAY, infra);
        vm.expectRevert(HolderRewards.ZeroAddress.selector);
        new HolderRewards(u, address(0), keeper, guardian, DELAY, infra);
        vm.expectRevert(HolderRewards.ZeroAddress.selector);
        new HolderRewards(u, owner, address(0), guardian, DELAY, infra);
        vm.expectRevert(HolderRewards.ZeroAddress.selector);
        new HolderRewards(u, owner, keeper, guardian, DELAY, address(0));
        vm.expectRevert(HolderRewards.KeeperIsGuardian.selector);
        new HolderRewards(u, owner, keeper, keeper, DELAY, infra);
        vm.expectRevert(HolderRewards.BadDelay.selector);
        new HolderRewards(u, owner, keeper, guardian, 7 days + 1, infra);
        // A root must wait at least an hour: a zero or tiny delay leaves no time to catch a bad root.
        vm.expectRevert(HolderRewards.BadDelay.selector);
        new HolderRewards(u, owner, keeper, guardian, 0, infra);
        vm.expectRevert(HolderRewards.BadDelay.selector);
        new HolderRewards(u, owner, keeper, guardian, 1 hours - 1, infra);
        new HolderRewards(u, owner, keeper, address(0), 1 hours, infra); // no guardian is fine
        assertEq(rewards.rootDelay(), DELAY);
        assertEq(address(rewards.usdc()), address(usdc));
        assertEq(rewards.owner(), owner);
        assertEq(rewards.keeper(), keeper);
        assertEq(rewards.guardian(), guardian);
        assertEq(rewards.sweepTo(), infra);
    }

    function test_LeafMatchesTheKeeper() public view {
        assertEq(rewards.leaf(7, alice, true, 5e6), _leaf(7, alice, true, 5e6));
        // bot/test/rewards.test.ts checks the same vector: token 7, 0x...aa, pushable, 5 USDC.
        assertEq(
            rewards.leaf(7, address(0xaa), true, 5e6), 0xd0f5e74041461fa8bd15776cdba0d59f393f75969de4ece00a567ed9d42f7af8
        );
    }

    function test_ClaimPaysOnceAndOnlyTheDelta() public {
        usdc.mint(address(rewards), 30e6);
        _set(_two(L(1, alice, true, 10e6), L(2, bob, true, 5e6)));
        _post();
        assertEq(_claim(stranger, 0), 10e6); // anyone may push a plain wallet's rewards
        assertEq(usdc.balanceOf(alice), 10e6);
        // Double claim: nothing more, nothing moves.
        assertEq(_claim(alice, 0), 0);
        assertEq(usdc.balanceOf(alice), 10e6);
        assertEq(rewards.claimed(1), 10e6);
        assertEq(rewards.totalClaimed(), 10e6);

        // The next root: cumulative amounts grow; a claim pays only what is new.
        _set(_two(L(1, alice, true, 14e6), L(2, bob, true, 9e6)));
        _post();
        assertEq(_claim(alice, 0), 4e6);
        assertEq(_claim(bob, 1), 9e6);
        assertEq(usdc.balanceOf(alice), 14e6);
        assertEq(usdc.balanceOf(bob), 9e6);
        assertEq(rewards.totalClaimed(), 23e6);
        assertEq(usdc.balanceOf(address(rewards)), 7e6);
        assertEq(rewards.received(), 30e6);
    }

    function test_ClaimAfterTransferOfTheNft() public {
        usdc.mint(address(rewards), 30e6);
        _set(_one(7, alice, true, 10e6));
        _post();
        assertEq(_claim(alice, 0), 10e6);

        // Alice sells token 7 to Bob on Robinhood. The next root names Bob; he gets only what accrued since.
        L[] memory alicesOld = _one(7, alice, true, 10e6);
        bytes32[] memory oldProof = MerkleTestLib.proof(_hashes(), 0);
        _set(_one(7, bob, true, 16e6));
        _post();
        assertEq(_claim(bob, 0), 6e6);
        assertEq(usdc.balanceOf(bob), 6e6);
        // Alice's old leaf no longer proves against the current root.
        vm.expectRevert(HolderRewards.BadProof.selector);
        rewards.claim(7, alice, true, alicesOld[0].cumulative, oldProof);
        // Nor can anyone name her with Bob's amount.
        vm.expectRevert(HolderRewards.BadProof.selector);
        rewards.claim(7, alice, true, 16e6, MerkleTestLib.proof(_hashes(), 0));
    }

    function test_UnclaimedRewardsMoveWithTheNft() public {
        usdc.mint(address(rewards), 30e6);
        _set(_one(7, alice, true, 10e6));
        _post();
        // Alice never claims and sells; Bob gets everything the token earned.
        _set(_one(7, bob, true, 16e6));
        _post();
        assertEq(_claim(bob, 0), 16e6);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_ContractHolderClaimsOnlyItself() public {
        usdc.mint(address(rewards), 10e6);
        _set(_one(3, safe, false, 4e6));
        _post();
        vm.expectRevert(HolderRewards.NotAccount.selector);
        _claim(stranger, 0);
        // The same Safe on Base claims itself.
        assertEq(_claim(safe, 0), 4e6);
        // The pull-only flag is part of the leaf: flipping it breaks the proof.
        vm.expectRevert(HolderRewards.BadProof.selector);
        rewards.claim(3, safe, true, 4e6, MerkleTestLib.proof(_hashes(), 0));
    }

    function test_ContractHolderThatCannotClaimLeavesRewardsOnTheToken() public {
        usdc.mint(address(rewards), 10e6);
        _set(_one(3, safe, false, 4e6)); // an escrow with no twin on Base
        _post();
        // The NFT is sold out of the escrow to Alice: the next root names her with everything.
        _set(_one(3, alice, true, 5e6));
        _post();
        assertEq(_claim(stranger, 0), 5e6);
        assertEq(usdc.balanceOf(alice), 5e6);
    }

    function test_RootAboveReceivedIsRefused() public {
        usdc.mint(address(rewards), 10e6);
        bytes32 r = keccak256("root");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HolderRewards.OverReceived.selector, 10e6 + 1, 10e6));
        rewards.proposeRoot(1, r, 10e6 + 1, bytes32(0));

        // After a claim, what was paid still counts as received.
        _set(_one(1, alice, true, 10e6));
        _post();
        _claim(alice, 0);
        assertEq(usdc.balanceOf(address(rewards)), 0);
        assertEq(rewards.received(), 10e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HolderRewards.OverReceived.selector, 11e6, 10e6));
        rewards.proposeRoot(2, r, 11e6, bytes32(0));
        usdc.mint(address(rewards), 1e6);
        vm.prank(keeper);
        rewards.proposeRoot(2, r, 11e6, bytes32(0));
    }

    function test_ClaimsStopAtTheRootTotal() public {
        // A keeper that lies about the total (leaves sum to 20, root says 12) cannot make the contract pay 20.
        usdc.mint(address(rewards), 50e6);
        _set(_two(L(1, alice, true, 10e6), L(2, bob, true, 10e6)));
        bytes32 r = MerkleTestLib.root(_hashes());
        vm.prank(keeper);
        rewards.proposeRoot(1, r, 12e6, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        assertEq(_claim(alice, 0), 10e6);
        // Bob gets what the total still covers; the rest stays owed to token 2.
        assertEq(_claim(bob, 1), 2e6);
        assertEq(rewards.claimed(2), 2e6);
        assertEq(rewards.totalClaimed(), 12e6);
        assertEq(_claim(bob, 1), 0);
    }

    function test_TotalsNeverShrink() public {
        usdc.mint(address(rewards), 50e6);
        _set(_one(1, alice, true, 10e6));
        _post();
        _set(_one(1, alice, true, 9e6));
        bytes32 r = MerkleTestLib.root(_hashes());
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HolderRewards.TotalDecreased.selector, 9e6, 10e6));
        rewards.proposeRoot(2, r, 9e6, bytes32(0));
    }

    function test_RootWaitsItsDelayAndCanBeRevoked() public {
        usdc.mint(address(rewards), 50e6);
        _set(_one(1, alice, true, 10e6));
        _post();
        _set(_one(1, alice, true, 25e6));
        uint256 t0 = block.timestamp;
        bytes32 r = _propose();
        assertEq(rewards.pendingRoot().root, r);
        assertEq(rewards.pendingRoot().validFrom, t0 + DELAY);
        assertEq(rewards.currentRoot().epoch, 1);
        // Before the delay the new leaf does not prove; the old root still pays.
        vm.expectRevert(HolderRewards.BadProof.selector);
        _claim(alice, 0);
        // One pending root at a time.
        vm.prank(keeper);
        vm.expectRevert(HolderRewards.RootPending.selector);
        rewards.proposeRoot(3, keccak256("x"), 25e6, bytes32(0));
        // Only the owner or the guardian may revoke; not the keeper.
        vm.prank(stranger);
        vm.expectRevert(HolderRewards.NotRevoker.selector);
        rewards.revokePending();
        vm.prank(keeper);
        vm.expectRevert(HolderRewards.NotRevoker.selector);
        rewards.revokePending();
        vm.prank(owner);
        rewards.revokePending();
        assertEq(rewards.pendingRoot().root, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(HolderRewards.BadProof.selector);
        _claim(alice, 0); // revoked: never pays
        vm.prank(owner);
        vm.expectRevert(HolderRewards.NoPendingRoot.selector);
        rewards.revokePending();

        // The keeper re-posts the same epoch; the guardian may revoke it in its delay; once matured nobody can.
        _propose();
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(guardian);
        rewards.revokePending();
        _propose();
        vm.warp(block.timestamp + DELAY);
        vm.prank(owner);
        vm.expectRevert(HolderRewards.NoPendingRoot.selector);
        rewards.revokePending();
        assertEq(rewards.currentRoot().epoch, 2);
        assertEq(_claim(alice, 0), 25e6);
    }

    function test_EpochsAreConsecutive() public {
        usdc.mint(address(rewards), 50e6);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(HolderRewards.BadEpoch.selector, 1));
        rewards.proposeRoot(2, keccak256("r"), 1, bytes32(0));
        vm.expectRevert(HolderRewards.BadRoot.selector);
        rewards.proposeRoot(1, bytes32(0), 1, bytes32(0));
        rewards.proposeRoot(1, keccak256("r"), 1, keccak256("data"));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(HolderRewards.NotKeeper.selector);
        rewards.proposeRoot(1, keccak256("r"), 1, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        HolderRewards.Root memory c = rewards.currentRoot();
        assertEq(c.epoch, 1);
        assertEq(c.total, 1);
        assertEq(c.dataHash, keccak256("data"));
    }

    function test_ShortestDelayIsOneHour() public {
        HolderRewards fast = new HolderRewards(IERC20Rewards(address(usdc)), owner, keeper, guardian, 1 hours, infra);
        usdc.mint(address(fast), 5e6);
        bytes32 l = fast.leaf(1, alice, true, 5e6);
        vm.prank(keeper);
        fast.proposeRoot(1, l, 5e6, bytes32(0));
        assertEq(fast.currentRoot().root, bytes32(0)); // never active in the block it was posted
        vm.warp(block.timestamp + 1 hours);
        assertEq(fast.currentRoot().root, l);
        assertEq(fast.claim(1, alice, true, 5e6, new bytes32[](0)), 5e6);
    }

    /// Review PoC (HIGH): the keeper revoked the honest pending root and posted its own under the same epoch number
    /// in one block, then took the whole balance. The keeper can no longer revoke.
    function test_Poc_KeeperCannotSwapThePendingRoot() public {
        usdc.mint(address(rewards), 100);
        bytes32 honest = rewards.leaf(1, alice, true, 100);
        bytes32 evil = rewards.leaf(1, keeper, true, 100);
        vm.startPrank(keeper);
        rewards.proposeRoot(1, honest, 100, bytes32("honest"));
        vm.expectRevert(HolderRewards.NotRevoker.selector);
        rewards.revokePending();
        vm.expectRevert(HolderRewards.RootPending.selector);
        rewards.proposeRoot(1, evil, 100, bytes32("evil"));
        vm.stopPrank();
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(HolderRewards.BadProof.selector);
        rewards.claim(1, keeper, true, 100, new bytes32[](0));
        assertEq(rewards.claim(1, alice, true, 100, new bytes32[](0)), 100);
    }

    function test_GuardianOnlyRevokes() public {
        usdc.mint(address(rewards), 5e6);
        _set(_one(1, alice, true, 5e6));
        _propose();
        // The guardian cannot post, rotate or sweep.
        vm.startPrank(guardian);
        vm.expectRevert(HolderRewards.NotKeeper.selector);
        rewards.proposeRoot(2, keccak256("r"), 1, bytes32(0));
        vm.expectRevert(HolderRewards.NotOwner.selector);
        rewards.setKeeper(guardian);
        vm.expectRevert(HolderRewards.NotOwner.selector);
        rewards.setGuardian(stranger);
        vm.expectRevert(HolderRewards.NotKeeper.selector);
        rewards.sweep(address(0));
        rewards.revokePending();
        vm.stopPrank();
        assertEq(rewards.pendingRoot().root, bytes32(0));

        // The owner sets and clears it; the keeper can never be the guardian.
        vm.startPrank(owner);
        vm.expectRevert(HolderRewards.KeeperIsGuardian.selector);
        rewards.setGuardian(keeper);
        vm.expectRevert(HolderRewards.KeeperIsGuardian.selector);
        rewards.setKeeper(guardian);
        rewards.setGuardian(address(0));
        vm.stopPrank();
        assertEq(rewards.guardian(), address(0));
        _propose();
        vm.prank(guardian);
        vm.expectRevert(HolderRewards.NotRevoker.selector);
        rewards.revokePending();
        // With no guardian set, the zero address is not a revoker either.
        vm.prank(address(0));
        vm.expectRevert(HolderRewards.NotRevoker.selector);
        rewards.revokePending();
    }

    /// Review PoC (MEDIUM): ETH sent to a splitter whose payee is HolderRewards could never be released. HolderRewards
    /// takes ETH now, and the keeper sweeps it (and any token but USDC) to infra; USDC never leaves that way.
    function test_Poc_EthAndOtherTokensFromTheSplitterGoToInfra() public {
        address burn = makeAddr("burn");
        address[] memory a = new address[](3);
        (a[0], a[1], a[2]) = (address(rewards), burn, infra);
        uint16[] memory b = new uint16[](3);
        (b[0], b[1], b[2]) = (5000, 2500, 2500);
        RevenueSplitter s = new RevenueSplitter(a, b, new bool[](3), address(0), infra);
        vm.deal(address(s), 1 ether);
        s.release();
        assertEq(address(rewards).balance, 0.5 ether);
        MockUsdc other = new MockUsdc();
        other.mint(address(s), 100);
        s.releaseToken(address(other));
        assertEq(other.balanceOf(address(rewards)), 50);
        usdc.mint(address(rewards), 7e6);

        vm.prank(stranger);
        vm.expectRevert(HolderRewards.NotKeeper.selector);
        rewards.sweep(address(0));
        vm.startPrank(keeper);
        vm.expectRevert(HolderRewards.NotSweepable.selector);
        rewards.sweep(address(usdc));
        assertEq(rewards.sweep(address(0)), 0.5 ether);
        assertEq(rewards.sweep(address(other)), 50);
        vm.stopPrank();
        assertEq(infra.balance, 0.75 ether);
        assertEq(other.balanceOf(infra), 75);
        assertEq(rewards.received(), 7e6); // only USDC counts, and it stays
    }

    /// Review PoC (MEDIUM), then swarm audit 2026-11-13 (low): a root that lowers one token's cumulative under what it
    /// already took and raises another's (same sum) cannot cover every leaf. The keeper refuses such a root before
    /// posting (bot/src/rewards/epoch.ts checkLeaves); if one lands anyway, the other holder is paid what the total
    /// still covers (it used to be locked out entirely) and the rest stays owed until a corrected root.
    function test_Poc_PerTokenDecreasePaysWhatTheTotalCovers() public {
        usdc.mint(address(rewards), 100);
        bytes32 a1 = rewards.leaf(1, alice, true, 60);
        bytes32 b1 = rewards.leaf(2, bob, true, 40);
        vm.prank(keeper);
        rewards.proposeRoot(1, MerkleTestLib.hashPair(a1, b1), 100, 0);
        vm.warp(block.timestamp + DELAY);
        bytes32[] memory p = new bytes32[](1);
        p[0] = b1;
        rewards.claim(1, alice, true, 60, p);
        bytes32 a2 = rewards.leaf(1, alice, true, 20);
        bytes32 b2 = rewards.leaf(2, bob, true, 80);
        vm.prank(keeper);
        rewards.proposeRoot(2, MerkleTestLib.hashPair(a2, b2), 100, 0);
        vm.warp(block.timestamp + DELAY);
        p[0] = a2;
        assertEq(rewards.claim(2, bob, true, 80, p), 40);
        assertEq(rewards.totalClaimed(), 100);
        assertEq(usdc.balanceOf(address(rewards)), 0);
        assertEq(rewards.claim(2, bob, true, 80, p), 0); // never more than arrived
        // 40 more arrive and a corrected root pays bob the rest.
        usdc.mint(address(rewards), 40);
        bytes32 a3 = rewards.leaf(1, alice, true, 60);
        bytes32 b3 = rewards.leaf(2, bob, true, 80);
        vm.prank(keeper);
        rewards.proposeRoot(3, MerkleTestLib.hashPair(a3, b3), 140, 0);
        vm.warp(block.timestamp + DELAY);
        p[0] = a3;
        assertEq(rewards.claim(2, bob, true, 80, p), 40);
        assertEq(usdc.balanceOf(bob), 80);
    }

    /// Swarm audit 2026-11-13 (low): a pushable leaf whose account has code on Base (an escrow that cannot move USDC)
    /// is not pushed by a stranger; the contract may still claim itself.
    function test_StrangerCannotPushUsdcIntoAContractAccount() public {
        address escrow = address(new Escrow());
        usdc.mint(address(rewards), 100e6);
        _set(_one(1, escrow, true, 100e6));
        _post();
        vm.expectRevert(HolderRewards.NotAccount.selector);
        _claim(stranger, 0);
        assertEq(usdc.balanceOf(escrow), 0);
        assertEq(_claim(escrow, 0), 100e6);
    }

    /// Swarm audit 2026-11-13 (info): one leaf that cannot be paid (a frozen account, a contract account) no longer
    /// fails the pushed batch; it is skipped with ClaimFailed and keeps its rewards.
    function test_ClaimManySkipsALeafItCannotPay() public {
        address escrow = address(new Escrow());
        usdc.mint(address(rewards), 50e6);
        usdc.freeze(alice);
        L[] memory ls = new L[](3);
        ls[0] = L(1, alice, true, 1e6);
        ls[1] = L(2, escrow, true, 2e6);
        ls[2] = L(9, bob, true, 3e6);
        _set(ls);
        _post();
        bytes32[] memory h = _hashes();
        HolderRewards.Claim[] memory cs = new HolderRewards.Claim[](3);
        for (uint256 i; i < 3; ++i) {
            cs[i] = HolderRewards.Claim(ls[i].tokenId, ls[i].account, ls[i].pushable, ls[i].cumulative, MerkleTestLib.proof(h, i));
        }
        vm.expectEmit(address(rewards));
        emit HolderRewards.ClaimFailed(1, alice, 1e6);
        vm.expectEmit(address(rewards));
        emit HolderRewards.ClaimFailed(2, escrow, 2e6);
        vm.prank(stranger);
        assertEq(rewards.claimMany(cs), 3e6);
        assertEq(usdc.balanceOf(bob), 3e6);
        assertEq(rewards.claimed(1), 0);
        assertEq(rewards.claimed(2), 0);
        assertEq(rewards.totalClaimed(), 3e6);
        usdc.unfreeze(alice);
        vm.prank(stranger);
        assertEq(rewards.claimMany(cs), 1e6);
        assertEq(usdc.balanceOf(alice), 1e6);
    }

    function test_ClaimMany() public {
        usdc.mint(address(rewards), 50e6);
        L[] memory ls = new L[](3);
        ls[0] = L(1, alice, true, 1e6);
        ls[1] = L(2, alice, true, 2e6);
        ls[2] = L(9, bob, true, 3e6);
        _set(ls);
        _post();
        bytes32[] memory h = _hashes();
        HolderRewards.Claim[] memory cs = new HolderRewards.Claim[](3);
        for (uint256 i; i < 3; ++i) {
            cs[i] = HolderRewards.Claim(ls[i].tokenId, ls[i].account, ls[i].pushable, ls[i].cumulative, MerkleTestLib.proof(h, i));
        }
        vm.prank(stranger);
        assertEq(rewards.claimMany(cs), 6e6);
        assertEq(usdc.balanceOf(alice), 3e6);
        assertEq(usdc.balanceOf(bob), 3e6);
        assertEq(rewards.claimMany(cs), 0); // again: nothing
    }

    function test_FailedTransferPaysNothing() public {
        usdc.mint(address(rewards), 5e6);
        usdc.freeze(alice);
        _set(_one(1, alice, true, 5e6));
        _post();
        vm.expectRevert();
        _claim(alice, 0);
        assertEq(rewards.claimed(1), 0);
        assertEq(rewards.totalClaimed(), 0);
    }

    function test_KeeperRotationDropsThePendingRoot() public {
        usdc.mint(address(rewards), 5e6);
        _set(_one(1, alice, true, 5e6));
        _propose(); // say the keeper key leaked and this root is bad
        address next = makeAddr("new keeper");
        vm.prank(stranger);
        vm.expectRevert(HolderRewards.NotOwner.selector);
        rewards.setKeeper(next);
        vm.prank(owner);
        vm.expectRevert(HolderRewards.ZeroAddress.selector);
        rewards.setKeeper(address(0));
        vm.prank(owner);
        rewards.setKeeper(next);
        assertEq(rewards.keeper(), next);
        assertEq(rewards.pendingRoot().root, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        assertEq(rewards.currentRoot().epoch, 0);
        vm.prank(keeper);
        vm.expectRevert(HolderRewards.NotKeeper.selector);
        rewards.proposeRoot(1, keccak256("r"), 1, bytes32(0));
    }

    function test_OwnershipIsTwoStep() public {
        address next = makeAddr("next owner");
        vm.prank(stranger);
        vm.expectRevert(HolderRewards.NotOwner.selector);
        rewards.transferOwnership(next);
        vm.prank(owner);
        rewards.transferOwnership(next);
        assertEq(rewards.owner(), owner);
        vm.prank(stranger);
        vm.expectRevert(HolderRewards.NotOwner.selector);
        rewards.acceptOwnership();
        vm.prank(next);
        rewards.acceptOwnership();
        assertEq(rewards.owner(), next);
        assertEq(rewards.pendingOwner(), address(0));
    }

    function testFuzz_NoRootAboveReceived(uint96 deposit, uint96 total, uint96 claimFirst) public {
        claimFirst = uint96(bound(claimFirst, 0, deposit));
        usdc.mint(address(rewards), deposit);
        if (claimFirst > 0) {
            _set(_one(1, alice, true, claimFirst));
            _post();
            _claim(alice, 0);
        }
        uint32 epoch = rewards.currentRoot().epoch + 1;
        vm.prank(keeper);
        if (total > deposit || total < claimFirst) {
            vm.expectRevert();
            rewards.proposeRoot(epoch, keccak256("r"), total, bytes32(0));
        } else {
            rewards.proposeRoot(epoch, keccak256("r"), total, bytes32(0));
        }
        assertEq(usdc.balanceOf(address(rewards)) + rewards.totalClaimed(), deposit);
    }
}

/// Random deposits, roots (honest or lying totals) and claims. Whatever the keeper posts, the contract never pays out
/// more than arrived and never more than the active root's total.
contract RewardsHandler is Test {
    MockUsdc usdc;
    HolderRewards rewards;
    address keeper;
    uint256 public deposited;
    address[3] accounts;

    struct Leaf {
        uint256 tokenId;
        address account;
        uint256 cumulative;
    }

    Leaf[] leaves; // of the last root proposed
    Leaf[] active; // of the root claims use

    constructor(MockUsdc u, HolderRewards r, address k) {
        (usdc, rewards, keeper) = (u, r, k);
        accounts = [makeAddr("h1"), makeAddr("h2"), makeAddr("h3")];
    }

    function deposit(uint64 amount) external {
        usdc.mint(address(rewards), amount);
        deposited += amount;
    }

    function propose(uint64[3] calldata cums, uint8 who, bool lie, uint64 lieTotal) external {
        if (rewards.pendingRoot().root != bytes32(0)) return;
        delete leaves;
        uint256 sum;
        bytes32[] memory h = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            leaves.push(Leaf(i + 1, accounts[(who + i) % 3], cums[i]));
            sum += cums[i];
            h[i] = rewards.leaf(i + 1, accounts[(who + i) % 3], true, cums[i]);
        }
        uint256 total = lie ? lieTotal : sum;
        uint32 epoch = rewards.currentRoot().epoch + 1;
        vm.prank(keeper);
        try rewards.proposeRoot(epoch, MerkleTestLib.root(h), total, bytes32(0)) {} catch {}
    }

    function wait() external {
        bool had = rewards.pendingRoot().root != bytes32(0);
        vm.warp(block.timestamp + rewards.rootDelay());
        if (had) {
            delete active;
            for (uint256 i; i < leaves.length; ++i) active.push(leaves[i]);
        }
    }

    function claim(uint8 i) external {
        if (active.length == 0) return;
        i = uint8(i % active.length);
        bytes32[] memory h = new bytes32[](active.length);
        for (uint256 j; j < active.length; ++j) {
            h[j] = rewards.leaf(active[j].tokenId, active[j].account, true, active[j].cumulative);
        }
        Leaf memory l = active[i];
        try rewards.claim(l.tokenId, l.account, true, l.cumulative, MerkleTestLib.proof(h, i)) {} catch {}
    }
}

contract HolderRewardsInvariantTest is Test {
    MockUsdc usdc;
    HolderRewards rewards;
    RewardsHandler handler;

    function setUp() public {
        usdc = new MockUsdc();
        address keeper = makeAddr("keeper");
        rewards = new HolderRewards(IERC20Rewards(address(usdc)), makeAddr("owner"), keeper, address(0), 1 hours, makeAddr("infra"));
        handler = new RewardsHandler(usdc, rewards, keeper);
        targetContract(address(handler));
    }

    function invariant_PaidNeverAboveReceived() public view {
        assertEq(usdc.balanceOf(address(rewards)) + rewards.totalClaimed(), handler.deposited());
        assertLe(rewards.totalClaimed(), handler.deposited());
    }

    function invariant_PaidNeverAboveTheRootTotal() public view {
        assertLe(rewards.totalClaimed(), rewards.currentRoot().total);
        assertLe(rewards.currentRoot().total, rewards.received());
    }
}
