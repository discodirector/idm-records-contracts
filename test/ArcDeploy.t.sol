// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ArcForwarder} from "../src/ArcForwarder.sol";
import {DeployArcForwarder} from "../script/DeployArcForwarder.s.sol";
import {FwdMessenger} from "./ArcForwarder.t.sol";

/// Arc's USDC as the deploy script reads it (decimals) and the forwarder moves it.
contract ArcUsdc6 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
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

/// DeployArcForwarder's checks, deploy and read-back on stand-ins of Arc's USDC and Circle's TokenMessengerV2 at their
/// real addresses (no env: the env-driven run is covered by the dry run against Arc in docs/DEPLOY.md section 4b).
contract DeployArcForwarderTest is Test {
    DeployArcForwarder script;
    address deployer = makeAddr("deployer");
    address splitter = makeAddr("labelSplitterOnBase");
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant MESSENGER_TESTNET = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;

    function setUp() public {
        script = new DeployArcForwarder();
        vm.chainId(5042);
        vm.etch(USDC, address(new ArcUsdc6()).code);
        vm.etch(MESSENGER, address(new FwdMessenger()).code);
    }

    function cfg() internal view returns (DeployArcForwarder.Config memory) {
        return DeployArcForwarder.Config({deployer: deployer, splitter: splitter, minForward: 1e6, maxFeeBps: 10, testnet: false});
    }

    function test_DeploysReadsBackAndForwardsToTheSplitter() public {
        DeployArcForwarder.Config memory c = cfg();
        script.checkInputs(c);
        uint64 nonce = vm.getNonce(deployer);
        ArcForwarder f = script.deploy(c);
        script.check(c, f);
        assertEq(vm.getNonce(deployer), nonce + 1);
        assertEq(address(f.usdc()), USDC);
        assertEq(address(f.tokenMessenger()), MESSENGER);
        assertEq(f.destinationDomain(), 6);
        assertEq(f.recipient(), splitter);
        assertEq(f.minAmount(), 1e6);
        assertEq(f.maxFeeBps(), 10);
        ArcUsdc6(USDC).mint(address(f), 2e6);
        f.forward();
        assertEq(ArcUsdc6(USDC).balanceOf(MESSENGER), 2e6);
    }

    function test_InputChecks() public {
        DeployArcForwarder.Config memory c = cfg();
        c.splitter = address(0);
        vm.expectRevert(bytes("LABEL_SPLITTER: deploy and verify the Base step first (deployments/label-base.json), or set it"));
        script.checkInputs(c);
        c = cfg();
        c.splitter = deployer;
        vm.expectRevert(bytes("LABEL_SPLITTER and DEPLOYER: must be different addresses"));
        script.checkInputs(c);
        c = cfg();
        c.minForward = 1;
        vm.expectRevert(bytes("ARC_MIN_FORWARD: between 100000 ($0.10) and 1000000000 ($1000)"));
        script.checkInputs(c);
        c = cfg();
        vm.chainId(8453);
        vm.expectRevert(bytes("wrong chain: expected Arc 5042"));
        script.checkInputs(c);
    }

    function test_RefusesWhenCirclesMinimumFeeIsAlreadyAboveTheCap() public {
        FwdMessenger(MESSENGER).setMinFee(20_000); // 20 bps
        DeployArcForwarder.Config memory c = cfg();
        vm.expectRevert(bytes("Circle's minimum CCTP fee is already above ARC_MAX_FEE_BPS: forwards would not go out"));
        script.checkInputs(c);
        c.maxFeeBps = 25;
        script.checkInputs(c);
    }

    function test_CheckFailsOnEveryMismatch() public {
        DeployArcForwarder.Config memory c = cfg();
        ArcForwarder f = script.deploy(c);
        DeployArcForwarder.Config memory other = cfg();
        other.splitter = makeAddr("someoneElse");
        vm.expectRevert(bytes("ArcForwarder mismatch: recipient (LabelSplitter)"));
        script.check(other, f);
        other = cfg();
        other.minForward = 2e6;
        vm.expectRevert(bytes("ArcForwarder mismatch: minAmount"));
        script.check(other, f);
        other = cfg();
        other.maxFeeBps = 0;
        vm.expectRevert(bytes("ArcForwarder mismatch: maxFeeBps"));
        script.check(other, f);
        other = cfg();
        other.testnet = true;
        vm.expectRevert(bytes("ArcForwarder mismatch: tokenMessenger"));
        script.check(other, f);
    }

    function test_TestnetUsesCirclesTestnetMessenger() public {
        vm.chainId(5042002);
        vm.etch(MESSENGER_TESTNET, address(new FwdMessenger()).code);
        DeployArcForwarder.Config memory c = cfg();
        c.testnet = true;
        script.checkInputs(c);
        ArcForwarder f = script.deploy(c);
        script.check(c, f);
        assertEq(address(f.tokenMessenger()), MESSENGER_TESTNET);
    }
}
