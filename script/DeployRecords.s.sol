// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IDMRecords, IERC20Like, IBalanceOf, ICreatorToken} from "../src/IDMRecords.sol";
import {RewardFeeder, IRecordsPot} from "../src/RewardFeeder.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {TreasuryFeeder} from "../src/TreasuryFeeder.sol";
import {LabelDeployBase, IERC20Meta} from "./LabelDeployBase.s.sol";

/// @notice Limit Break Creator Token Transfer Validator v5 (src/DataTypes.sol, src/CreatorTokenTransferValidator.sol;
///         commit 59adb8b of github.com/limitbreakinc/creator-token-transfer-validator).
struct CollectionSecurityPolicy {
    uint8 rulesetId;
    uint48 listId;
    address customRuleset;
    uint8 globalOptions;
    uint16 rulesetOptions;
    uint16 tokenType;
}

interface ITransferValidatorV5 {
    /// @dev Caller: the collection, its owner() or an admin role holder. Writes only the four values passed.
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
    function getCollectionSecurityPolicy(address collection) external view returns (CollectionSecurityPolicy memory);
    /// @dev Caller: as setRulesetOfCollection.
    function setTokenTypeOfCollection(address collection, uint16 tokenType) external;
}

interface IPulseTreasuryView {
    function idm() external view returns (address);
    function poolManager() external view returns (address);
}

/// @title DeployRecords — IDM Records on Robinhood Chain (owner-run; docs/DEPLOY.md)
/// @notice Order (no cycle: the royalty receiver is set after the splitter exists):
///           1. IDMRecords(owner = DEPLOYER, signer = RECORDS_SIGNER, reward token USDG, hold token $IDM, base URI,
///              no royalty yet)
///           2. RewardFeeder(PoolManager, records, owner = RECORDS_OWNER, keeper = PAYOUT_KEEPER, sweep to infra,
///              ETH/USDG 0.05% pool)
///           3. TreasuryFeeder(PoolManager, USDG, PulseTreasury, owner = RECORDS_OWNER, keeper = PAYOUT_KEEPER, sweep
///              to infra): swaps USDG to ETH for PulseTreasury. Also the Stations splitter's $IDM payee on Robinhood
///              (DeployStationsSplit takes this one, it does not deploy its own).
///           4. RevenueSplitter (royalty receiver): 50% RewardFeeder, 25% TreasuryFeeder ($IDM buy and burn), 25% infra;
///              WETH unwrapped. The TreasuryFeeder sends ETH on to PulseTreasury and swaps USDG to ETH first, so
///              royalties paid in USDG are burned too (swarm audit 2026-11-13, owner decision 2026-11-14; before,
///              PulseTreasury was the ETH-only payee and its share of token royalties went to infra)
///           4a. IDMRecords.setRoyalty(splitter, 5%)
///           5. IDMRecords.setTransferValidator(RECORDS_VALIDATOR) (ERC721-C royalty enforcement; default Limit Break's
///              Creator Token Transfer Validator v5, which is on Robinhood Chain; RECORDS_VALIDATOR=0x0 skips it),
///              then on v5 validator.setTokenTypeOfCollection(records, 721) from the deployer: the collection's own
///              registration runs in a try/catch that a gas estimate starves (Robinhood fork rehearsal 2026-11-14)
///           5a. On v5 (owner decision 2026-11-04): validator.setRulesetOfCollection(records, 0, 0x0, 0, 6), so contract
///              wallets (a Safe) and EIP-7702 wallets may move their own records like plain wallets do, while Limit
///              Break's default list 0 still decides which marketplaces may move them (royalties stay enforced there).
///              RECORDS_ALLOW_WALLET_OTC=0 keeps v5's defaults. `allowWalletOtc()` does the same for a collection that
///              is already deployed (from its owner).
///           6. IDMRecords.transferOwnership(RECORDS_OWNER), only if it differs from DEPLOYER (it then accepts)
///         `run()` checks every input and dependency first, deploys (simulated unless --broadcast), reads it all back,
///         prints a summary and writes deployments/records-robinhood.preview.json. `verify()` reads the live contracts
///         (addresses from Forge's broadcast file or env), checks their code against this build and the validator's
///         code against the hash pinned here, and writes deployments/records-robinhood.json.
/// @dev Env: DEPLOYER (the address Forge signs for), RECORDS_SIGNER, PAYOUT_KEEPER, LABEL_INFRA; optional
///      RECORDS_OWNER (default DEPLOYER), RECORDS_BASE_URI (default https://theidm.fun/records/), RECORDS_VALIDATOR
///      (default DEFAULT_VALIDATOR; the zero address = no validator), RECORDS_VALIDATOR_CODEHASH (default
///      V5_CODEHASH for the default validator; a custom validator is not pinned unless set).
///      verify() optional: RECORDS_CONTRACT + PAYOUT_FEEDER + TREASURY_FEEDER + PAYOUT_SPLITTER (all four) instead of
///      the broadcast file.
contract DeployRecords is LabelDeployBase {
    string public constant NAME = "IDM Records";
    string public constant SYMBOL = "RECORDS";
    string public constant DEFAULT_BASE_URI = "https://theidm.fun/records/";
    uint96 public constant ROYALTY_BPS = 500;
    /// @dev Limit Break's Creator Token Transfer Validator v5 (ERC721-C), at its address on every chain. On Robinhood
    ///      Chain since before 2026-11-04: the same code as on Base except the chain id cached for EIP-712. Its default
    ///      list allows OpenSea's SignedZone and Payment Processor; owners keep moving their own tokens.
    address public constant DEFAULT_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    /// @dev DEFAULT_VALIDATOR's code hash on Robinhood Chain, read 2026-11-04 (`cast codehash`, read-only). A change
    ///      means Limit Break's code there is not the one this collection was checked against.
    bytes32 public constant V5_CODEHASH = 0xcf4eb611d0a4264a3cca483100d883e21545581c69b80e9d0cc29606d4b93dcc;
    /// @dev v5 ruleset id 0: the default (today the whitelist ruleset), kept current by Limit Break.
    uint8 public constant V5_RULESET_DEFAULT = 0;
    /// @dev v5 whitelist options (src/Constants.sol): ALLOW_OTC_FOR_7702_DELEGATES (1 << 1) | ALLOW_OTC_FOR_SMART_WALLETS
    ///      (1 << 2). BLOCK_ALL_OTC (bit 0) and the receiver blocks (bits 3, 4) stay off; global options stay 0.
    uint16 public constant V5_WALLET_OTC = 6;
    /// @dev validateTransfer(address,address,address,uint256), what IDMRecords calls on its validator.
    bytes4 public constant VALIDATION_FUNCTION = 0xcaee23ea;
    uint24 public constant POOL_FEE = RH_POOL_FEE;
    int24 public constant TICK_SPACING = RH_TICK_SPACING;
    string public constant SCRIPT_FILE = "DeployRecords.s.sol";
    string public constant PREVIEW_RECORD = "deployments/records-robinhood.preview.json";
    string public constant RECORD = "deployments/records-robinhood.json";


    struct Config {
        /// @dev Sends every transaction; IDMRecords' first owner.
        address deployer;
        /// @dev Final owner of IDMRecords (signer rotation, base URI, royalty, validator). Default: the deployer.
        address owner;
        /// @dev Voucher signer: the records service's key, holds no funds. Rotatable by the owner.
        address signer;
        /// @dev RewardFeeder.keeper: the payout bot's key. The owner can replace it (setKeeper) and moves its price floor (setFloor).
        address keeper;
        /// @dev 25% of royalties; also where the feeders sweep tokens other than USDG.
        address infra;
        /// @dev ERC721-C transfer validator (default DEFAULT_VALIDATOR); zero = royalties are not enforced on transfers.
        address validator;
        /// @dev The validator's expected code hash; zero = not pinned.
        bytes32 validatorCodehash;
        /// @dev Lets contract and EIP-7702 wallets move their own records (v5 ruleset options 6). Limit Break v5 only.
        bool walletOtc;
        string baseURI;
        /// @dev Token ids open to vouchers at deploy (drop 1's highest id); 0 = none until the owner calls setMintableUpTo.
        uint256 mintableUpTo;
    }

    struct Deployment {
        IDMRecords records;
        RewardFeeder feeder;
        TreasuryFeeder treasuryFeeder;
        RevenueSplitter splitter;
    }

    // ---------------------------------------------------------------- entry points

    function run() external returns (Deployment memory d) {
        Config memory c = loadConfig();
        checkInputs(c);
        d = deploy(c);
        check(c, d);
        summary(c, d, "local run (nothing is sent without --broadcast)");
        Created[4] memory none;
        (none[0].addr, none[1].addr, none[2].addr, none[3].addr) =
            (address(d.records), address(d.feeder), address(d.treasuryFeeder), address(d.splitter));
        writeRecord(c, d, none, "simulated", _recordPath(PREVIEW_RECORD));
    }

    /// @notice After the broadcast confirmed: reads the live contracts back. Never sends anything.
    function verify() external returns (Deployment memory d) {
        Config memory c = loadConfig();
        _chain(ROBINHOOD_CHAIN_ID, "Robinhood Chain");
        Created[4] memory x = loadDeployment();
        d = Deployment(
            IDMRecords(x[0].addr),
            RewardFeeder(payable(x[1].addr)),
            TreasuryFeeder(payable(x[2].addr)),
            RevenueSplitter(payable(x[3].addr))
        );
        check(c, d);
        summary(c, d, "VERIFIED on chain");
        writeRecord(c, d, x, "verified", _recordPath(RECORD));
    }

    // ---------------------------------------------------------------- inputs

    function loadConfig() public view returns (Config memory c) {
        c.deployer = vm.envAddress("DEPLOYER");
        c.owner = vm.envOr("RECORDS_OWNER", c.deployer);
        c.signer = vm.envAddress("RECORDS_SIGNER");
        c.keeper = vm.envAddress("PAYOUT_KEEPER");
        c.infra = vm.envAddress("LABEL_INFRA");
        c.validator = vm.envOr("RECORDS_VALIDATOR", DEFAULT_VALIDATOR);
        c.validatorCodehash =
            vm.envOr("RECORDS_VALIDATOR_CODEHASH", c.validator == DEFAULT_VALIDATOR ? V5_CODEHASH : bytes32(0));
        c.walletOtc = vm.envOr("RECORDS_ALLOW_WALLET_OTC", c.validator == DEFAULT_VALIDATOR);
        c.baseURI = vm.envOr("RECORDS_BASE_URI", DEFAULT_BASE_URI);
        c.mintableUpTo = vm.envOr("RECORDS_MINTABLE_UP_TO", uint256(0));
    }

    /// @notice Everything that can be checked before a single transaction. Reverts with the input's name.
    function checkInputs(Config memory c) public view {
        _chain(ROBINHOOD_CHAIN_ID, "Robinhood Chain");
        _nonzero(c.deployer, "DEPLOYER");
        _nonzero(c.owner, "RECORDS_OWNER");
        _nonzero(c.signer, "RECORDS_SIGNER");
        _nonzero(c.keeper, "PAYOUT_KEEPER");
        _nonzero(c.infra, "LABEL_INFRA");
        // Keys that live on the server are never the owner's, and never each other.
        _distinct(c.signer, c.deployer, "RECORDS_SIGNER and DEPLOYER");
        _distinct(c.signer, c.owner, "RECORDS_SIGNER and RECORDS_OWNER");
        _distinct(c.signer, c.keeper, "RECORDS_SIGNER and PAYOUT_KEEPER");
        _distinct(c.signer, c.infra, "RECORDS_SIGNER and LABEL_INFRA");
        _distinct(c.keeper, c.deployer, "PAYOUT_KEEPER and DEPLOYER");
        _distinct(c.keeper, c.owner, "PAYOUT_KEEPER and RECORDS_OWNER");
        _distinct(c.keeper, c.infra, "PAYOUT_KEEPER and LABEL_INFRA");
        _distinct(c.infra, TREASURY, "LABEL_INFRA and PulseTreasury");
        _isEoa(c.signer, "RECORDS_SIGNER");
        _isEoa(c.keeper, "PAYOUT_KEEPER");
        _checkBaseURI(c.baseURI);
        require(c.mintableUpTo <= 1000, "RECORDS_MINTABLE_UP_TO: at most 1000 (the cap)");
        if (c.validator != address(0)) {
            _hasCode(c.validator, "RECORDS_VALIDATOR");
            _checkValidatorCode(c);
        }
        require(
            !c.walletOtc || c.validator == DEFAULT_VALIDATOR,
            "RECORDS_ALLOW_WALLET_OTC: a Limit Break v5 setting; set it to 0 for another validator or none"
        );

        _hasCode(USDG, "USDG");
        _decimals6(USDG, "USDG");
        // Vouchers carry minHold in $IDM units: the records service counts 18 decimals.
        _hasCode(IDM, "$IDM");
        require(IERC20Meta(IDM).decimals() == 18, "$IDM: expected 18 decimals");
        _hasCode(RH_WETH, "WETH");
        _hasCode(POOL_MANAGER, "PoolManager");
        _hasCode(TREASURY, "PulseTreasury");
        require(IPulseTreasuryView(TREASURY).idm() == IDM, "PulseTreasury: idm() is not $IDM");
        require(IPulseTreasuryView(TREASURY).poolManager() == POOL_MANAGER, "PulseTreasury: wrong PoolManager");
        _checkPool();
    }

    function _checkValidatorCode(Config memory c) internal view {
        if (c.validatorCodehash == bytes32(0)) return;
        require(
            c.validator.codehash == c.validatorCodehash,
            "RECORDS_VALIDATOR: code hash differs from the pinned one (Limit Break v5 as read 2026-11-04)"
        );
    }

    function _checkBaseURI(string memory uri) internal pure {
        bytes memory b = bytes(uri);
        require(b.length > 8 && b[b.length - 1] == "/", "RECORDS_BASE_URI: must end with /");
        require(_startsWith(b, "https://") || _startsWith(b, "ipfs://"), "RECORDS_BASE_URI: must start with https:// or ipfs://");
    }

    function _startsWith(bytes memory b, bytes memory p) private pure returns (bool) {
        if (b.length < p.length) return false;
        for (uint256 i; i < p.length; ++i) {
            if (b[i] != p[i]) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------- deploy

    /// @dev The burn quarter goes to the TreasuryFeeder in any currency: ETH on to PulseTreasury, USDG swapped to ETH
    ///      first, any other token swept to infra. No ETH-only payee, so the token sink is never used.
    function royaltySplit(address feeder, address treasuryFeeder, address infra) public pure returns (Split memory) {
        return Split({
            holders: feeder,
            burn: treasuryFeeder,
            infra: infra,
            burnEthOnly: false,
            weth: RH_WETH,
            tokenSink: infra
        });
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        vm.startBroadcast(c.deployer);
        d.records =
            new IDMRecords(NAME, SYMBOL, c.deployer, c.signer, IERC20Like(USDG), IBalanceOf(IDM), c.baseURI, address(0), 0);
        (uint256 price,) = _checkPool();
        d.feeder = new RewardFeeder(
            IPoolManager(POOL_MANAGER),
            IRecordsPot(address(d.records)),
            c.owner,
            c.keeper,
            c.infra,
            POOL_FEE,
            TICK_SPACING,
            _feedFloor(price)
        );
        d.treasuryFeeder = new TreasuryFeeder(
            IPoolManager(POOL_MANAGER), USDG, TREASURY, c.owner, c.keeper, c.infra, POOL_FEE, TICK_SPACING, _feedCeiling(price)
        );
        d.splitter = _deploySplit(royaltySplit(address(d.feeder), address(d.treasuryFeeder), c.infra));
        d.records.setRoyalty(address(d.splitter), ROYALTY_BPS);
        if (c.validator != address(0)) d.records.setTransferValidator(c.validator);
        // setTransferValidator registers the token type in a try/catch, and a gas estimate finds the cheaper path where
        // that inner call runs out of gas and is caught (seen on a Robinhood fork, 2026-11-14): the owner sets it here.
        if (c.validator == DEFAULT_VALIDATOR) ITransferValidatorV5(c.validator).setTokenTypeOfCollection(address(d.records), 721);
        if (c.mintableUpTo != 0) d.records.setMintableUpTo(c.mintableUpTo);
        // The deployer still owns the collection here, which is who v5 lets set its rules.
        if (c.walletOtc) _setWalletOtc(c.validator, address(d.records));
        if (c.owner != c.deployer) d.records.transferOwnership(c.owner);
        vm.stopBroadcast();
    }

    function _setWalletOtc(address validator, address records) internal {
        ITransferValidatorV5(validator).setRulesetOfCollection(records, V5_RULESET_DEFAULT, address(0), 0, V5_WALLET_OTC);
    }

    /// @notice For a collection already deployed: its owner (RECORDS_OWNER, default DEPLOYER) applies step 5a.
    ///         RECORDS_CONTRACT names it. A Safe owner sends the same call from the Safe instead (docs/DEPLOY.md
    ///         section 10). Simulated unless --broadcast.
    function allowWalletOtc() external {
        Config memory c = loadConfig();
        _chain(ROBINHOOD_CHAIN_ID, "Robinhood Chain");
        IDMRecords n = IDMRecords(vm.envAddress("RECORDS_CONTRACT"));
        require(n.getTransferValidator() == DEFAULT_VALIDATOR, "RECORDS_CONTRACT: its validator is not Limit Break v5");
        _checkValidatorCode(c);
        require(n.owner() == c.owner, "RECORDS_OWNER: not the collection's owner (only it may set the rules)");
        vm.startBroadcast(c.owner);
        _setWalletOtc(DEFAULT_VALIDATOR, address(n));
        vm.stopBroadcast();
        _checkPolicy(n, true);
        console2.log("  v5 ruleset options of", address(n), "now", uint256(V5_WALLET_OTC));
    }

    /// @dev The collection's rules on Limit Break v5: default ruleset, default list 0, no custom ruleset, no global
    ///      options, ERC-721; wallet OTC on or off as decided.
    function _checkPolicy(IDMRecords n, bool walletOtc) internal view {
        CollectionSecurityPolicy memory p = ITransferValidatorV5(DEFAULT_VALIDATOR).getCollectionSecurityPolicy(address(n));
        require(
            p.rulesetId == V5_RULESET_DEFAULT && p.customRuleset == address(0) && p.globalOptions == 0,
            "IDMRecords mismatch: v5 ruleset (want the default ruleset, no custom ruleset, no global options)"
        );
        require(p.listId == 0, "IDMRecords mismatch: v5 list (want Limit Break's default list 0)");
        require(p.tokenType == 721, "IDMRecords mismatch: v5 token type (want 721)");
        require(
            p.rulesetOptions == (walletOtc ? V5_WALLET_OTC : 0),
            walletOtc
                ? "IDMRecords mismatch: v5 options (contract and 7702 wallets not allowed yet: allowWalletOtc())"
                : "IDMRecords mismatch: v5 options (want the defaults)"
        );
    }

    // ---------------------------------------------------------------- read back

    /// @notice Reads every setting of the four contracts back; reverts on the first one that differs from `c`.
    function check(Config memory c, Deployment memory d) public view {
        IDMRecords n = d.records;
        RewardFeeder f = d.feeder;
        _hasCode(address(n), "IDMRecords");
        _hasCode(address(f), "RewardFeeder");
        _checkCode(address(n), "IDMRecords");
        _checkCode(address(f), "RewardFeeder");
        _checkCode(address(d.splitter), "RevenueSplitter");

        require(_eq(n.name(), NAME) && _eq(n.symbol(), SYMBOL), "IDMRecords mismatch: name or symbol");
        if (c.owner == c.deployer) {
            require(n.owner() == c.owner && n.pendingOwner() == address(0), "IDMRecords mismatch: owner");
        } else {
            bool accepted = n.owner() == c.owner && n.pendingOwner() == address(0);
            bool pending = n.owner() == c.deployer && n.pendingOwner() == c.owner;
            require(accepted || pending, "IDMRecords mismatch: owner / pending owner");
        }
        require(n.signer() == c.signer, "IDMRecords mismatch: signer");
        require(address(n.rewardToken()) == USDG, "IDMRecords mismatch: reward token");
        require(address(n.holdToken()) == IDM, "IDMRecords mismatch: hold token");
        require(_eq(n.baseURI(), c.baseURI), "IDMRecords mismatch: base URI");
        require(!n.metadataFrozen(), "IDMRecords mismatch: metadata already frozen");
        require(n.royaltyReceiver() == address(d.splitter) && n.royaltyBps() == ROYALTY_BPS, "IDMRecords mismatch: royalty");
        (address receiver, uint256 amount) = n.royaltyInfo(1, 10_000);
        require(receiver == address(d.splitter) && amount == ROYALTY_BPS, "IDMRecords mismatch: royaltyInfo");
        require(
            n.transferValidator() == c.validator && n.getTransferValidator() == c.validator,
            "IDMRecords mismatch: transfer validator"
        );
        if (c.validator != address(0)) _checkValidatorCode(c);
        if (c.validator == DEFAULT_VALIDATOR) _checkPolicy(n, c.walletOtc);
        if (n.pendingSigner() != address(0)) {
            // A proposal nobody activated within SIGNER_WINDOW can never be activated: cancel it so the state is clean.
            require(
                block.timestamp <= n.pendingSignerAt() + n.SIGNER_WINDOW(),
                "IDMRecords mismatch: a lapsed signer proposal is stored (cancelSigner())"
            );
            revert("IDMRecords mismatch: a signer change is pending (activate or wait)");
        }
        (bytes4 fn, bool isView) = n.getTransferValidationFunction();
        require(fn == VALIDATION_FUNCTION && isView, "IDMRecords mismatch: transfer validation function");
        require(
            n.supportsInterface(type(ICreatorToken).interfaceId) && n.supportsInterface(0xa07d229a),
            "IDMRecords mismatch: no ICreatorToken (ERC721-C)"
        );
        require(n.MAX_SUPPLY() == 1000, "IDMRecords mismatch: MAX_SUPPLY");
        require(n.supportsInterface(0x2a55205a), "IDMRecords mismatch: no ERC-2981");
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(NAME)),
                keccak256("1"),
                ROBINHOOD_CHAIN_ID,
                address(n)
            )
        );
        require(n.DOMAIN_SEPARATOR() == domain, "IDMRecords mismatch: EIP-712 domain");

        require(address(f.records()) == address(n), "RewardFeeder mismatch: records");
        require(f.rewardToken() == USDG, "RewardFeeder mismatch: reward token");
        require(f.keeper() == c.keeper, "RewardFeeder mismatch: keeper");
        require(f.owner() == c.owner, "RewardFeeder mismatch: owner");
        require(f.sweepTo() == c.infra, "RewardFeeder mismatch: sweepTo");
        require(address(f.poolManager()) == POOL_MANAGER, "RewardFeeder mismatch: PoolManager");
        require(f.fee() == POOL_FEE && f.tickSpacing() == TICK_SPACING, "RewardFeeder mismatch: pool fee / tick spacing");
        PoolKey memory k = f.poolKey();
        require(
            Currency.unwrap(k.currency0) == address(0) && Currency.unwrap(k.currency1) == USDG
                && address(k.hooks) == address(0),
            "RewardFeeder mismatch: pool key"
        );
        _checkPool();
        _checkBand(f.minUsdgPerEth(), true, "RewardFeeder");

        _checkTreasuryFeeder(d.treasuryFeeder, c.owner, c.keeper, c.infra);
        _checkSplit(d.splitter, royaltySplit(address(f), address(d.treasuryFeeder), c.infra), "royalty splitter");
    }

    /// @dev The feeder's ETH/USDG pool exists, has liquidity, and prices ETH sanely.
    function _checkPool() internal view returns (uint256 usdgPerEth, uint128 liquidity) {
        return _checkEthUsdgPool();
    }

    // ---------------------------------------------------------------- deployment evidence

    /// @notice The four addresses (and their tx/block when known): env, or Forge's broadcast file of run().
    function loadDeployment() public view returns (Created[4] memory x) {
        address r = vm.envOr("RECORDS_CONTRACT", address(0));
        address f = vm.envOr("PAYOUT_FEEDER", address(0));
        address t = vm.envOr("TREASURY_FEEDER", address(0));
        address s = vm.envOr("PAYOUT_SPLITTER", address(0));
        if (r != address(0) || f != address(0) || t != address(0) || s != address(0)) {
            require(
                r != address(0) && f != address(0) && t != address(0) && s != address(0),
                "set all of RECORDS_CONTRACT, PAYOUT_FEEDER, TREASURY_FEEDER, PAYOUT_SPLITTER, or none"
            );
            (x[0].addr, x[1].addr, x[2].addr, x[3].addr) = (r, f, t, s);
            return x;
        }
        return fromBroadcast(_broadcastFile(SCRIPT_FILE));
    }

    function fromBroadcast(string memory path) public view returns (Created[4] memory x) {
        require(vm.exists(path), string.concat("no broadcast file at ", path, "; set the addresses by env instead"));
        string memory json = vm.readFile(path);
        x[0] = _created(json, "IDMRecords", 0);
        x[1] = _created(json, "RewardFeeder", 0);
        x[2] = _created(json, "TreasuryFeeder", 0);
        x[3] = _created(json, "RevenueSplitter", 0);
    }

    // ---------------------------------------------------------------- output

    function summary(Config memory c, Deployment memory d, string memory status) public view {
        IDMRecords n = d.records;
        (uint256 price, uint128 liquidity) = _checkPool();
        console2.log("== IDM Records on Robinhood Chain", block.chainid, status);
        console2.log("  IDMRecords                      ", address(n));
        console2.log("    name / symbol                  IDM Records / RECORDS, cap", n.MAX_SUPPLY());
        console2.log("    owner                         ", n.owner());
        console2.log("    pending owner (0 = none)      ", n.pendingOwner());
        console2.log("    voucher signer (rotatable)    ", n.signer());
        console2.log("    base URI (until frozen)       ", n.baseURI());
        console2.log("    reward token USDG             ", address(n.rewardToken()));
        console2.log("    hold token $IDM (mint check)  ", address(n.holdToken()));
        console2.log("    royalty bps / receiver        ", n.royaltyBps(), n.royaltyReceiver());
        console2.log("    transfer validator (ERC721-C) ", n.getTransferValidator());
        if (n.getTransferValidator() == address(0)) {
            console2.log("    !! no transfer validator: the 5% royalty is NOT enforced on transfers yet");
        } else if (n.getTransferValidator() == DEFAULT_VALIDATOR) {
            console2.log("    (Limit Break Creator Token Transfer Validator v5, code hash pinned)");
            console2.log("    contract / 7702 wallets move their own records (v5 options 6)", c.walletOtc);
        }
        console2.log("    tokens minted                 ", n.totalSupply());
        console2.log("    open to vouchers: ids 1 ..    ", n.mintableUpTo());
        if (n.mintableUpTo() == 0) console2.log("    !! no ids open: the owner calls setMintableUpTo(<drop's highest id>) before the drop");
        console2.log("  RewardFeeder (no withdrawal)    ", address(d.feeder));
        console2.log("    owner (replaces the keeper)   ", d.feeder.owner());
        console2.log("    keeper (feeds)                ", d.feeder.keeper());
        console2.log("    floor USDG/ETH (owner sets)   ", d.feeder.minUsdgPerEth());
        console2.log("    sweep to (other tokens)       ", d.feeder.sweepTo());
        console2.log("    pool ETH/USDG fee (pips)      ", uint256(d.feeder.fee()));
        console2.log("    pool tick spacing             ", int256(d.feeder.tickSpacing()));
        console2.log("    pool price USDG/ETH (6 dec)   ", price);
        console2.log("    pool liquidity                ", uint256(liquidity));
        console2.log("  TreasuryFeeder (no withdrawal)  ", address(d.treasuryFeeder));
        console2.log("    USDG -> ETH -> PulseTreasury  ", TREASURY);
        console2.log("    owner (replaces the keeper)   ", d.treasuryFeeder.owner());
        console2.log("    keeper (swaps)                ", d.treasuryFeeder.keeper());
        console2.log("    ceiling USDG/ETH (owner sets) ", d.treasuryFeeder.maxUsdgPerEth());
        _logSplit(
            d.splitter,
            royaltySplit(address(d.feeder), address(d.treasuryFeeder), c.infra),
            "RewardFeeder (NFT holders)",
            "TreasuryFeeder ($IDM burn)"
        );
        if (c.infra.code.length > 0) {
            console2.log("    !! infra is a contract: it must accept plain ETH or every release() reverts");
        }
        if (n.pendingOwner() != address(0)) {
            console2.log("  NEXT: RECORDS_OWNER calls acceptOwnership() on IDMRecords, then run verify() again");
        }
    }

    function writeRecord(Config memory c, Deployment memory d, Created[4] memory x, string memory status, string memory path)
        public
    {
        string memory k = "records";
        _recordHead(k, "robinhood", status);
        _recordCreated(k, "records", x[0]);
        _recordCreated(k, "rewardFeeder", x[1]);
        _recordCreated(k, "treasuryFeeder", x[2]);
        _recordCreated(k, "royaltySplitter", x[3]);
        vm.serializeAddress(k, "deployer", c.deployer);
        vm.serializeAddress(k, "owner", d.records.owner());
        vm.serializeAddress(k, "pendingOwner", d.records.pendingOwner());
        vm.serializeAddress(k, "signer", d.records.signer());
        vm.serializeAddress(k, "keeper", d.feeder.keeper());
        vm.serializeAddress(k, "feederOwner", d.feeder.owner());
        vm.serializeAddress(k, "infra", c.infra);
        vm.serializeAddress(k, "treasury", TREASURY);
        vm.serializeAddress(k, "rewardToken", USDG);
        vm.serializeAddress(k, "holdToken", address(d.records.holdToken()));
        vm.serializeAddress(k, "weth", RH_WETH);
        vm.serializeAddress(k, "poolManager", POOL_MANAGER);
        vm.serializeUint(k, "poolFee", POOL_FEE);
        vm.serializeInt(k, "tickSpacing", TICK_SPACING);
        vm.serializeUint(k, "royaltyBps", ROYALTY_BPS);
        vm.serializeAddress(k, "transferValidator", d.records.transferValidator());
        vm.serializeBool(k, "walletOtc", c.walletOtc);
        vm.serializeString(k, "baseURI", d.records.baseURI());
        vm.serializeUint(k, "maxSupply", 1000);
        string memory json = vm.serializeString(
            k, "royaltyShares", "5000 RewardFeeder / 2500 TreasuryFeeder (-> PulseTreasury, USDG swapped to ETH) / 2500 infra"
        );
        vm.writeJson(json, path);
        console2.log("  record written:", path);
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
