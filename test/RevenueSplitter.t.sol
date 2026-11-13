// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";

contract Tok {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract Weth is Tok {
    function withdraw(uint256 a) external {
        balanceOf[msg.sender] -= a;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok);
    }

    receive() external payable {}
}

/// Takes ETH, has no way to move tokens (stands in for PulseTreasury).
contract EthOnly {
    receive() external payable {}
}

contract Refuser {}

contract Greedy {
    RevenueSplitter public s;

    function set(RevenueSplitter s_) external {
        s = s_;
    }

    receive() external payable {
        if (address(s).balance > 0) s.release();
    }
}

contract RevenueSplitterTest is Test {
    address feeder = makeAddr("feeder");
    address infra = makeAddr("infra");
    EthOnly treasury = new EthOnly();
    Weth weth = new Weth();
    RevenueSplitter s;

    function _split(address a, address b, address c, bool bEthOnly, address sink) internal returns (RevenueSplitter) {
        address[] memory acc = new address[](3);
        (acc[0], acc[1], acc[2]) = (a, b, c);
        uint16[] memory bps = new uint16[](3);
        (bps[0], bps[1], bps[2]) = (5000, 2500, 2500);
        bool[] memory only = new bool[](3);
        only[1] = bEthOnly;
        return new RevenueSplitter(acc, bps, only, address(weth), sink);
    }

    function setUp() public {
        s = _split(feeder, address(treasury), infra, true, infra);
    }

    function test_SplitsEth50_25_25() public {
        vm.deal(address(s), 1 ether);
        s.release();
        assertEq(feeder.balance, 0.5 ether);
        assertEq(address(treasury).balance, 0.25 ether);
        assertEq(infra.balance, 0.25 ether);
        assertEq(address(s).balance, 0);
    }

    function testFuzz_NothingLost(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(s), amount);
        s.release();
        assertEq(feeder.balance + address(treasury).balance + infra.balance, amount);
        assertEq(feeder.balance, uint256(amount) * 5000 / 10_000);
    }

    function test_AnyoneReleases_AndEmptyReverts() public {
        vm.expectRevert(RevenueSplitter.NothingToRelease.selector);
        s.release();
        vm.deal(address(s), 4);
        vm.prank(makeAddr("stranger"));
        s.release();
        assertEq(feeder.balance, 2);
    }

    function test_WethIsUnwrappedThenReleased() public {
        vm.deal(address(weth), 1 ether);
        weth.mint(address(s), 1 ether);
        vm.expectRevert(RevenueSplitter.UseUnwrap.selector);
        s.releaseToken(address(weth));
        s.unwrapWeth();
        s.release();
        assertEq(address(treasury).balance, 0.25 ether);
    }

    function test_TokenShareOfEthOnlyPayeeGoesToSink() public {
        Tok usd = new Tok();
        usd.mint(address(s), 1000);
        s.releaseToken(address(usd));
        assertEq(usd.balanceOf(feeder), 500);
        assertEq(usd.balanceOf(address(treasury)), 0);
        assertEq(usd.balanceOf(infra), 500);
    }

    function test_RefusesBadPayees() public {
        vm.expectRevert(RevenueSplitter.BadPayees.selector);
        _split(feeder, feeder, infra, false, infra); // duplicate
        vm.expectRevert(RevenueSplitter.BadPayees.selector);
        _split(feeder, address(0), infra, false, infra); // zero
        vm.expectRevert(RevenueSplitter.BadPayees.selector);
        _split(feeder, address(treasury), infra, true, address(treasury)); // sink cannot take tokens
        vm.expectRevert(RevenueSplitter.BadPayees.selector);
        _split(feeder, address(treasury), infra, true, makeAddr("outsider")); // sink not a payee
        address[] memory acc = new address[](1);
        acc[0] = feeder;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 9999;
        vm.expectRevert(RevenueSplitter.BadPayees.selector);
        new RevenueSplitter(acc, bps, new bool[](1), address(0), address(0)); // not 100%
    }

    function test_PayeeThatRefusesEthBlocksRelease() public {
        RevenueSplitter r = _split(feeder, address(new Refuser()), infra, false, infra);
        vm.deal(address(r), 1 ether);
        vm.expectRevert();
        r.release();
    }

    function test_PayeeCannotReenter() public {
        Greedy g = new Greedy();
        RevenueSplitter r = _split(address(g), address(treasury), infra, true, infra);
        g.set(r);
        vm.deal(address(r), 1 ether);
        vm.expectRevert();
        r.release();
    }
}
