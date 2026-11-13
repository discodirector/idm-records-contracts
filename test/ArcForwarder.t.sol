// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcForwarder} from "../src/ArcForwarder.sol";

/// USDC as far as the forwarder and the messenger use it.
contract FwdUsdc {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public refuseApprove;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function setRefuseApprove(bool r) external {
        refuseApprove = r;
    }

    function approve(address s, uint256 a) external returns (bool) {
        if (refuseApprove) return false;
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract FwdMinter {
    uint256 public limit = 10_000_000e6;

    function setLimit(uint256 l) external {
        limit = l;
    }

    function burnLimitsPerMessage(address) external view returns (uint256) {
        return limit;
    }
}

/// Stands in for TokenMessengerV2: pulls the amount (as CCTP does before burning it) and records the call.
contract FwdMessenger {
    struct Call {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
        address sender;
    }

    FwdMinter public immutable minter = new FwdMinter();
    Call[] public calls;
    bool public paused;
    /// @dev As TokenMessengerV2: 1e-7 units; 0 = off.
    uint256 public minFee;
    bool public noMinFee;

    function setMinFee(uint256 f) external {
        minFee = f;
    }

    function setNoMinFee(bool n) external {
        noMinFee = n;
    }

    function getMinFeeAmount(uint256 amount) public view returns (uint256) {
        require(!noMinFee, "no such function");
        if (minFee == 0) return 0;
        uint256 f = amount * minFee / 10_000_000;
        return f == 0 ? 1 : f;
    }

    function localMinter() external view returns (address) {
        return address(minter);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        require(!paused, "paused");
        require(amount > 0 && maxFee < amount, "fee");
        if (minFee > 0) require(maxFee >= getMinFeeAmount(amount), "Insufficient max fee");
        require(amount <= minter.limit(), "limit");
        require(hookData.length > 0, "hook");
        FwdUsdc(burnToken).transferFrom(msg.sender, address(this), amount);
        calls.push(
            Call(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold, hookData, msg.sender)
        );
    }

    function count() external view returns (uint256) {
        return calls.length;
    }

    function hookOf(uint256 i) external view returns (bytes memory) {
        return calls[i].hookData;
    }
}

contract ArcForwarderTest is Test {
    FwdUsdc usdc = new FwdUsdc();
    FwdMessenger messenger = new FwdMessenger();
    address splitter = makeAddr("labelSplitter");
    uint32 constant BASE_DOMAIN = 6;
    ArcForwarder f;

    event Forwarded(uint64 indexed seq, uint256 amount, uint256 maxFee, uint256 left);

    function setUp() public {
        f = new ArcForwarder(address(usdc), address(messenger), BASE_DOMAIN, splitter, 1e6, 0);
    }

    function _call(uint256 i) internal view returns (FwdMessenger.Call memory c) {
        (c.amount, c.destinationDomain, c.mintRecipient, c.burnToken, c.destinationCaller, c.maxFee, c.minFinalityThreshold,, c.sender) =
            messenger.calls(i);
        c.hookData = messenger.hookOf(i);
    }

    function test_ForwardsTheWholeBalanceToTheSplitterOnBase() public {
        usdc.mint(address(f), 990_000 + 10_000_000);
        vm.expectEmit(true, false, false, true, address(f));
        emit Forwarded(1, 10_990_000, 0, 0);
        vm.prank(makeAddr("anyone"));
        (uint64 seq, uint256 amount) = f.forward();
        assertEq(seq, 1);
        assertEq(amount, 10_990_000);
        assertEq(usdc.balanceOf(address(f)), 0);
        assertEq(usdc.balanceOf(address(messenger)), 10_990_000);
        FwdMessenger.Call memory c = _call(0);
        assertEq(c.amount, 10_990_000);
        assertEq(c.destinationDomain, BASE_DOMAIN);
        assertEq(c.mintRecipient, bytes32(uint256(uint160(splitter))));
        assertEq(c.burnToken, address(usdc));
        assertEq(c.destinationCaller, bytes32(0), "anyone can finish the message on Base");
        assertEq(c.maxFee, 0);
        assertEq(c.minFinalityThreshold, 2000, "Standard Transfer only");
        assertEq(abi.decode(c.hookData, (uint256)), 1);
        assertEq(c.sender, address(f));
        assertEq(usdc.allowance(address(f), address(messenger)), 0, "no allowance left over");
    }

    function test_SequenceNumbersCountUp() public {
        for (uint256 i = 1; i <= 3; ++i) {
            usdc.mint(address(f), i * 1e6);
            (uint64 seq,) = f.forward();
            assertEq(seq, i);
            assertEq(abi.decode(_call(i - 1).hookData, (uint256)), i);
        }
        assertEq(f.forwards(), 3);
    }

    function test_RefusesBelowTheMinimum() public {
        usdc.mint(address(f), 999_999);
        vm.expectRevert(abi.encodeWithSelector(ArcForwarder.TooLittle.selector, 999_999, 1e6));
        f.forward();
        (uint256 amount, uint256 maxFee, uint256 cap) = f.forwardable();
        assertEq(amount, 0);
        assertEq(maxFee, 0);
        assertEq(cap, 0);
        assertEq(f.forwards(), 0);
    }

    function test_EmptyRefuses() public {
        vm.expectRevert(abi.encodeWithSelector(ArcForwarder.TooLittle.selector, 0, 1e6));
        f.forward();
    }

    function test_AboveTheBurnLimitSendsTheLimitAndLeavesTheRest() public {
        messenger.minter().setLimit(5e6);
        usdc.mint(address(f), 12e6);
        vm.expectEmit(true, false, false, true, address(f));
        emit Forwarded(1, 5e6, 0, 7e6);
        f.forward();
        f.forward();
        (uint64 seq, uint256 amount) = f.forward();
        assertEq(seq, 3);
        assertEq(amount, 2e6);
        assertEq(usdc.balanceOf(address(f)), 0);
        assertEq(usdc.balanceOf(address(messenger)), 12e6);
    }

    function test_PaysExactlyCirclesMinimumFeeUpToTheCap() public {
        ArcForwarder g = new ArcForwarder(address(usdc), address(messenger), BASE_DOMAIN, splitter, 1e6, 15);
        usdc.mint(address(g), 20e6);
        (uint256 amount, uint256 maxFee, uint256 cap) = g.forwardable();
        assertEq(amount, 20e6);
        assertEq(maxFee, 0, "free while Circle's minimum is off");
        assertEq(cap, 30_000); // 0.15%
        g.forward();
        assertEq(_call(0).maxFee, 0);
        // Circle turns its minimum on (1 bps = 1000 in 1e-7 units): the next forward allows exactly that.
        messenger.setMinFee(1000);
        usdc.mint(address(g), 20e6);
        (, maxFee,) = g.forwardable();
        assertEq(maxFee, 2000);
        g.forward();
        assertEq(_call(1).maxFee, 2000);
        assertEq(_call(1).minFinalityThreshold, 2000);
    }

    function test_AMinimumFeeAboveTheCapStopsForwardsUntilItComesDown() public {
        ArcForwarder g = new ArcForwarder(address(usdc), address(messenger), BASE_DOMAIN, splitter, 1e6, 10);
        usdc.mint(address(g), 10e6);
        messenger.setMinFee(20_000); // 20 bps, above the 10 bps cap
        vm.expectRevert(abi.encodeWithSelector(ArcForwarder.FeeAboveCap.selector, 20_000, 10_000));
        g.forward();
        assertEq(usdc.balanceOf(address(g)), 10e6, "the money waits");
        messenger.setMinFee(5000);
        g.forward();
        assertEq(usdc.balanceOf(address(g)), 0);
        assertEq(_call(0).maxFee, 5000);
    }

    function test_WithMaxFeeZeroAnyMinimumFeeStopsForwards() public {
        usdc.mint(address(f), 10e6);
        messenger.setMinFee(1);
        vm.expectRevert(abi.encodeWithSelector(ArcForwarder.FeeAboveCap.selector, 1, 0));
        f.forward();
    }

    function test_AMessengerWithoutAMinimumFeeIsFree() public {
        messenger.setNoMinFee(true);
        usdc.mint(address(f), 2e6);
        (, uint256 maxFee,) = f.forwardable();
        assertEq(maxFee, 0);
        f.forward();
        assertEq(_call(0).maxFee, 0);
    }

    function test_ConstructorRefusesBadSettings() public {
        vm.expectRevert(ArcForwarder.BadConfig.selector);
        new ArcForwarder(address(0), address(messenger), BASE_DOMAIN, splitter, 1e6, 0);
        vm.expectRevert(ArcForwarder.BadConfig.selector);
        new ArcForwarder(address(usdc), address(0), BASE_DOMAIN, splitter, 1e6, 0);
        vm.expectRevert(ArcForwarder.BadConfig.selector);
        new ArcForwarder(address(usdc), address(messenger), BASE_DOMAIN, address(0), 1e6, 0);
        vm.expectRevert(ArcForwarder.BadConfig.selector);
        new ArcForwarder(address(usdc), address(messenger), BASE_DOMAIN, splitter, 0, 0);
        vm.expectRevert(ArcForwarder.BadConfig.selector);
        new ArcForwarder(address(usdc), address(messenger), BASE_DOMAIN, splitter, 1e6, 101);
    }

    function test_ReadsBack() public view {
        assertEq(address(f.usdc()), address(usdc));
        assertEq(address(f.tokenMessenger()), address(messenger));
        assertEq(f.destinationDomain(), BASE_DOMAIN);
        assertEq(f.recipient(), splitter);
        assertEq(f.minAmount(), 1e6);
        assertEq(f.maxFeeBps(), 0);
    }

    function test_AFailedBurnLeavesEverything() public {
        usdc.mint(address(f), 3e6);
        messenger.setPaused(true);
        vm.expectRevert(bytes("paused"));
        f.forward();
        assertEq(usdc.balanceOf(address(f)), 3e6);
        assertEq(f.forwards(), 0, "the sequence number is not used up");
        messenger.setPaused(false);
        (uint64 seq,) = f.forward();
        assertEq(seq, 1);
    }

    function test_RefusedApproveReverts() public {
        usdc.mint(address(f), 3e6);
        usdc.setRefuseApprove(true);
        vm.expectRevert(ArcForwarder.ApproveFailed.selector);
        f.forward();
    }

    /// Whatever arrives and whoever calls, the money only ever goes to the messenger, for the splitter on Base.
    function testFuzz_OnlyEverBurnsForTheSplitter(uint96[5] memory pays, address caller) public {
        uint256 total;
        for (uint256 i; i < pays.length; ++i) {
            uint256 a = uint256(pays[i]) % 1_000_000e6;
            usdc.mint(address(f), a);
            total += a;
            if (usdc.balanceOf(address(f)) >= 1e6) {
                vm.prank(caller);
                f.forward();
            }
        }
        assertEq(usdc.balanceOf(address(messenger)) + usdc.balanceOf(address(f)), total);
        for (uint256 i; i < messenger.count(); ++i) {
            FwdMessenger.Call memory c = _call(i);
            assertEq(c.mintRecipient, bytes32(uint256(uint160(splitter))));
            assertEq(c.destinationDomain, BASE_DOMAIN);
            assertEq(c.destinationCaller, bytes32(0));
            assertEq(c.minFinalityThreshold, 2000);
            assertEq(c.maxFee, 0);
        }
    }
}
