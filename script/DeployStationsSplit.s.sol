// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {TreasuryFeeder} from "../src/TreasuryFeeder.sol";
import {LabelDeployBase} from "./LabelDeployBase.s.sol";

interface IHolderRewardsView {
    function usdc() external view returns (address);
}

interface IRewardFeederView {
    function rewardToken() external view returns (address);
    function records() external view returns (address);
    function keeper() external view returns (address);
}

/// @title DeployStationsSplit — the Stations income split, one splitter per payment chain (owner-run; docs/DEPLOY.md)
/// @notice The USD part of station service fees and subscriptions is paid in stablecoins to the station pay-to
///         (docs/STATIONS.md). This RevenueSplitter becomes that pay-to on its chain and splits every payment in four,
///         immutably, no owner:
///           1/4 IDM Records holders: Base -> HolderRewards (its shared pool); Robinhood -> RewardFeeder (the pot's
///               shared pool at its next feed)
///           1/4 $IDM buy and burn: Base -> the bridge keeper's burn wallet (bridged to Robinhood as ETH for
///               PulseTreasury); Robinhood -> the TreasuryFeeder DeployRecords created (USDG -> ETH -> PulseTreasury;
///               it is also the royalty splitter's token sink, so one feeder and one keeper serve both)
///           1/4 IMD buy and burn: STATIONS_IMD_BURN
///           1/4 infra: LABEL_INFRA
///         Anyone may release (`releaseToken(stable)`); the rewards keeper (Base) and the payout keeper (Robinhood) do
///         it on their schedule. Run once per chain: `--rpc-url $BASE_RPC` or `--rpc-url $RH_RPC`, after the step that
///         deployed that chain's holders contract was verified: the holders payee must be the one in its record
///         (deployments/label-base.json, deployments/records-robinhood.json).
/// @dev Env: DEPLOYER, STATIONS_IMD_BURN, LABEL_INFRA; Base: HOLDER_REWARDS, BRIDGE_BURN; Robinhood: PAYOUT_FEEDER,
///      PAYOUT_KEEPER, optional RECORDS_OWNER (the feeders' owner; default DEPLOYER), RECORDS_CONTRACT and
///      TREASURY_FEEDER (default: from the records record, which they must match). STATIONS_LABEL_RECORD /
///      STATIONS_RECORDS_RECORD override the record paths. verify() optional: STATIONS_SPLITTER instead of the
///      broadcast file.
contract DeployStationsSplit is LabelDeployBase {
    uint16 public constant QUARTER = 2500;
    string public constant SCRIPT_FILE = "DeployStationsSplit.s.sol";
    string public constant LABEL_RECORD = "deployments/label-base.json";
    string public constant RECORDS_RECORD = "deployments/records-robinhood.json";

    struct Config {
        address deployer;
        /// @dev HolderRewards (Base) or RewardFeeder (Robinhood).
        address holders;
        /// @dev Base: the burn bridge wallet. Robinhood: unused (the $IDM payee is the TreasuryFeeder).
        address idmBurn;
        address imdBurn;
        address infra;
        /// @dev The holders contract and (Base) burn wallet named by the earlier step's verified record.
        address recordHolders;
        address recordBurn;
        /// @dev Robinhood: IDM Records (the feeder must feed it), the feeders' owner and keeper, the TreasuryFeeder
        ///      (and the one in the verified records record).
        address records;
        address owner;
        address keeper;
        address treasuryFeeder;
        address recordTreasuryFeeder;
    }

    struct Deployment {
        RevenueSplitter splitter;
        /// @dev Robinhood only (zero on Base): not deployed here, DeployRecords' one.
        TreasuryFeeder treasuryFeeder;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = loadConfig();
        checkInputs(c);
        d = deploy(c);
        check(c, d);
        summary(c, d, "local run (nothing is sent without --broadcast)");
        Created[2] memory x;
        (x[0].addr, x[1].addr) = (address(d.splitter), address(d.treasuryFeeder));
        writeRecord(c, x, "simulated", _recordPath(recordFile(true)));
    }

    /// @notice After the broadcast confirmed: reads the live contracts back. Never sends anything.
    function verify() external returns (Deployment memory d) {
        Config memory c = loadConfig();
        Created[2] memory x = loadDeployment();
        x[1].addr = c.treasuryFeeder;
        d = Deployment(RevenueSplitter(payable(x[0].addr)), TreasuryFeeder(payable(c.treasuryFeeder)));
        check(c, d);
        summary(c, d, "VERIFIED on chain");
        writeRecord(c, x, "verified", _recordPath(recordFile(false)));
    }

    function onBase() public view returns (bool) {
        require(block.chainid == BASE_CHAIN_ID || block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain: expected Base 8453 or Robinhood Chain 4663");
        return block.chainid == BASE_CHAIN_ID;
    }

    function network() public view returns (string memory) {
        return onBase() ? "base" : "robinhood";
    }

    /// @notice The stablecoin this chain's station payments arrive in.
    function stable() public view returns (address) {
        return onBase() ? BASE_USDC : USDG;
    }

    function recordFile(bool preview) public view returns (string memory) {
        return string.concat("deployments/stations-split-", network(), preview ? ".preview.json" : ".json");
    }

    function loadConfig() public view returns (Config memory c) {
        c.deployer = vm.envAddress("DEPLOYER");
        c.imdBurn = vm.envAddress("STATIONS_IMD_BURN");
        c.infra = vm.envAddress("LABEL_INFRA");
        if (onBase()) {
            c.holders = vm.envAddress("HOLDER_REWARDS");
            c.idmBurn = vm.envOr("BRIDGE_BURN", address(0));
            c.recordHolders = _fromRecord("STATIONS_LABEL_RECORD", LABEL_RECORD, "holderRewards");
            c.recordBurn = _fromRecord("STATIONS_LABEL_RECORD", LABEL_RECORD, "burnBridge");
        } else {
            require(
                vm.envOr("STATIONS_IDM_BURN", address(0)) == address(0),
                "STATIONS_IDM_BURN: not used any more; on Robinhood the $IDM quarter goes to DeployRecords' TreasuryFeeder"
            );
            c.holders = vm.envAddress("PAYOUT_FEEDER");
            c.recordHolders = _fromRecord("STATIONS_RECORDS_RECORD", RECORDS_RECORD, "rewardFeeder");
            c.records = vm.envOr("RECORDS_CONTRACT", _fromRecord("STATIONS_RECORDS_RECORD", RECORDS_RECORD, "records"));
            require(
                vm.envOr("STATIONS_OWNER", address(0)) == address(0),
                "STATIONS_OWNER: not used any more; the TreasuryFeeder's owner is RECORDS_OWNER (DeployRecords)"
            );
            c.owner = vm.envOr("RECORDS_OWNER", c.deployer);
            c.keeper = vm.envAddress("PAYOUT_KEEPER");
            c.recordTreasuryFeeder = _fromRecord("STATIONS_RECORDS_RECORD", RECORDS_RECORD, "treasuryFeeder");
            c.treasuryFeeder = vm.envOr("TREASURY_FEEDER", c.recordTreasuryFeeder);
        }
    }

    function checkInputs(Config memory c) public view {
        bool base = onBase();
        string memory holdersName = base ? "HOLDER_REWARDS" : "PAYOUT_FEEDER";
        _nonzero(c.deployer, "DEPLOYER");
        _nonzero(c.holders, holdersName);
        _nonzero(c.imdBurn, "STATIONS_IMD_BURN");
        _nonzero(c.infra, "LABEL_INFRA");
        _hasCode(c.holders, holdersName);
        _hasCode(stable(), base ? "USDC" : "USDG");
        _decimals6(stable(), base ? "USDC" : "USDG");
        // The holders payee must be the contract the earlier step deployed and verified, not just any lookalike.
        require(
            c.recordHolders != address(0),
            string.concat(holdersName, ": no verified record of it (run ", base ? "DeployLabel" : "DeployRecords", " verify() first)")
        );
        require(c.holders == c.recordHolders, string.concat(holdersName, ": not the one in the verified deployment record"));
        _distinct(c.imdBurn, TREASURY, "STATIONS_IMD_BURN and PulseTreasury");
        if (base) {
            _nonzero(c.idmBurn, "BRIDGE_BURN");
            _checkCode(c.holders, "HolderRewards");
            require(IHolderRewardsView(c.holders).usdc() == BASE_USDC, "HOLDER_REWARDS: not a HolderRewards paying Base USDC");
            _isEoa(c.idmBurn, "BRIDGE_BURN");
            // The bridge keeper accepts the Stations splitter only if it pays the LabelSplitter's burn wallet.
            require(c.idmBurn == c.recordBurn, "BRIDGE_BURN: not the LabelSplitter's burn wallet in deployments/label-base.json");
            _distinctPayees([c.holders, c.idmBurn, c.imdBurn, c.infra]);
        } else {
            _nonzero(c.records, "RECORDS_CONTRACT");
            _nonzero(c.owner, "RECORDS_OWNER");
            _nonzero(c.treasuryFeeder, "TREASURY_FEEDER");
            require(
                c.recordTreasuryFeeder != address(0),
                "TREASURY_FEEDER: no verified record of it (run DeployRecords verify() first)"
            );
            require(c.treasuryFeeder == c.recordTreasuryFeeder, "TREASURY_FEEDER: not the one in the verified deployment record");
            _nonzero(c.keeper, "PAYOUT_KEEPER");
            _checkCode(c.holders, "RewardFeeder");
            IRewardFeederView f = IRewardFeederView(c.holders);
            require(f.rewardToken() == USDG, "PAYOUT_FEEDER: not the IDM Records RewardFeeder (USDG)");
            require(f.records() == c.records, "PAYOUT_FEEDER: does not feed the deployed IDM Records");
            require(f.keeper() != address(0), "PAYOUT_FEEDER: no keeper");
            require(c.keeper == f.keeper(), "PAYOUT_KEEPER: not the RewardFeeder's keeper (one payout bot runs both feeders)");
            _isEoa(c.keeper, "PAYOUT_KEEPER");
            _distinct(c.keeper, c.owner, "PAYOUT_KEEPER and RECORDS_OWNER");
            _distinct(c.imdBurn, c.keeper, "STATIONS_IMD_BURN and PAYOUT_KEEPER");
            _hasCode(TREASURY, "PulseTreasury");
            _hasCode(POOL_MANAGER, "PoolManager");
            _checkTreasuryFeeder(TreasuryFeeder(payable(c.treasuryFeeder)), c.owner, c.keeper, c.infra);
            _distinctPayees([c.holders, c.treasuryFeeder, c.imdBurn, c.infra]);
        }
    }

    function _distinctPayees(address[4] memory a) internal pure {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < i; ++j) require(a[i] != a[j], "stations payees: must be four different addresses");
        }
    }

    function payees(Config memory c, address idm)
        public
        pure
        returns (address[] memory a, uint16[] memory b, bool[] memory e)
    {
        a = new address[](4);
        (a[0], a[1], a[2], a[3]) = (c.holders, idm, c.imdBurn, c.infra);
        b = new uint16[](4);
        (b[0], b[1], b[2], b[3]) = (QUARTER, QUARTER, QUARTER, QUARTER);
        e = new bool[](4);
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        bool base = onBase();
        vm.startBroadcast(c.deployer);
        if (!base) d.treasuryFeeder = TreasuryFeeder(payable(c.treasuryFeeder));
        (address[] memory a, uint16[] memory b, bool[] memory e) =
            payees(c, base ? c.idmBurn : address(d.treasuryFeeder));
        d.splitter = new RevenueSplitter(a, b, e, address(0), c.infra);
        vm.stopBroadcast();
    }

    function check(Config memory c, Deployment memory d) public view {
        bool base = onBase();
        RevenueSplitter s = d.splitter;
        _hasCode(address(s), "StationsSplitter");
        _checkCode(address(s), "RevenueSplitter");
        address idm = base ? c.idmBurn : address(d.treasuryFeeder);
        (address[] memory a, uint16[] memory b, bool[] memory e) = s.payees();
        require(a.length == 4 && b.length == 4 && e.length == 4, "StationsSplitter mismatch: payee count");
        require(a[0] == c.holders, "StationsSplitter mismatch: holders payee");
        require(a[1] == idm, "StationsSplitter mismatch: $IDM burn payee");
        require(a[2] == c.imdBurn, "StationsSplitter mismatch: IMD burn payee");
        require(a[3] == c.infra, "StationsSplitter mismatch: infra payee");
        for (uint256 i; i < 4; ++i) {
            require(b[i] == QUARTER, "StationsSplitter mismatch: shares");
            require(!e[i], "StationsSplitter mismatch: ethOnly flags");
        }
        require(s.weth() == address(0), "StationsSplitter mismatch: weth");
        require(s.tokenSink() == c.infra, "StationsSplitter mismatch: tokenSink");
        if (base) {
            require(address(d.treasuryFeeder) == address(0), "StationsSplitter mismatch: no TreasuryFeeder on Base");
            return;
        }
        require(address(d.treasuryFeeder) == c.treasuryFeeder, "StationsSplitter mismatch: TreasuryFeeder");
        _checkTreasuryFeeder(d.treasuryFeeder, c.owner, c.keeper, c.infra);
    }

    /// @notice [splitter, (unused here: the TreasuryFeeder comes from the config)]: env, or Forge's broadcast file of run().
    function loadDeployment() public view returns (Created[2] memory x) {
        x[0].addr = vm.envOr("STATIONS_SPLITTER", address(0));
        if (x[0].addr != address(0)) return x;
        string memory path = _broadcastFile(SCRIPT_FILE);
        require(vm.exists(path), string.concat("no broadcast file at ", path, "; set STATIONS_SPLITTER instead"));
        x[0] = _created(vm.readFile(path), "RevenueSplitter", 0);
    }

    function summary(Config memory c, Deployment memory d, string memory status) public view {
        bool base = onBase();
        console2.log(string.concat("== Stations splitter on ", network()), block.chainid, status);
        console2.log("  splitter (no owner, immutable)  ", address(d.splitter));
        console2.log(base ? "    1/4 holders: HolderRewards    " : "    1/4 holders: RewardFeeder     ", c.holders);
        if (base) {
            console2.log("    1/4 $IDM: burn bridge wallet  ", c.idmBurn);
        } else {
            console2.log("    1/4 $IDM: TreasuryFeeder (from DeployRecords)", address(d.treasuryFeeder));
            console2.log("      USDG -> ETH -> PulseTreasury", TREASURY);
            console2.log("      owner (replaces the keeper) ", c.owner);
            console2.log("      keeper (swaps)              ", c.keeper);
            console2.log("      ceiling USDG/ETH (owner)    ", d.treasuryFeeder.maxUsdgPerEth());
        }
        console2.log("    1/4 IMD buy and burn          ", c.imdBurn);
        console2.log("    1/4 infra (and token sink)    ", c.infra);
        console2.log("    payments in                   ", stable());
        console2.log("  NEXT: put it in STATION_PAY_TO for this chain only after verify() passes (docs/DEPLOY.md)");
    }

    function writeRecord(Config memory c, Created[2] memory x, string memory status, string memory path) public {
        string memory k = "stations";
        _recordHead(k, network(), status);
        _recordCreated(k, "stationsSplitter", x[0]);
        if (!onBase()) {
            vm.serializeAddress(k, "treasuryFeeder", x[1].addr);
            vm.serializeAddress(k, "treasuryFeederOwner", c.owner);
            vm.serializeAddress(k, "keeper", c.keeper);
            vm.serializeAddress(k, "records", c.records);
        }
        vm.serializeAddress(k, "deployer", c.deployer);
        vm.serializeAddress(k, "holders", c.holders);
        vm.serializeAddress(k, "idmBurn", onBase() ? c.idmBurn : x[1].addr);
        vm.serializeAddress(k, "imdBurn", c.imdBurn);
        vm.serializeAddress(k, "infra", c.infra);
        vm.serializeAddress(k, "stable", stable());
        string memory json = vm.serializeString(
            k, "shares", "2500 holders / 2500 $IDM burn / 2500 IMD burn / 2500 infra; no owner, immutable"
        );
        vm.writeJson(json, path);
        console2.log("  record written:", path);
    }
}
