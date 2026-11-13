// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {ArcForwarder, ITokenMessengerV2, ITokenMinterV2} from "../src/ArcForwarder.sol";
import {LabelDeployBase} from "./LabelDeployBase.s.sol";

/// @title DeployArcForwarder — the label's pay-to on Arc (owner-run; docs/DEPLOY.md section 4b)
/// @notice One contract on Arc: ArcForwarder (no owner, immutable), the `payTo` of every x402 sale paid on Arc. It
///         sends all its USDC to the LabelSplitter on Base with Circle CCTP V2, so it is deployed AFTER the Base step
///         (DeployLabel) and reads the LabelSplitter from its verified record (deployments/label-base.json).
///         `run()` checks inputs and Circle's contracts on Arc, deploys (simulated unless --broadcast), reads it back,
///         prints a summary and writes deployments/arc-forwarder.preview.json; `verify()` reads the live contract,
///         checks its code against this build and writes deployments/arc-forwarder.json (ARC_FORWARDER and
///         ARC_START_BLOCK for the keepers).
/// @dev Env: DEPLOYER; LABEL_SPLITTER (default: the verified record's labelSplitter; when both are there they must
///      agree; LABEL_RECORD overrides the record's path); optional ARC_MIN_FORWARD (USDC units, default 1e6 = $1),
///      ARC_MAX_FEE_BPS (cap on Circle's minimum CCTP fee, default 10 = 0.1%; 0..100), ARC_TESTNET=1 for Arc Testnet
///      (5042002, a rehearsal with Base Sepolia's LabelSplitter). verify() optional: ARC_FORWARDER instead of the
///      broadcast file.
contract DeployArcForwarder is LabelDeployBase {
    string public constant SCRIPT_FILE = "DeployArcForwarder.s.sol";
    string public constant PREVIEW_RECORD = "deployments/arc-forwarder.preview.json";
    string public constant RECORD = "deployments/arc-forwarder.json";

    uint256 public constant ARC_CHAIN_ID = 5042;
    uint256 public constant ARC_TESTNET_CHAIN_ID = 5042002;
    /// @notice USDC's ERC-20 interface on Arc (mainnet and testnet).
    address public constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    /// @notice Circle CCTP V2 TokenMessengerV2: the same address on every EVM mainnet, another on every testnet.
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant TOKEN_MESSENGER_TESTNET = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;
    /// @notice CCTP domain of Base (and Base Sepolia); Arc's own is 26.
    uint32 public constant BASE_DOMAIN = 6;
    uint256 public constant DEFAULT_MIN_FORWARD = 1e6;
    uint16 public constant DEFAULT_MAX_FEE_BPS = 10;

    struct Config {
        address deployer;
        address splitter;
        uint256 minForward;
        uint16 maxFeeBps;
        bool testnet;
    }

    function run() external returns (ArcForwarder f) {
        Config memory c = loadConfig();
        checkInputs(c);
        f = deploy(c);
        check(c, f);
        summary(c, f, "local run (nothing is sent without --broadcast)");
        Created memory x;
        x.addr = address(f);
        writeRecord(c, x, "simulated", _recordPath(PREVIEW_RECORD));
    }

    /// @notice After the broadcast confirmed: reads the live contract back. Never sends anything.
    function verify() external returns (ArcForwarder f) {
        Config memory c = loadConfig();
        _arcChain(c);
        Created memory x = loadDeployment();
        f = ArcForwarder(x.addr);
        check(c, f);
        _checkCode(address(f), "ArcForwarder");
        summary(c, f, "VERIFIED on chain");
        writeRecord(c, x, "verified", _recordPath(RECORD));
    }

    function loadConfig() public view returns (Config memory c) {
        c.deployer = vm.envAddress("DEPLOYER");
        c.testnet = vm.envOr("ARC_TESTNET", false);
        address fromRecord = c.testnet ? address(0) : _fromRecord("LABEL_RECORD", "deployments/label-base.json", "labelSplitter");
        address fromEnv = vm.envOr("LABEL_SPLITTER", address(0));
        require(
            fromRecord == address(0) || fromEnv == address(0) || fromRecord == fromEnv,
            "LABEL_SPLITTER differs from deployments/label-base.json's labelSplitter"
        );
        c.splitter = fromEnv != address(0) ? fromEnv : fromRecord;
        c.minForward = vm.envOr("ARC_MIN_FORWARD", DEFAULT_MIN_FORWARD);
        uint256 bps = vm.envOr("ARC_MAX_FEE_BPS", uint256(DEFAULT_MAX_FEE_BPS));
        require(bps <= 100, "ARC_MAX_FEE_BPS: 0..100 (the contract refuses more than 1%)");
        c.maxFeeBps = uint16(bps);
    }

    function messenger(Config memory c) public pure returns (address) {
        return c.testnet ? TOKEN_MESSENGER_TESTNET : TOKEN_MESSENGER;
    }

    function _arcChain(Config memory c) internal view {
        if (c.testnet) _chain(ARC_TESTNET_CHAIN_ID, "Arc Testnet");
        else _chain(ARC_CHAIN_ID, "Arc");
    }

    function checkInputs(Config memory c) public view {
        _arcChain(c);
        _nonzero(c.deployer, "DEPLOYER");
        require(
            c.splitter != address(0),
            "LABEL_SPLITTER: deploy and verify the Base step first (deployments/label-base.json), or set it"
        );
        _distinct(c.splitter, c.deployer, "LABEL_SPLITTER and DEPLOYER");
        require(c.minForward >= 1e5 && c.minForward <= 1_000e6, "ARC_MIN_FORWARD: between 100000 ($0.10) and 1000000000 ($1000)");
        _hasCode(ARC_USDC, "Arc USDC");
        _decimals6(ARC_USDC, "Arc USDC");
        address m = messenger(c);
        _hasCode(m, "TokenMessengerV2");
        address minter = ITokenMessengerV2(m).localMinter();
        _hasCode(minter, "TokenMinterV2");
        require(
            ITokenMinterV2(minter).burnLimitsPerMessage(ARC_USDC) >= c.minForward,
            "TokenMinterV2: Arc USDC cannot be burned (per-message limit below ARC_MIN_FORWARD)"
        );
        uint256 minFee = ITokenMessengerV2(m).getMinFeeAmount(c.minForward);
        require(
            minFee <= c.minForward * c.maxFeeBps / BPS_UNIT,
            "Circle's minimum CCTP fee is already above ARC_MAX_FEE_BPS: forwards would not go out"
        );
    }

    uint256 private constant BPS_UNIT = 10_000;

    function deploy(Config memory c) public returns (ArcForwarder f) {
        vm.startBroadcast(c.deployer);
        f = new ArcForwarder(ARC_USDC, messenger(c), BASE_DOMAIN, c.splitter, c.minForward, c.maxFeeBps);
        vm.stopBroadcast();
    }

    /// @dev Reads every setting back; reverts on the first mismatch.
    function check(Config memory c, ArcForwarder f) public view {
        _hasCode(address(f), "ArcForwarder");
        require(address(f.usdc()) == ARC_USDC, "ArcForwarder mismatch: usdc");
        require(address(f.tokenMessenger()) == messenger(c), "ArcForwarder mismatch: tokenMessenger");
        require(f.destinationDomain() == BASE_DOMAIN, "ArcForwarder mismatch: destinationDomain");
        require(f.recipient() == c.splitter, "ArcForwarder mismatch: recipient (LabelSplitter)");
        require(f.minAmount() == c.minForward, "ArcForwarder mismatch: minAmount");
        require(f.maxFeeBps() == c.maxFeeBps, "ArcForwarder mismatch: maxFeeBps");
        require(f.FINALITY_STANDARD() == 2000, "ArcForwarder mismatch: finality");
    }

    function loadDeployment() public view returns (Created memory x) {
        address a = vm.envOr("ARC_FORWARDER", address(0));
        if (a != address(0)) {
            x.addr = a;
            return x;
        }
        string memory path = _broadcastFile(SCRIPT_FILE);
        require(vm.exists(path), string.concat("no broadcast file at ", path, "; set ARC_FORWARDER instead"));
        x = _created(vm.readFile(path), "ArcForwarder", 0);
    }

    function summary(Config memory c, ArcForwarder f, string memory status) public pure {
        console2.log("== Label pay-to on Arc", status);
        console2.log("  ArcForwarder (no owner, immutable)", address(f));
        console2.log("    sends USDC to (LabelSplitter, Base)", c.splitter);
        console2.log("    via CCTP V2 TokenMessengerV2      ", messenger(c));
        console2.log("    Base CCTP domain                  ", uint256(BASE_DOMAIN));
        console2.log("    least forward (USDC units)        ", c.minForward);
        console2.log("    fee cap (bps of a forward)        ", uint256(c.maxFeeBps));
        console2.log("    USDC on Arc (x402 asset)          ", ARC_USDC);
        console2.log("  NEXT: verify(), then MUSIC_ARC_PAY_TO = the forwarder (docs/DEPLOY.md section 4b)");
    }

    function writeRecord(Config memory c, Created memory x, string memory status, string memory path) public {
        string memory k = "arc";
        _recordHead(k, c.testnet ? "arc-testnet" : "arc", status);
        _recordCreated(k, "arcForwarder", x);
        vm.serializeAddress(k, "deployer", c.deployer);
        vm.serializeAddress(k, "labelSplitter", c.splitter);
        vm.serializeAddress(k, "tokenMessenger", messenger(c));
        vm.serializeUint(k, "destinationDomain", BASE_DOMAIN);
        vm.serializeUint(k, "minForward", c.minForward);
        vm.serializeUint(k, "maxFeeBps", c.maxFeeBps);
        string memory json = vm.serializeAddress(k, "usdc", ARC_USDC);
        vm.writeJson(json, path);
        console2.log("  record written:", path);
    }
}
