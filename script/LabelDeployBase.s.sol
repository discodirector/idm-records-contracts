// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {TreasuryFeeder} from "../src/TreasuryFeeder.sol";

interface IERC20Meta {
    function decimals() external view returns (uint8);
}

/// @notice Shared inputs, checks and records for the label deploy scripts (DeployRecords on Robinhood, DeployLabel on
///         Base). No script reads a private key: Forge signs with the owner's own --account / --ledger / --trezor for
///         the address in DEPLOYER. Without --broadcast a run only simulates. Owner checklist: docs/DEPLOY.md.
abstract contract LabelDeployBase is Script {
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 public constant BASE_CHAIN_ID = 8453;

    // Robinhood Chain 4663
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant TREASURY = 0xAb64b47daA0f68e50BDF776e73B4245D78575a6c;
    address public constant IDM = 0x4Fe9f3823791c8b187B81aB8B7398d793FEd28f6;

    // Base 8453
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    /// @notice The ETH/USDG Uniswap v4 pool both feeders swap in: 0.05%, tick spacing 10, no hooks.
    uint24 public constant RH_POOL_FEE = 500;
    int24 public constant RH_TICK_SPACING = 10;
    /// @dev ETH priced in USDG must sit in this band, or the pool is not the one we mean (units: USDG per ETH).
    uint256 public constant MIN_ETH_PRICE = 100e6;
    uint256 public constant MAX_ETH_PRICE = 1_000_000e6;
    /// @notice The feeders' price band at deploy: RewardFeeder's floor this far under the pool's ETH price,
    ///         TreasuryFeeder's ceiling this far over it (audit 2026-11-13). The owner moves it later with
    ///         setFloor / setCeiling.
    uint256 public constant FEED_BAND_BPS = 2500;

    /// @notice Label shares, both splitters: holders / $IDM buy and burn / infra.
    uint16 public constant HOLDERS_BPS = 5000;
    uint16 public constant BURN_BPS = 2500;
    uint16 public constant INFRA_BPS = 2500;

    // ---------------------------------------------------------------- input checks

    function _nonzero(address a, string memory what) internal pure {
        require(a != address(0), string.concat(what, ": zero address"));
    }

    function _distinct(address a, address b, string memory what) internal pure {
        require(a != b, string.concat(what, ": must be different addresses"));
    }

    function _hasCode(address a, string memory what) internal view {
        require(a.code.length > 0, string.concat(what, ": no contract code at this address"));
    }

    /// @dev A key the server holds (signer, keeper, bridge wallet) must be a plain EOA.
    function _isEoa(address a, string memory what) internal view {
        require(a.code.length == 0, string.concat(what, ": must be a plain wallet (EOA), found contract code"));
    }

    function _decimals6(address token, string memory what) internal view {
        require(IERC20Meta(token).decimals() == 6, string.concat(what, ": expected 6 decimals"));
    }

    function _chain(uint256 id, string memory name) internal view {
        require(block.chainid == id, string.concat("wrong chain: expected ", name, " ", vm.toString(id)));
    }

    /// @dev The ETH/USDG 0.05% pool exists, has liquidity, and prices ETH sanely.
    function _checkEthUsdgPool() internal view returns (uint256 usdgPerEth, uint128 liquidity) {
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), RH_POOL_FEE, RH_TICK_SPACING, IHooks(address(0)));
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(POOL_MANAGER), PoolIdLibrary.toId(k));
        require(sqrtPriceX96 > 0, "ETH/USDG 0.05% pool: not initialized");
        liquidity = StateLibrary.getLiquidity(IPoolManager(POOL_MANAGER), PoolIdLibrary.toId(k));
        require(liquidity > 0, "ETH/USDG 0.05% pool: no liquidity");
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        usdgPerEth = FullMath.mulDiv(priceX96, 1e18, 1 << 96);
        require(usdgPerEth >= MIN_ETH_PRICE && usdgPerEth <= MAX_ETH_PRICE, "ETH/USDG 0.05% pool: price out of range");
    }

    /// @dev RewardFeeder's floor and TreasuryFeeder's ceiling (USDG per 1 ETH) from the pool's price now.
    function _feedFloor(uint256 usdgPerEth) internal pure returns (uint256) {
        return usdgPerEth * (10_000 - FEED_BAND_BPS) / 10_000;
    }

    function _feedCeiling(uint256 usdgPerEth) internal pure returns (uint256) {
        return usdgPerEth * (10_000 + FEED_BAND_BPS) / 10_000;
    }

    /// @dev A band still sane against the pool's price at verify time: on the right side of it, within half of it.
    function _checkBand(uint256 floorOrCeiling, bool isFloor, string memory what) internal view {
        (uint256 price,) = _checkEthUsdgPool();
        if (isFloor) {
            require(floorOrCeiling < price && floorOrCeiling * 2 >= price, string.concat(what, ": floor not 0-50% under the pool price"));
        } else {
            require(floorOrCeiling > price && floorOrCeiling <= price * 3 / 2, string.concat(what, ": ceiling not 0-50% over the pool price"));
        }
    }

    /// @dev The one TreasuryFeeder on Robinhood (DeployRecords creates it; the Stations splitter pays it too).
    function _checkTreasuryFeeder(TreasuryFeeder t, address owner_, address keeper_, address infra) internal view {
        _hasCode(address(t), "TreasuryFeeder");
        _checkCode(address(t), "TreasuryFeeder");
        require(t.usdg() == USDG, "TreasuryFeeder mismatch: usdg");
        require(t.treasury() == TREASURY, "TreasuryFeeder mismatch: treasury");
        require(t.owner() == owner_, "TreasuryFeeder mismatch: owner");
        require(t.keeper() == keeper_, "TreasuryFeeder mismatch: keeper");
        require(t.sweepTo() == infra, "TreasuryFeeder mismatch: sweepTo");
        require(address(t.poolManager()) == POOL_MANAGER, "TreasuryFeeder mismatch: PoolManager");
        require(t.fee() == RH_POOL_FEE && t.tickSpacing() == RH_TICK_SPACING, "TreasuryFeeder mismatch: pool fee / tick spacing");
        _checkBand(t.maxUsdgPerEth(), false, "TreasuryFeeder");
    }

    // ---------------------------------------------------------------- code checks

    /// @dev One immutable's place in the runtime code (Forge artifact `immutableReferences`; keys sorted).
    struct CodeRef {
        uint256 length;
        uint256 start;
    }

    /// @notice The live code at `a` is exactly this build's `<name>.sol:<name>` runtime code, immutables aside: the
    ///         immutable slots (filled at deploy) are blanked in both before comparing.
    function _checkCode(address a, string memory name) internal view {
        string memory json = vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
        bytes memory want = vm.parseJsonBytes(json, ".deployedBytecode.object");
        bytes memory got = a.code;
        require(got.length == want.length, string.concat(name, " code mismatch: not this build's contract (length)"));
        string memory refs = ".deployedBytecode.immutableReferences";
        if (vm.keyExistsJson(json, refs)) {
            string[] memory keys = vm.parseJsonKeys(json, refs);
            for (uint256 k; k < keys.length; ++k) {
                CodeRef[] memory r = abi.decode(vm.parseJson(json, string.concat(refs, ".", keys[k])), (CodeRef[]));
                for (uint256 i; i < r.length; ++i) {
                    for (uint256 j; j < r[i].length; ++j) {
                        got[r[i].start + j] = 0;
                        want[r[i].start + j] = 0;
                    }
                }
            }
        }
        require(keccak256(got) == keccak256(want), string.concat(name, " code mismatch: not this build's contract"));
    }

    // ---------------------------------------------------------------- deployment records of other steps

    /// @notice An address from another step's verified deployment record (deployments/*.json), or zero if the file is
    ///         not there. `envPath` overrides the file's path.
    function _fromRecord(string memory envPath, string memory defaultPath, string memory key)
        internal
        view
        returns (address a)
    {
        string memory path = vm.envOr(envPath, defaultPath);
        if (!vm.exists(path)) return address(0);
        string memory json = vm.readFile(path);
        require(
            keccak256(bytes(vm.parseJsonString(json, ".status"))) == keccak256("verified"),
            string.concat(path, ": not a verified record (run that step's verify() first)")
        );
        a = vm.parseJsonAddress(json, string.concat(".", key));
    }

    // ---------------------------------------------------------------- splitter

    struct Split {
        address holders;
        address burn;
        address infra;
        bool burnEthOnly;
        address weth;
        address tokenSink;
    }

    function _deploySplit(Split memory p) internal returns (RevenueSplitter) {
        address[] memory a = new address[](3);
        (a[0], a[1], a[2]) = (p.holders, p.burn, p.infra);
        uint16[] memory b = new uint16[](3);
        (b[0], b[1], b[2]) = (HOLDERS_BPS, BURN_BPS, INFRA_BPS);
        bool[] memory e = new bool[](3);
        e[1] = p.burnEthOnly;
        return new RevenueSplitter(a, b, e, p.weth, p.tokenSink);
    }

    /// @dev Reads every immutable of a deployed splitter back and reverts on the first mismatch.
    function _checkSplit(RevenueSplitter s, Split memory p, string memory what) internal view {
        _hasCode(address(s), what);
        (address[] memory a, uint16[] memory b, bool[] memory e) = s.payees();
        require(a.length == 3 && b.length == 3 && e.length == 3, string.concat(what, " mismatch: payee count"));
        require(a[0] == p.holders, string.concat(what, " mismatch: holders payee"));
        require(a[1] == p.burn, string.concat(what, " mismatch: burn payee"));
        require(a[2] == p.infra, string.concat(what, " mismatch: infra payee"));
        require(b[0] == HOLDERS_BPS && b[1] == BURN_BPS && b[2] == INFRA_BPS, string.concat(what, " mismatch: shares"));
        require(!e[0] && e[1] == p.burnEthOnly && !e[2], string.concat(what, " mismatch: ethOnly flags"));
        require(s.weth() == p.weth, string.concat(what, " mismatch: weth"));
        require(s.tokenSink() == p.tokenSink, string.concat(what, " mismatch: tokenSink"));
        require(s.BPS() == 10_000, string.concat(what, " mismatch: BPS"));
    }

    function _logSplit(RevenueSplitter s, Split memory p, string memory holdersName, string memory burnName) internal pure {
        console2.log("  splitter (no owner, immutable)  ", address(s));
        console2.log(string.concat("    50% ", holdersName), p.holders);
        console2.log(string.concat("    25% ", burnName), p.burn);
        console2.log("    25% infra                     ", p.infra);
        console2.log("    burn payee takes ETH only     ", p.burnEthOnly);
        console2.log("    weth (unwrapped, 0 = none)    ", p.weth);
        console2.log("    token sink (ethOnly's tokens) ", p.tokenSink);
    }

    // ---------------------------------------------------------------- deployment evidence

    struct Created {
        address addr;
        bytes32 tx;
        uint256 blockNumber;
    }

    /// @notice Forge's own record of a broadcast run, relative to the contracts/ directory.
    function _broadcastFile(string memory scriptFile) internal view returns (string memory) {
        return vm.envOr(
            "DEPLOY_BROADCAST",
            string.concat("broadcast/", scriptFile, "/", vm.toString(block.chainid), "/run-latest.json")
        );
    }

    /// @dev The `nth` (0-based) CREATE of `contractName` in a Forge broadcast file, with its tx hash and block.
    function _created(string memory json, string memory contractName, uint256 nth) internal view returns (Created memory c) {
        uint256 seen;
        for (uint256 i;; ++i) {
            string memory t = string.concat(".transactions[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, t)) break;
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(t, ".transactionType")))) != keccak256("CREATE")) {
                continue;
            }
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(t, ".contractName")))) != keccak256(bytes(contractName))) {
                continue;
            }
            if (seen++ < nth) continue;
            c.addr = vm.parseJsonAddress(json, string.concat(t, ".contractAddress"));
            c.tx = vm.parseJsonBytes32(json, string.concat(t, ".hash"));
            c.blockNumber = _receiptBlock(json, c.tx);
            return c;
        }
        revert(string.concat("broadcast file: no CREATE of ", contractName));
    }

    function _receiptBlock(string memory json, bytes32 txHash) private view returns (uint256) {
        for (uint256 i;; ++i) {
            string memory r = string.concat(".receipts[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, r)) break;
            if (vm.parseJsonBytes32(json, string.concat(r, ".transactionHash")) != txHash) continue;
            require(vm.parseJsonUint(json, string.concat(r, ".status")) == 1, "broadcast file: a deploy transaction failed");
            return vm.parseJsonUint(json, string.concat(r, ".blockNumber"));
        }
        return 0; // sent but no receipt recorded
    }

    // ---------------------------------------------------------------- records

    /// @dev Common head of a deployment record; `status` is "simulated" (run) or "verified" (read back on chain).
    function _recordHead(string memory k, string memory network, string memory status) internal {
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "network", network);
        vm.serializeString(k, "status", status);
        vm.serializeUint(k, "checkedBlock", block.number);
        vm.serializeUint(k, "checkedAt", block.timestamp);
    }

    function _recordCreated(string memory k, string memory name, Created memory c) internal {
        vm.serializeAddress(k, name, c.addr);
        if (c.tx != bytes32(0)) vm.serializeBytes32(k, string.concat(name, "Tx"), c.tx);
        if (c.blockNumber != 0) vm.serializeUint(k, string.concat(name, "Block"), c.blockNumber);
    }

    function _recordPath(string memory defaultPath) internal view returns (string memory) {
        return vm.envOr("DEPLOY_RECORD", defaultPath);
    }
}
