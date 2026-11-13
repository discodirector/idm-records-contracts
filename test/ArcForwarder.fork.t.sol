// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ArcForwarder, ITokenMessengerV2, ITokenMinterV2} from "../src/ArcForwarder.sol";

interface IUsdcArc {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function transfer(address, uint256) external returns (bool);
}

/// Arc moves USDC balances in its native ledger through a precompile at 0x1800…00, which Foundry's EVM does not have.
/// On the fork it is replaced by this stand-in: it moves native balances (18 decimals) with cheatcodes, as the
/// precompile does, so Circle's real USDC, TokenMessengerV2 and TokenMinterV2 code runs unchanged around it.
contract NativeLedgerStandIn {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    event Call(bytes4 selector, bytes data);

    function transfer(address from, address to, uint256 amount) external returns (bool) {
        vm.deal(from, from.balance - amount);
        vm.deal(to, to.balance + amount);
        return true;
    }

    function burn(address from, uint256 amount) external returns (bool) {
        vm.deal(from, from.balance - amount);
        return true;
    }

    function mint(address to, uint256 amount) external returns (bool) {
        vm.deal(to, to.balance + amount);
        return true;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        emit Call(bytes4(data), data);
        revert("NativeLedgerStandIn: unknown call");
    }
}

/// Arc's blocklist precompile at 0x1800…01, stood in for the same reason: nobody is blocklisted on the fork.
contract BlocklistStandIn {
    function isBlocklisted(address) external pure returns (bool) {
        return false;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        revert("BlocklistStandIn: unknown call");
    }
}

/// ArcForwarder against Circle's live CCTP V2 contracts on an Arc mainnet fork:
///   ARC_FORK_RPC=https://rpc.mainnet.arc.io forge test --match-contract ArcForwarderForkTest -vv
/// Skipped without ARC_FORK_RPC (no network in ordinary runs).
contract ArcForwarderForkTest is Test {
    uint256 constant ARC_CHAIN_ID = 5042;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant TOKEN_MINTER = 0xfd78EE919681417d192449715b2594ab58f5D002;
    uint32 constant BASE_DOMAIN = 6;
    address splitter = makeAddr("labelSplitterOnBase");

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("ARC_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, ARC_CHAIN_ID, "not Arc mainnet");
        return true;
    }

    function test_Fork_CctpOnArcIsWhatTheForwarderExpects() public {
        if (!_fork()) return;
        assertGt(TOKEN_MESSENGER.code.length, 0);
        assertEq(ITokenMessengerV2(TOKEN_MESSENGER).localMinter(), TOKEN_MINTER);
        assertGt(ITokenMinterV2(TOKEN_MINTER).burnLimitsPerMessage(USDC), 1_000_000e6, "per-message limit above $1M");
        assertEq(ITokenMessengerV2(TOKEN_MESSENGER).getMinFeeAmount(1_000_000), 0, "Standard Transfers from Arc are free today");
        assertEq(IUsdcArc(USDC).decimals(), 6);
        assertEq(IUsdcArc(USDC).name(), "USDC");
    }

    /// A real forward on the fork: the forwarder's USDC is burned by Circle's TokenMessengerV2 for the splitter on
    /// Base. The forwarder is funded by a USDC transfer from an address that holds some (Arc's USDC keeps balances in
    /// the native ledger, so `deal` cannot be used): ARC_FORK_USDC_HOLDER, or the TokenMessenger's own caller pool.
    function test_Fork_ForwardBurnsForTheSplitterOnBase() public {
        if (!_fork()) return;
        vm.etch(0x1800000000000000000000000000000000000000, address(new NativeLedgerStandIn()).code);
        vm.allowCheatcodes(0x1800000000000000000000000000000000000000);
        vm.etch(0x1800000000000000000000000000000000000001, address(new BlocklistStandIn()).code);
        ArcForwarder f = new ArcForwarder(USDC, TOKEN_MESSENGER, BASE_DOMAIN, splitter, 1e6, 10);
        address holder = vm.envOr("ARC_FORK_USDC_HOLDER", address(0));
        if (holder == address(0)) {
            // Arc's gas token is USDC: native value is the same balance as the ERC-20 (18 vs 6 decimals).
            holder = makeAddr("holder");
            vm.deal(holder, 10 ether);
        }
        uint256 have = IUsdcArc(USDC).balanceOf(holder);
        if (have < 3e6) {
            emit log_named_uint("holder's USDC (6 decimals), too little for the test", have);
            vm.skip(true);
            return;
        }
        vm.prank(holder);
        assertTrue(IUsdcArc(USDC).transfer(address(f), 3e6));
        assertEq(IUsdcArc(USDC).balanceOf(address(f)), 3e6);
        vm.recordLogs();
        (uint64 seq, uint256 amount) = f.forward();
        assertEq(seq, 1);
        assertEq(amount, 3e6);
        assertEq(IUsdcArc(USDC).balanceOf(address(f)), 0);
        // DepositForBurn(burnToken, amount, depositor, mintRecipient, destinationDomain, ..., hookData) from the messenger.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool burned;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == TOKEN_MESSENGER && logs[i].topics.length == 4) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), USDC, "burn token");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(f), "depositor");
                assertEq(uint256(logs[i].topics[3]), 2000, "Standard finality");
                burned = true;
            }
        }
        assertTrue(burned, "no DepositForBurn from Circle's TokenMessengerV2");
    }
}
