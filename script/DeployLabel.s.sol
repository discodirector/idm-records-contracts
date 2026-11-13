// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {HolderRewards, IERC20Rewards} from "../src/HolderRewards.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {LabelDeployBase} from "./LabelDeployBase.s.sol";

/// @title DeployLabel — the label's money on Base (owner-run; docs/DEPLOY.md)
/// @notice Two contracts, in this order:
///           1. HolderRewards (USDC, owner = REWARDS_OWNER, keeper = REWARDS_KEEPER, guardian = REWARDS_GUARDIAN, root
///              delay, sweep to infra): the IDM Records holders' rewards, paid on Base (owner decision 2026-11-04,
///              docs/HOLDER-REWARDS.md)
///           2. RevenueSplitter (LabelSplitter), the `payTo` of every x402 sale: 50% HolderRewards, 25% the $IDM burn
///              bridge wallet, 25% infra. The bridge keeper (bot/src/bridge) holds the burn wallet's key and moves its
///              USDC to Robinhood Chain as ETH for PulseTreasury. No payee is ETH-only, so the token sink is unused
///              (set to infra). No WETH unwrapping: WETH stays a token, and HolderRewards sweeps its half (with any
///              ETH or other token) to infra.
///         `run()` checks inputs, deploys (simulated unless --broadcast), reads it back, prints a summary and writes
///         deployments/label-base.preview.json; `verify()` reads the live contracts, checks their code against this
///         build and writes deployments/label-base.json.
/// @dev Env: DEPLOYER, REWARDS_KEEPER, BRIDGE_BURN, LABEL_INFRA; optional REWARDS_OWNER (default DEPLOYER),
///      REWARDS_GUARDIAN (the watcher's revoke-only key; default none), REWARDS_DELAY (seconds, default 12 h).
///      LABEL_WETH is refused on Base. verify() optional: HOLDER_REWARDS + LABEL_SPLITTER (both) instead of the
///      broadcast file.
contract DeployLabel is LabelDeployBase {
    string public constant SCRIPT_FILE = "DeployLabel.s.sol";
    string public constant PREVIEW_RECORD = "deployments/label-base.preview.json";
    string public constant RECORD = "deployments/label-base.json";
    /// @notice A root waits this long before it pays, so a bad root can be caught and revoked. Fixed at deploy: an
    ///         immutable of HolderRewards, which nobody can change later.
    uint64 public constant DEFAULT_ROOT_DELAY = 12 hours;
    uint64 public constant MIN_ROOT_DELAY = 1 hours;

    struct Config {
        address deployer;
        /// @dev HolderRewards owner: rotates the keeper, revokes a pending root. A hardware wallet or a Safe.
        address owner;
        /// @dev HolderRewards keeper: the rewards bot's key (posts roots, releases the splitters), gas only.
        address keeper;
        /// @dev HolderRewards guardian: the watcher's key on another host, may only revoke a pending root. 0 = none.
        address guardian;
        uint64 rootDelay;
        /// @dev Keeper-held EOA: bridges its USDC to Robinhood as ETH, forwarded to PulseTreasury.
        address burn;
        address infra;
        /// @dev Must be zero: unwrapped WETH would become ETH, which HolderRewards only sweeps to infra anyway.
        address weth;
    }

    struct Deployment {
        HolderRewards rewards;
        RevenueSplitter splitter;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = loadConfig();
        checkInputs(c);
        d = deploy(c);
        check(c, d);
        summary(c, d, "local run (nothing is sent without --broadcast)");
        Created[2] memory x;
        (x[0].addr, x[1].addr) = (address(d.rewards), address(d.splitter));
        writeRecord(c, x, "simulated", _recordPath(PREVIEW_RECORD));
    }

    /// @notice After the broadcast confirmed: reads the live contracts back. Never sends anything.
    function verify() external returns (Deployment memory d) {
        Config memory c = loadConfig();
        _chain(BASE_CHAIN_ID, "Base");
        Created[2] memory x = loadDeployment();
        d = Deployment(HolderRewards(payable(x[0].addr)), RevenueSplitter(payable(x[1].addr)));
        check(c, d);
        summary(c, d, "VERIFIED on chain");
        writeRecord(c, x, "verified", _recordPath(RECORD));
    }

    function loadConfig() public view returns (Config memory c) {
        c.deployer = vm.envAddress("DEPLOYER");
        c.owner = vm.envOr("REWARDS_OWNER", c.deployer);
        c.keeper = vm.envAddress("REWARDS_KEEPER");
        c.guardian = vm.envOr("REWARDS_GUARDIAN", address(0));
        c.rootDelay = uint64(vm.envOr("REWARDS_DELAY", uint256(DEFAULT_ROOT_DELAY)));
        c.burn = vm.envAddress("BRIDGE_BURN");
        c.infra = vm.envAddress("LABEL_INFRA");
        c.weth = vm.envOr("LABEL_WETH", address(0));
    }

    function checkInputs(Config memory c) public view {
        _chain(BASE_CHAIN_ID, "Base");
        _nonzero(c.deployer, "DEPLOYER");
        _nonzero(c.owner, "REWARDS_OWNER");
        _nonzero(c.keeper, "REWARDS_KEEPER");
        _nonzero(c.burn, "BRIDGE_BURN");
        _nonzero(c.infra, "LABEL_INFRA");
        _distinct(c.keeper, c.deployer, "REWARDS_KEEPER and DEPLOYER");
        _distinct(c.keeper, c.owner, "REWARDS_KEEPER and REWARDS_OWNER");
        _distinct(c.keeper, c.burn, "REWARDS_KEEPER and BRIDGE_BURN");
        _distinct(c.keeper, c.infra, "REWARDS_KEEPER and LABEL_INFRA");
        _distinct(c.burn, c.infra, "BRIDGE_BURN and LABEL_INFRA");
        _distinct(c.burn, c.deployer, "BRIDGE_BURN and DEPLOYER");
        _distinct(c.burn, c.owner, "BRIDGE_BURN and REWARDS_OWNER");
        _isEoa(c.keeper, "REWARDS_KEEPER");
        _isEoa(c.burn, "BRIDGE_BURN");
        if (c.guardian != address(0)) {
            _distinct(c.guardian, c.keeper, "REWARDS_GUARDIAN and REWARDS_KEEPER");
            _distinct(c.guardian, c.deployer, "REWARDS_GUARDIAN and DEPLOYER");
            _distinct(c.guardian, c.owner, "REWARDS_GUARDIAN and REWARDS_OWNER");
            _distinct(c.guardian, c.burn, "REWARDS_GUARDIAN and BRIDGE_BURN");
            _distinct(c.guardian, c.infra, "REWARDS_GUARDIAN and LABEL_INFRA");
            _isEoa(c.guardian, "REWARDS_GUARDIAN");
        }
        require(
            c.rootDelay >= MIN_ROOT_DELAY && c.rootDelay <= 7 days, "REWARDS_DELAY: between 3600 (1 h) and 604800 (7 days)"
        );
        require(
            c.weth == address(0),
            "LABEL_WETH: not on Base (unwrapped WETH is ETH, which HolderRewards cannot use); leave it unset"
        );
        _hasCode(BASE_USDC, "USDC");
        _decimals6(BASE_USDC, "USDC");
    }

    function split(Config memory c, address rewards) public pure returns (Split memory) {
        return Split({holders: rewards, burn: c.burn, infra: c.infra, burnEthOnly: false, weth: address(0), tokenSink: c.infra});
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        vm.startBroadcast(c.deployer);
        d.rewards = new HolderRewards(IERC20Rewards(BASE_USDC), c.owner, c.keeper, c.guardian, c.rootDelay, c.infra);
        d.splitter = _deploySplit(split(c, address(d.rewards)));
        vm.stopBroadcast();
    }

    /// @dev Reads every setting back, and the code against this build; reverts on the first mismatch.
    function check(Config memory c, Deployment memory d) public view {
        _hasCode(address(d.rewards), "HolderRewards");
        _checkCode(address(d.rewards), "HolderRewards");
        _checkCode(address(d.splitter), "RevenueSplitter");
        require(address(d.rewards.usdc()) == BASE_USDC, "HolderRewards mismatch: usdc");
        require(d.rewards.owner() == c.owner, "HolderRewards mismatch: owner");
        require(d.rewards.keeper() == c.keeper, "HolderRewards mismatch: keeper");
        require(d.rewards.guardian() == c.guardian, "HolderRewards mismatch: guardian");
        require(d.rewards.rootDelay() == c.rootDelay, "HolderRewards mismatch: rootDelay");
        require(d.rewards.sweepTo() == c.infra, "HolderRewards mismatch: sweepTo");
        _checkSplit(d.splitter, split(c, address(d.rewards)), "LabelSplitter");
    }

    function loadDeployment() public view returns (Created[2] memory x) {
        address r = vm.envOr("HOLDER_REWARDS", address(0));
        address s = vm.envOr("LABEL_SPLITTER", address(0));
        if (r != address(0) || s != address(0)) {
            require(r != address(0) && s != address(0), "set both HOLDER_REWARDS and LABEL_SPLITTER, or neither");
            (x[0].addr, x[1].addr) = (r, s);
            return x;
        }
        return fromBroadcast(_broadcastFile(SCRIPT_FILE));
    }

    function fromBroadcast(string memory path) public view returns (Created[2] memory x) {
        require(vm.exists(path), string.concat("no broadcast file at ", path, "; set HOLDER_REWARDS and LABEL_SPLITTER instead"));
        string memory json = vm.readFile(path);
        x[0] = _created(json, "HolderRewards", 0);
        x[1] = _created(json, "RevenueSplitter", 0);
    }

    function summary(Config memory c, Deployment memory d, string memory status) public view {
        console2.log("== Label money on Base", block.chainid, status);
        console2.log("  HolderRewards (no withdrawal)   ", address(d.rewards));
        console2.log("    owner (rotate keeper, revoke) ", c.owner);
        console2.log("    keeper (posts roots, gas only)", c.keeper);
        console2.log("    guardian (revoke only, 0=none)", c.guardian);
        console2.log("    sweep to (ETH, other tokens)  ", c.infra);
        console2.log("    root delay (seconds)          ", uint256(c.rootDelay));
        _logSplit(d.splitter, split(c, address(d.rewards)), "HolderRewards                   ", "burn bridge wallet (-> ETH)     ");
        console2.log("    USDC (x402 asset)             ", BASE_USDC);
        console2.log("  NEXT: set MUSIC_PAY_TO to the splitter only after verify() passes (docs/DEPLOY.md)");
    }

    function writeRecord(Config memory c, Created[2] memory x, string memory status, string memory path) public {
        string memory k = "label";
        _recordHead(k, "base", status);
        _recordCreated(k, "holderRewards", x[0]);
        _recordCreated(k, "labelSplitter", x[1]);
        vm.serializeAddress(k, "deployer", c.deployer);
        vm.serializeAddress(k, "rewardsOwner", c.owner);
        vm.serializeAddress(k, "rewardsKeeper", c.keeper);
        vm.serializeAddress(k, "rewardsGuardian", c.guardian);
        vm.serializeUint(k, "rootDelay", c.rootDelay);
        vm.serializeAddress(k, "burnBridge", c.burn);
        vm.serializeAddress(k, "infra", c.infra);
        vm.serializeAddress(k, "tokenSink", c.infra);
        vm.serializeAddress(k, "sweepTo", c.infra);
        vm.serializeAddress(k, "weth", address(0));
        vm.serializeAddress(k, "usdc", BASE_USDC);
        string memory json =
            vm.serializeString(k, "shares", "5000 HolderRewards / 2500 burn bridge / 2500 infra; no owner, immutable");
        vm.writeJson(json, path);
        console2.log("  record written:", path);
    }
}
