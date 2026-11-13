// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRecords, CollectionSecurityPolicy, ITransferValidatorV5} from "../script/DeployRecords.s.sol";
import {DeployLabel} from "../script/DeployLabel.s.sol";
import {DeployStationsSplit} from "../script/DeployStationsSplit.s.sol";
import {LabelDeployBase} from "../script/LabelDeployBase.s.sol";
import {IDMRecords, ICreatorToken} from "../src/IDMRecords.sol";
import {RewardFeeder, IRecordsPot} from "../src/RewardFeeder.sol";
import {TreasuryFeeder} from "../src/TreasuryFeeder.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Like, IBalanceOf} from "../src/IDMRecords.sol";
import {RevenueSplitter} from "../src/RevenueSplitter.sol";
import {HolderRewards, IERC20Rewards as IERC20Like2} from "../src/HolderRewards.sol";

/// A 6-decimal token for the Base splitter's release (etched at the USDC address).
contract Usdc6 {
    mapping(address => uint256) public balanceOf;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
}

/// Stands in for the ERC721-C validator at its address, without a network: allows every transfer, and keeps each
/// collection's v5 security policy as Limit Break's validator does (only the collection's owner may set it).
contract AllowAllValidator {
    mapping(address => CollectionSecurityPolicy) internal _policy;

    function validateTransfer(address, address, address, uint256) external view {}

    function setTokenTypeOfCollection(address collection, uint16 tokenType) external {
        require(msg.sender == collection, "only the collection");
        _policy[collection].tokenType = tokenType;
    }

    function setRulesetOfCollection(address collection, uint8 rulesetId, address customRuleset, uint8 globalOptions, uint16 rulesetOptions)
        external
    {
        require(msg.sender == IDMRecords(collection).owner(), "only the collection's owner");
        CollectionSecurityPolicy storage p = _policy[collection];
        (p.rulesetId, p.customRuleset, p.globalOptions, p.rulesetOptions) = (rulesetId, customRuleset, globalOptions, rulesetOptions);
    }

    function getCollectionSecurityPolicy(address collection) external view returns (CollectionSecurityPolicy memory) {
        return _policy[collection];
    }
}

/// A contract wallet (a Safe, say) that holds and sends records itself.
contract ContractWallet {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function send(IDMRecords n, address to, uint256 id) external {
        n.transferFrom(address(this), to, id);
    }

    function approve(IDMRecords n, address operator) external {
        n.setApprovalForAll(operator, true);
    }
}

/// The read side of Limit Break's Creator Token Transfer Validator v5 the fork rehearsal uses.
interface IValidatorV5 {
    function getListAccounts(uint48 id, uint8 listType) external view returns (address[] memory);
    function isAccountInListByCollection(address collection, uint8 listType, address account) external view returns (bool);
}

abstract contract LabelDeployFixture is Test {
    /// @dev Skips a test that writes deployment records when the profile only reads deployments/ (the default
    ///      profile; FOUNDRY_PROFILE=deploy may write).
    function skipUnlessWritable() internal {
        try vm.writeFile("deployments/test-write-check.preview.json", "{}") {} catch { vm.skip(true); }
    }

    // Robinhood / Base constants, as the scripts have them.
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address payable constant TREASURY = payable(0xAb64b47daA0f68e50BDF776e73B4245D78575a6c);
    address constant IDM = 0x4Fe9f3823791c8b187B81aB8B7398d793FEd28f6;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant LB_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    /// sqrtPriceX96 seen on the ETH/USDG 0.05% pool on 2026-11-03 (about $2246 per ETH).
    uint256 constant SQRT_PRICE = 3757136363756052830000593;

    address deployer = makeAddr("deployer");
    address signer = makeAddr("voucher signer");
    address keeper = makeAddr("payout keeper");
    address infra = makeAddr("infra");
    address rewardsKeeper = makeAddr("rewards keeper");
    address burn = makeAddr("burn bridge");
    address other = makeAddr("someone else");
    address imdBurn = makeAddr("imd burn");
    address guardian = makeAddr("rewards guardian");

    function recordsConfig() internal view returns (DeployRecords.Config memory) {
        return DeployRecords.Config(
            deployer, deployer, signer, keeper, infra, address(0), bytes32(0), false, "https://theidm.fun/records/"
        );
    }

    function labelConfig() internal view returns (DeployLabel.Config memory) {
        return DeployLabel.Config(deployer, deployer, rewardsKeeper, guardian, 12 hours, burn, infra, address(0));
    }

    /// Code and the few views the Robinhood script reads, without a network.
    function mockRobinhood() internal {
        vm.chainId(4663);
        vm.etch(USDG, hex"00");
        vm.mockCall(USDG, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.etch(RH_WETH, hex"00");
        vm.etch(POOL_MANAGER, hex"00");
        vm.mockCall(POOL_MANAGER, abi.encodeWithSignature("extsload(bytes32)"), abi.encode(SQRT_PRICE));
        vm.etch(TREASURY, hex"00");
        vm.mockCall(TREASURY, abi.encodeWithSignature("idm()"), abi.encode(IDM));
        vm.mockCall(TREASURY, abi.encodeWithSignature("poolManager()"), abi.encode(POOL_MANAGER));
        vm.etch(IDM, hex"00");
        vm.mockCall(IDM, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.etch(LB_VALIDATOR, type(AllowAllValidator).runtimeCode);
    }

    function mockBase() internal {
        vm.chainId(8453);
        vm.etch(BASE_USDC, address(new Usdc6()).code);
    }

    /// A Forge broadcast file (run-latest.json) as Forge 1.x writes it, trimmed to the fields the scripts read.
    function broadcastJson(string[] memory names, address[] memory addrs, string memory status)
        internal
        pure
        returns (string memory txs)
    {
        string memory receipts;
        for (uint256 i; i < names.length; ++i) {
            string memory h = vm.toString(bytes32(i + 1));
            string memory sep = i == 0 ? "" : ",";
            txs = string.concat(
                txs, sep, '{"hash":"', h, '","transactionType":"CREATE","contractName":"', names[i],
                '","contractAddress":"', vm.toString(addrs[i]), '"}'
            );
            receipts = string.concat(
                receipts, sep, '{"transactionHash":"', h, '","status":"', status, '","blockNumber":"',
                vm.toString(bytes32(100 + i)), '"}'
            );
        }
        // A CALL to the first contract (setRoyalty) must be skipped when looking for CREATEs.
        txs = string.concat(
            '{"transactions":[', txs, ',{"hash":"', vm.toString(bytes32(uint256(99))),
            '","transactionType":"CALL","contractName":"', names[0], '","contractAddress":"', vm.toString(addrs[0]),
            '"}],"receipts":[', receipts, "]}"
        );
    }
}

contract DeployRecordsTest is LabelDeployFixture {
    DeployRecords script;

    function setUp() public {
        script = new DeployRecords();
        mockRobinhood();
    }

    function test_DeploysInOrderAndReadsBack() public {
        DeployRecords.Config memory c = recordsConfig();
        script.checkInputs(c);
        uint64 nonce = vm.getNonce(deployer);
        DeployRecords.Deployment memory d = script.deploy(c);
        script.check(c, d);

        // Three creations, then setRoyalty; nothing else.
        assertEq(vm.getNonce(deployer), nonce + 4);
        assertEq(address(d.records), vm.computeCreateAddress(deployer, nonce));
        assertEq(address(d.feeder), vm.computeCreateAddress(deployer, nonce + 1));
        assertEq(address(d.splitter), vm.computeCreateAddress(deployer, nonce + 2));

        assertEq(d.records.owner(), deployer);
        assertEq(d.records.signer(), signer);
        assertEq(d.records.royaltyReceiver(), address(d.splitter));
        assertEq(d.records.royaltyBps(), 500);
        assertEq(d.records.transferValidator(), address(0));
        assertEq(address(d.feeder.records()), address(d.records));
        assertEq(d.feeder.keeper(), keeper);
        assertEq(d.feeder.owner(), deployer); // RECORDS_OWNER: may replace the keeper
        assertEq(d.feeder.sweepTo(), infra);
        (address[] memory a,, bool[] memory e) = d.splitter.payees();
        assertEq(a[0], address(d.feeder));
        assertEq(a[1], TREASURY);
        assertEq(a[2], infra);
        assertTrue(e[1]);
        assertEq(d.splitter.tokenSink(), infra);
        assertEq(d.splitter.weth(), RH_WETH);

        // A royalty in ETH lands where it should.
        vm.deal(address(d.splitter), 1 ether);
        d.splitter.release();
        assertEq(address(d.feeder).balance, 0.5 ether);
        assertEq(TREASURY.balance, 0.25 ether);
        assertEq(infra.balance, 0.25 ether);
    }

    function test_ValidatorAndOwnerHandover() public {
        DeployRecords.Config memory c = recordsConfig();
        address safe = makeAddr("owner safe");
        c.owner = safe;
        c.validator = script.DEFAULT_VALIDATOR(); // a stand-in validator is etched there
        c.validatorCodehash = LB_VALIDATOR.codehash; // the stand-in's; the real run pins Limit Break's
        c.walletOtc = true;
        script.checkInputs(c);
        uint64 nonce = vm.getNonce(deployer);
        DeployRecords.Deployment memory d = script.deploy(c);
        // Three creations, setRoyalty, setTransferValidator, the v5 rules, transferOwnership.
        assertEq(vm.getNonce(deployer), nonce + 7);
        CollectionSecurityPolicy memory p = ITransferValidatorV5(LB_VALIDATOR).getCollectionSecurityPolicy(address(d.records));
        assertEq(p.rulesetOptions, 6);
        assertEq(p.rulesetId, 0);
        assertEq(p.listId, 0);
        assertEq(p.tokenType, 721);
        assertEq(d.records.transferValidator(), c.validator);
        assertEq(d.records.getTransferValidator(), LB_VALIDATOR);
        assertTrue(d.records.supportsInterface(type(ICreatorToken).interfaceId));
        assertEq(address(d.records.holdToken()), IDM);
        assertEq(d.records.owner(), deployer);
        assertEq(d.records.pendingOwner(), safe);
        script.check(c, d); // pending is a valid state

        vm.prank(safe);
        d.records.acceptOwnership();
        script.check(c, d);
        assertEq(d.records.owner(), safe);

        // The rules are read back: v5's defaults where wallet transfers were decided, and the other way round.
        c.walletOtc = false;
        vm.expectRevert(bytes("IDMRecords mismatch: v5 options (want the defaults)"));
        script.check(c, d);
        c.walletOtc = true;
        vm.prank(safe);
        ITransferValidatorV5(LB_VALIDATOR).setRulesetOfCollection(address(d.records), 0, address(0), 0, 0);
        vm.expectRevert(bytes("IDMRecords mismatch: v5 options (contract and 7702 wallets not allowed yet: allowWalletOtc())"));
        script.check(c, d);
        vm.prank(safe);
        ITransferValidatorV5(LB_VALIDATOR).setRulesetOfCollection(address(d.records), 0, address(0), 1, 6);
        vm.expectRevert(bytes("IDMRecords mismatch: v5 ruleset (want the default ruleset, no custom ruleset, no global options)"));
        script.check(c, d);
    }

    function test_WalletOtcOnlyForLimitBreakV5() public {
        DeployRecords.Config memory c = recordsConfig();
        c.walletOtc = true; // with no validator
        _expectInput(c, "RECORDS_ALLOW_WALLET_OTC: a Limit Break v5 setting; set it to 0 for another validator or none");
    }

    function test_CheckFailsLoudlyOnEveryMismatch() public {
        DeployRecords.Config memory c = recordsConfig();
        DeployRecords.Deployment memory d = script.deploy(c);
        IDMRecords n = d.records;

        vm.prank(deployer);
        n.setSigner(other);
        vm.expectRevert(bytes("IDMRecords mismatch: a signer change is pending (activate or wait)"));
        script.check(c, d);
        // A proposal left past its window can never be activated: the check asks for cancelSigner().
        vm.warp(n.pendingSignerAt() + n.SIGNER_WINDOW() + 1);
        vm.expectRevert(bytes("IDMRecords mismatch: a lapsed signer proposal is stored (cancelSigner())"));
        script.check(c, d);
        vm.prank(deployer);
        n.cancelSigner();
        script.check(c, d);
        vm.prank(deployer);
        n.setSigner(other);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(deployer);
        n.activateSigner();
        vm.expectRevert(bytes("IDMRecords mismatch: signer"));
        script.check(c, d);
        vm.prank(deployer);
        n.setSigner(signer);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(deployer);
        n.activateSigner();

        vm.prank(deployer);
        n.setRoyalty(address(d.splitter), 600);
        vm.expectRevert(bytes("IDMRecords mismatch: royalty"));
        script.check(c, d);
        vm.prank(deployer);
        n.setRoyalty(other, 500);
        vm.expectRevert(bytes("IDMRecords mismatch: royalty"));
        script.check(c, d);
        vm.prank(deployer);
        n.setRoyalty(address(d.splitter), 500);

        vm.prank(deployer);
        n.setBaseURI("https://example.com/");
        vm.expectRevert(bytes("IDMRecords mismatch: base URI"));
        script.check(c, d);
        vm.prank(deployer);
        n.setBaseURI(c.baseURI);

        vm.prank(deployer);
        n.setTransferValidator(LB_VALIDATOR);
        vm.expectRevert(bytes("IDMRecords mismatch: transfer validator"));
        script.check(c, d);
        vm.prank(deployer);
        n.setTransferValidator(address(0));

        vm.prank(deployer);
        n.transferOwnership(other);
        vm.expectRevert(bytes("IDMRecords mismatch: owner"));
        script.check(c, d);
        vm.prank(deployer);
        n.transferOwnership(address(0));

        DeployRecords.Config memory wrong = recordsConfig();
        wrong.keeper = other;
        vm.expectRevert(bytes("RewardFeeder mismatch: keeper"));
        script.check(wrong, d);
        wrong = recordsConfig();
        wrong.owner = other;
        vm.expectRevert(bytes("IDMRecords mismatch: owner / pending owner"));
        script.check(wrong, d);
        wrong = recordsConfig();
        wrong.infra = other;
        vm.expectRevert(bytes("RewardFeeder mismatch: sweepTo"));
        script.check(wrong, d);

        // Another deployment's splitter is not this collection's royalty receiver.
        DeployRecords.Deployment memory mixed =
            DeployRecords.Deployment(d.records, d.feeder, script.deploy(c).splitter);
        vm.expectRevert(bytes("IDMRecords mismatch: royalty"));
        script.check(c, mixed);

        script.check(c, d); // everything restored

        // Code that is not this build's is refused, even at the right address with the right answers.
        bytes memory real = address(d.feeder).code;
        vm.etch(address(d.feeder), address(d.splitter).code);
        vm.expectRevert(bytes("RewardFeeder code mismatch: not this build's contract (length)"));
        script.check(c, d);
        bytes memory patched = bytes.concat(real);
        patched[patched.length - 40] = patched[patched.length - 40] ^ 0x01;
        vm.etch(address(d.feeder), patched);
        vm.expectRevert(bytes("RewardFeeder code mismatch: not this build's contract"));
        script.check(c, d);
        vm.etch(address(d.feeder), real);
        script.check(c, d);

        vm.prank(deployer);
        n.freezeMetadata();
        vm.expectRevert(bytes("IDMRecords mismatch: metadata already frozen"));
        script.check(c, d);

        DeployRecords.Deployment memory e = script.deploy(c);
        vm.prank(deployer);
        e.records.lockTransferValidator();
        vm.expectRevert(bytes("IDMRecords mismatch: validator already locked"));
        script.check(c, e);
    }

    function _expectInput(DeployRecords.Config memory c, string memory message) internal {
        vm.expectRevert(bytes(message));
        script.checkInputs(c);
    }

    function test_InputChecksBeforeAnyTransaction() public {
        DeployRecords.Config memory c;

        vm.chainId(1);
        _expectInput(recordsConfig(), "wrong chain: expected Robinhood Chain 4663");
        vm.chainId(4663);

        c = recordsConfig();
        c.signer = address(0);
        _expectInput(c, "RECORDS_SIGNER: zero address");
        c = recordsConfig();
        c.keeper = address(0);
        _expectInput(c, "PAYOUT_KEEPER: zero address");
        c = recordsConfig();
        c.signer = keeper;
        _expectInput(c, "RECORDS_SIGNER and PAYOUT_KEEPER: must be different addresses");
        c = recordsConfig();
        c.signer = deployer;
        _expectInput(c, "RECORDS_SIGNER and DEPLOYER: must be different addresses");
        c = recordsConfig();
        c.keeper = deployer;
        _expectInput(c, "PAYOUT_KEEPER and DEPLOYER: must be different addresses");
        c = recordsConfig();
        c.owner = keeper;
        _expectInput(c, "PAYOUT_KEEPER and RECORDS_OWNER: must be different addresses");
        c = recordsConfig();
        c.infra = keeper;
        _expectInput(c, "PAYOUT_KEEPER and LABEL_INFRA: must be different addresses");
        c = recordsConfig();
        c.infra = TREASURY;
        _expectInput(c, "LABEL_INFRA and PulseTreasury: must be different addresses");
        c = recordsConfig();
        c.keeper = address(script);
        _expectInput(c, "PAYOUT_KEEPER: must be a plain wallet (EOA), found contract code");
        c = recordsConfig();
        c.baseURI = "https://theidm.fun/records";
        _expectInput(c, "RECORDS_BASE_URI: must end with /");
        c = recordsConfig();
        c.baseURI = "http://theidm.fun/records/";
        _expectInput(c, "RECORDS_BASE_URI: must start with https:// or ipfs://");
        c = recordsConfig();
        c.validator = other;
        _expectInput(c, "RECORDS_VALIDATOR: no contract code at this address");
        // Limit Break's v5 is pinned by its code hash: the stand-in etched at its address is not that code.
        c = recordsConfig();
        c.validator = LB_VALIDATOR;
        c.validatorCodehash = script.V5_CODEHASH();
        _expectInput(c, "RECORDS_VALIDATOR: code hash differs from the pinned one (Limit Break v5 as read 2026-11-04)");

        vm.etch(IDM, "");
        _expectInput(recordsConfig(), "$IDM: no contract code at this address");
        vm.etch(IDM, hex"00");
        vm.mockCall(IDM, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        _expectInput(recordsConfig(), "$IDM: expected 18 decimals");
        vm.mockCall(IDM, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        vm.etch(USDG, "");
        _expectInput(recordsConfig(), "USDG: no contract code at this address");
        vm.etch(USDG, hex"00");
        vm.mockCall(USDG, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        _expectInput(recordsConfig(), "USDG: expected 6 decimals");
        vm.mockCall(USDG, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));

        vm.mockCall(TREASURY, abi.encodeWithSignature("idm()"), abi.encode(other));
        _expectInput(recordsConfig(), "PulseTreasury: idm() is not $IDM");
        vm.mockCall(TREASURY, abi.encodeWithSignature("idm()"), abi.encode(IDM));

        vm.mockCall(POOL_MANAGER, abi.encodeWithSignature("extsload(bytes32)"), abi.encode(uint256(0)));
        _expectInput(recordsConfig(), "ETH/USDG 0.05% pool: not initialized");
        // sqrtPrice 2^96 = one USDG unit per wei: not an ETH/USDG price.
        vm.mockCall(POOL_MANAGER, abi.encodeWithSignature("extsload(bytes32)"), abi.encode(uint256(1) << 96));
        _expectInput(recordsConfig(), "ETH/USDG 0.05% pool: price out of range");
        vm.mockCall(POOL_MANAGER, abi.encodeWithSignature("extsload(bytes32)"), abi.encode(SQRT_PRICE));

        script.checkInputs(recordsConfig());
    }

    function test_RecordAndBroadcastFile() public {
        skipUnlessWritable();
        DeployRecords.Config memory c = recordsConfig();
        DeployRecords.Deployment memory d = script.deploy(c);

        string[] memory names = new string[](3);
        (names[0], names[1], names[2]) = ("IDMRecords", "RewardFeeder", "RevenueSplitter");
        address[] memory addrs = new address[](3);
        (addrs[0], addrs[1], addrs[2]) = (address(d.records), address(d.feeder), address(d.splitter));
        string memory bfile = "deployments/test-broadcast-records.preview.json";
        vm.writeFile(bfile, broadcastJson(names, addrs, "0x1"));
        LabelDeployBase.Created[3] memory x = script.fromBroadcast(bfile);
        assertEq(x[0].addr, address(d.records));
        assertEq(x[1].addr, address(d.feeder));
        assertEq(x[2].addr, address(d.splitter));
        assertEq(x[0].tx, bytes32(uint256(1)));
        assertEq(x[2].blockNumber, 102);

        string memory rfile = "deployments/test-records.preview.json";
        script.writeRecord(c, d, x, "verified", rfile);
        string memory json = vm.readFile(rfile);
        assertEq(vm.parseJsonUint(json, ".chainId"), 4663);
        assertEq(vm.parseJsonString(json, ".status"), "verified");
        assertEq(vm.parseJsonAddress(json, ".records"), address(d.records));
        assertEq(vm.parseJsonBytes32(json, ".recordsTx"), bytes32(uint256(1)));
        assertEq(vm.parseJsonUint(json, ".recordsBlock"), 100);
        assertEq(vm.parseJsonAddress(json, ".rewardFeeder"), address(d.feeder));
        assertEq(vm.parseJsonAddress(json, ".royaltySplitter"), address(d.splitter));
        assertEq(vm.parseJsonAddress(json, ".signer"), signer);
        assertEq(vm.parseJsonAddress(json, ".keeper"), keeper);
        assertEq(vm.parseJsonAddress(json, ".treasury"), TREASURY);
        assertEq(vm.parseJsonUint(json, ".royaltyBps"), 500);
        assertEq(vm.parseJsonString(json, ".baseURI"), c.baseURI);
        assertEq(vm.parseJsonAddress(json, ".holdToken"), IDM);
        assertEq(vm.parseJsonAddress(json, ".transferValidator"), address(0));

        vm.writeFile(bfile, broadcastJson(names, addrs, "0x0"));
        vm.expectRevert(bytes("broadcast file: a deploy transaction failed"));
        script.fromBroadcast(bfile);
        names[1] = "SomethingElse";
        vm.writeFile(bfile, broadcastJson(names, addrs, "0x1"));
        vm.expectRevert(bytes("broadcast file: no CREATE of RewardFeeder"));
        script.fromBroadcast(bfile);
        vm.removeFile(bfile);
        vm.removeFile(rfile);
        vm.expectRevert(
            bytes(string.concat("no broadcast file at ", bfile, "; set the addresses by env instead"))
        );
        script.fromBroadcast(bfile);
    }
}

contract DeployLabelTest is LabelDeployFixture {
    DeployLabel script;

    function setUp() public {
        script = new DeployLabel();
        mockBase();
    }

    function test_DeploysAndReleasesUsdc() public {
        DeployLabel.Config memory c = labelConfig();
        script.checkInputs(c);
        uint64 nonce = vm.getNonce(deployer);
        DeployLabel.Deployment memory d = script.deploy(c);
        script.check(c, d);
        assertEq(vm.getNonce(deployer), nonce + 2);
        assertEq(address(d.rewards.usdc()), BASE_USDC);
        assertEq(d.rewards.owner(), deployer);
        assertEq(d.rewards.keeper(), rewardsKeeper);
        assertEq(d.rewards.guardian(), guardian);
        assertEq(d.rewards.sweepTo(), infra);
        assertEq(d.rewards.rootDelay(), 12 hours);
        (address[] memory a, uint16[] memory b, bool[] memory e) = d.splitter.payees();
        assertEq(a[0], address(d.rewards));
        assertEq(a[1], burn);
        assertEq(a[2], infra);
        assertEq(b[0], 5000);
        assertEq(b[1], 2500);
        assertEq(b[2], 2500);
        assertFalse(e[0] || e[1] || e[2]);
        assertEq(d.splitter.weth(), address(0));

        Usdc6(BASE_USDC).mint(address(d.splitter), 20e6);
        d.splitter.releaseToken(BASE_USDC);
        assertEq(Usdc6(BASE_USDC).balanceOf(address(d.rewards)), 10e6);
        assertEq(d.rewards.received(), 10e6);
        assertEq(Usdc6(BASE_USDC).balanceOf(burn), 5e6);
        assertEq(Usdc6(BASE_USDC).balanceOf(infra), 5e6);
    }

    function test_OwnerAndDelayOptions() public {
        DeployLabel.Config memory c = labelConfig();
        c.owner = other;
        c.rootDelay = 1 days;
        script.checkInputs(c);
        DeployLabel.Deployment memory d = script.deploy(c);
        script.check(c, d);
        assertEq(d.rewards.owner(), other);
        vm.expectRevert(bytes("HolderRewards mismatch: owner"));
        script.check(labelConfig(), d);
        c.rootDelay = 12 hours;
        vm.expectRevert(bytes("HolderRewards mismatch: rootDelay"));
        script.check(c, d);
    }

    /// Unwrapped WETH would be ETH, which HolderRewards cannot use: on Base WETH stays a token (its holders' half is
    /// swept to infra by HolderRewards), so LABEL_WETH is refused.
    function test_WethRefusedOnBase() public {
        DeployLabel.Config memory c = labelConfig();
        c.weth = BASE_WETH;
        vm.expectRevert(
            bytes("LABEL_WETH: not on Base (unwrapped WETH is ETH, which HolderRewards cannot use); leave it unset")
        );
        script.checkInputs(c);
        DeployLabel.Deployment memory d = script.deploy(c);
        assertEq(d.splitter.weth(), address(0)); // even if asked
    }

    function test_GuardianOptional() public {
        DeployLabel.Config memory c = labelConfig();
        c.guardian = address(0);
        script.checkInputs(c);
        DeployLabel.Deployment memory d = script.deploy(c);
        script.check(c, d);
        assertEq(d.rewards.guardian(), address(0));
        vm.expectRevert(bytes("HolderRewards mismatch: guardian"));
        script.check(labelConfig(), d);
    }

    function _expectInput(DeployLabel.Config memory c, string memory message) internal {
        vm.expectRevert(bytes(message));
        script.checkInputs(c);
    }

    function test_InputChecks() public {
        DeployLabel.Config memory c;
        vm.chainId(4663);
        _expectInput(labelConfig(), "wrong chain: expected Base 8453");
        vm.chainId(8453);

        c = labelConfig();
        c.keeper = address(0);
        _expectInput(c, "REWARDS_KEEPER: zero address");
        c = labelConfig();
        c.keeper = deployer;
        _expectInput(c, "REWARDS_KEEPER and DEPLOYER: must be different addresses");
        c = labelConfig();
        c.owner = rewardsKeeper;
        _expectInput(c, "REWARDS_KEEPER and REWARDS_OWNER: must be different addresses");
        c = labelConfig();
        c.burn = rewardsKeeper;
        _expectInput(c, "REWARDS_KEEPER and BRIDGE_BURN: must be different addresses");
        c = labelConfig();
        c.infra = burn;
        _expectInput(c, "BRIDGE_BURN and LABEL_INFRA: must be different addresses");
        c = labelConfig();
        c.burn = deployer;
        _expectInput(c, "BRIDGE_BURN and DEPLOYER: must be different addresses");
        c = labelConfig();
        c.burn = address(script);
        _expectInput(c, "BRIDGE_BURN: must be a plain wallet (EOA), found contract code");
        c = labelConfig();
        c.keeper = address(script);
        _expectInput(c, "REWARDS_KEEPER: must be a plain wallet (EOA), found contract code");
        c = labelConfig();
        c.rootDelay = 59 minutes;
        _expectInput(c, "REWARDS_DELAY: between 3600 (1 h) and 604800 (7 days)");
        c.rootDelay = 7 days + 1;
        _expectInput(c, "REWARDS_DELAY: between 3600 (1 h) and 604800 (7 days)");
        c = labelConfig();
        c.guardian = rewardsKeeper;
        _expectInput(c, "REWARDS_GUARDIAN and REWARDS_KEEPER: must be different addresses");
        c = labelConfig();
        c.guardian = burn;
        _expectInput(c, "REWARDS_GUARDIAN and BRIDGE_BURN: must be different addresses");
        c = labelConfig();
        c.guardian = deployer;
        _expectInput(c, "REWARDS_GUARDIAN and DEPLOYER: must be different addresses");
        c = labelConfig();
        c.guardian = address(script);
        _expectInput(c, "REWARDS_GUARDIAN: must be a plain wallet (EOA), found contract code");

        vm.etch(BASE_USDC, "");
        _expectInput(labelConfig(), "USDC: no contract code at this address");
        vm.etch(BASE_USDC, hex"00");
        vm.mockCall(BASE_USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        _expectInput(labelConfig(), "USDC: expected 6 decimals");
    }

    function test_CheckFailsLoudly() public {
        DeployLabel.Deployment memory d = script.deploy(labelConfig());
        DeployLabel.Config memory c = labelConfig();
        c.infra = other;
        vm.expectRevert(bytes("HolderRewards mismatch: sweepTo"));
        script.check(c, d);
        c = labelConfig();
        c.keeper = other;
        vm.expectRevert(bytes("HolderRewards mismatch: keeper"));
        script.check(c, d);
        // A splitter that pays some other rewards contract.
        DeployLabel.Deployment memory e = script.deploy(labelConfig());
        vm.expectRevert(bytes("LabelSplitter mismatch: holders payee"));
        script.check(labelConfig(), DeployLabel.Deployment(d.rewards, e.splitter));
        vm.expectRevert(bytes("HolderRewards: no contract code at this address"));
        script.check(labelConfig(), DeployLabel.Deployment(HolderRewards(payable(other)), d.splitter));
    }

    function test_RecordAndBroadcastFile() public {
        skipUnlessWritable();
        DeployLabel.Config memory c = labelConfig();
        DeployLabel.Deployment memory d = script.deploy(c);
        string[] memory names = new string[](2);
        (names[0], names[1]) = ("HolderRewards", "RevenueSplitter");
        address[] memory addrs = new address[](2);
        (addrs[0], addrs[1]) = (address(d.rewards), address(d.splitter));
        string memory bfile = "deployments/test-broadcast-label.preview.json";
        vm.writeFile(bfile, broadcastJson(names, addrs, "0x1"));
        LabelDeployBase.Created[2] memory x = script.fromBroadcast(bfile);
        assertEq(x[0].addr, address(d.rewards));
        assertEq(x[1].addr, address(d.splitter));
        assertEq(x[1].blockNumber, 101);

        string memory rfile = "deployments/test-label.preview.json";
        script.writeRecord(c, x, "verified", rfile);
        string memory json = vm.readFile(rfile);
        assertEq(vm.parseJsonUint(json, ".chainId"), 8453);
        assertEq(vm.parseJsonAddress(json, ".holderRewards"), address(d.rewards));
        assertEq(vm.parseJsonBytes32(json, ".holderRewardsTx"), bytes32(uint256(1)));
        assertEq(vm.parseJsonAddress(json, ".labelSplitter"), address(d.splitter));
        assertEq(vm.parseJsonUint(json, ".labelSplitterBlock"), 101);
        assertEq(vm.parseJsonAddress(json, ".rewardsKeeper"), rewardsKeeper);
        assertEq(vm.parseJsonUint(json, ".rootDelay"), 12 hours);
        assertEq(vm.parseJsonAddress(json, ".burnBridge"), burn);
        assertEq(vm.parseJsonAddress(json, ".usdc"), BASE_USDC);
        vm.removeFile(bfile);
        vm.removeFile(rfile);
    }
}

contract DeployStationsSplitTest is LabelDeployFixture {
    DeployStationsSplit script;

    function setUp() public {
        script = new DeployStationsSplit();
    }

    function _rewards() internal returns (HolderRewards) {
        return new HolderRewards(IERC20Like2(BASE_USDC), deployer, rewardsKeeper, address(0), 1 hours, infra);
    }

    function _baseConfig(address rewards) internal view returns (DeployStationsSplit.Config memory) {
        return DeployStationsSplit.Config(
            deployer, rewards, burn, imdBurn, infra, rewards, burn, address(0), address(0), address(0)
        );
    }

    function test_BaseSplitsInFourWithHoldersToHolderRewards() public {
        mockBase();
        HolderRewards rewards = _rewards();
        DeployStationsSplit.Config memory c = _baseConfig(address(rewards));
        script.checkInputs(c);
        DeployStationsSplit.Deployment memory d = script.deploy(c);
        RevenueSplitter s = d.splitter;
        script.check(c, d);
        assertEq(address(d.treasuryFeeder), address(0));
        assertEq(script.recordFile(false), "deployments/stations-split-base.json");
        Usdc6(BASE_USDC).mint(address(s), 100e6 + 3);
        s.releaseToken(BASE_USDC);
        assertEq(Usdc6(BASE_USDC).balanceOf(address(rewards)), 25e6);
        assertEq(rewards.received(), 25e6);
        assertEq(Usdc6(BASE_USDC).balanceOf(burn), 25e6);
        assertEq(Usdc6(BASE_USDC).balanceOf(imdBurn), 25e6);
        assertEq(Usdc6(BASE_USDC).balanceOf(infra), 25e6 + 3); // rounding dust to the last payee

        DeployStationsSplit.Config memory w = _baseConfig(address(rewards));
        w.imdBurn = other;
        vm.expectRevert(bytes("StationsSplitter mismatch: IMD burn payee"));
        script.check(w, d);
    }

    /// Robinhood: holders' quarter to RewardFeeder (of the deployed IDM Records), $IDM quarter to a new TreasuryFeeder.
    function _robinhood() internal returns (DeployStationsSplit.Config memory c, RewardFeeder feeder) {
        mockRobinhood();
        vm.etch(USDG, address(new Usdc6()).code);
        IDMRecords records = new IDMRecords(
            "IDM Records", "RECORDS", deployer, signer, IERC20Like(USDG), IBalanceOf(IDM), "https://theidm.fun/records/",
            address(0), 0
        );
        feeder = new RewardFeeder(
            IPoolManager(POOL_MANAGER), IRecordsPot(address(records)), deployer, keeper, infra, 500, 10, 1500e6
        );
        c = DeployStationsSplit.Config(
            deployer, address(feeder), address(0), imdBurn, infra, address(feeder), address(0), address(records),
            deployer, keeper
        );
    }

    function test_RobinhoodQuartersGoToRewardFeederAndTreasuryFeeder() public {
        (DeployStationsSplit.Config memory c, RewardFeeder feeder) = _robinhood();
        script.checkInputs(c);
        DeployStationsSplit.Deployment memory d = script.deploy(c);
        script.check(c, d);
        TreasuryFeeder t = d.treasuryFeeder;
        assertEq(t.usdg(), USDG);
        assertEq(t.treasury(), TREASURY);
        assertEq(t.keeper(), keeper);
        assertEq(t.owner(), deployer);
        assertEq(t.sweepTo(), infra);
        (address[] memory a,,) = d.splitter.payees();
        assertEq(a[0], address(feeder));
        assertEq(a[1], address(t));
        assertEq(script.stable(), USDG);
        assertEq(script.recordFile(true), "deployments/stations-split-robinhood.preview.json");
        Usdc6(USDG).mint(address(d.splitter), 40e6);
        d.splitter.releaseToken(USDG);
        assertEq(Usdc6(USDG).balanceOf(address(feeder)), 10e6);
        assertEq(Usdc6(USDG).balanceOf(address(t)), 10e6);
        assertEq(Usdc6(USDG).balanceOf(imdBurn), 10e6);

        DeployStationsSplit.Config memory w = _copy(c);
        w.keeper = other;
        vm.expectRevert(bytes("TreasuryFeeder mismatch: keeper"));
        script.check(w, d);
    }

    function _copy(DeployStationsSplit.Config memory c) internal pure returns (DeployStationsSplit.Config memory) {
        return abi.decode(abi.encode(c), (DeployStationsSplit.Config));
    }

    function test_RobinhoodInputChecks() public {
        (DeployStationsSplit.Config memory c, RewardFeeder feeder) = _robinhood();
        DeployStationsSplit.Config memory w = _copy(c);
        w.recordHolders = address(0);
        vm.expectRevert(bytes("PAYOUT_FEEDER: no verified record of it (run DeployRecords verify() first)"));
        script.checkInputs(w);
        w = _copy(c);
        w.recordHolders = other;
        vm.expectRevert(bytes("PAYOUT_FEEDER: not the one in the verified deployment record"));
        script.checkInputs(w);
        w = _copy(c);
        w.records = other;
        vm.expectRevert(bytes("PAYOUT_FEEDER: does not feed the deployed IDM Records"));
        script.checkInputs(w);
        w = _copy(c);
        w.keeper = other;
        vm.expectRevert(bytes("PAYOUT_KEEPER: not the RewardFeeder's keeper (one payout bot runs both feeders)"));
        script.checkInputs(w);
        w = _copy(c);
        w.imdBurn = TREASURY;
        vm.expectRevert(bytes("STATIONS_IMD_BURN and PulseTreasury: must be different addresses"));
        script.checkInputs(w);
        w = _copy(c);
        w.imdBurn = infra;
        vm.expectRevert(bytes("stations payees: must be four different addresses"));
        script.checkInputs(w);
        // A lookalike feeder (right answers, other code) is refused.
        address fake = makeAddr("fake feeder");
        vm.etch(fake, address(new Usdc6()).code);
        vm.mockCall(fake, abi.encodeWithSignature("rewardToken()"), abi.encode(USDG));
        w = _copy(c);
        (w.holders, w.recordHolders) = (fake, fake);
        vm.expectRevert(bytes("RewardFeeder code mismatch: not this build's contract (length)"));
        script.checkInputs(w);
        assertEq(address(feeder.records()), c.records);
    }

    function test_StationsInputChecks() public {
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain: expected Base 8453 or Robinhood Chain 4663"));
        script.checkInputs(_baseConfig(other));

        mockBase();
        HolderRewards rewards = _rewards();
        DeployStationsSplit.Config memory c = _baseConfig(address(rewards));
        c.imdBurn = infra;
        vm.expectRevert(bytes("stations payees: must be four different addresses"));
        script.checkInputs(c);
        c = _baseConfig(address(rewards));
        c.imdBurn = address(0);
        vm.expectRevert(bytes("STATIONS_IMD_BURN: zero address"));
        script.checkInputs(c);
        c = _baseConfig(other);
        vm.expectRevert(bytes("HOLDER_REWARDS: no contract code at this address"));
        script.checkInputs(c);
        HolderRewards wrong = new HolderRewards(IERC20Like2(address(new Usdc6())), deployer, rewardsKeeper, address(0), 1 hours, infra);
        vm.expectRevert(bytes("HOLDER_REWARDS: not a HolderRewards paying Base USDC"));
        script.checkInputs(_baseConfig(address(wrong)));
        // HolderRewards must be the one DeployLabel verified, and the burn wallet the LabelSplitter's.
        c = _baseConfig(address(rewards));
        c.recordHolders = address(wrong);
        vm.expectRevert(bytes("HOLDER_REWARDS: not the one in the verified deployment record"));
        script.checkInputs(c);
        c = _baseConfig(address(rewards));
        c.recordHolders = address(0);
        vm.expectRevert(bytes("HOLDER_REWARDS: no verified record of it (run DeployLabel verify() first)"));
        script.checkInputs(c);
        c = _baseConfig(address(rewards));
        c.recordBurn = other;
        vm.expectRevert(bytes("BRIDGE_BURN: not the LabelSplitter's burn wallet in deployments/label-base.json"));
        script.checkInputs(c);
        c = _baseConfig(address(rewards));
        c.idmBurn = address(script);
        c.recordBurn = address(script);
        vm.expectRevert(bytes("BRIDGE_BURN: must be a plain wallet (EOA), found contract code"));
        script.checkInputs(c);
        c = _baseConfig(address(rewards));
        c.idmBurn = address(0);
        vm.expectRevert(bytes("BRIDGE_BURN: zero address"));
        script.checkInputs(c);
    }
}

/// The only test that touches the process environment: Forge runs tests in parallel and env is shared, so every
/// env-driven step of both scripts runs here, in order.
contract LabelDeployEnvTest is LabelDeployFixture {
    function test_RunAndVerifyFromEnv() public {
        skipUnlessWritable();
        mockRobinhood();
        DeployRecords records = new DeployRecords();
        vm.setEnv("DEPLOYER", vm.toString(deployer));
        vm.setEnv("RECORDS_SIGNER", vm.toString(signer));
        vm.setEnv("PAYOUT_KEEPER", vm.toString(keeper));
        vm.setEnv("LABEL_INFRA", vm.toString(infra));
        // The stand-in validator at Limit Break's address is not Limit Break's code: pin the stand-in's hash here.
        vm.setEnv("RECORDS_VALIDATOR_CODEHASH", vm.toString(LB_VALIDATOR.codehash));
        string memory preview = "deployments/test-env-records.preview.json";
        vm.setEnv("DEPLOY_RECORD", preview);
        DeployRecords.Deployment memory d = records.run();
        string memory json = vm.readFile(preview);
        assertEq(vm.parseJsonString(json, ".status"), "simulated");
        assertEq(vm.parseJsonAddress(json, ".records"), address(d.records));
        assertEq(vm.parseJsonString(json, ".baseURI"), "https://theidm.fun/records/"); // the default
        assertEq(vm.parseJsonAddress(json, ".owner"), deployer); // RECORDS_OWNER defaults to DEPLOYER
        assertEq(vm.parseJsonAddress(json, ".transferValidator"), LB_VALIDATOR); // RECORDS_VALIDATOR's default
        assertEq(d.records.getTransferValidator(), LB_VALIDATOR);
        assertTrue(vm.parseJsonBool(json, ".walletOtc")); // on by default with Limit Break v5
        assertEq(ITransferValidatorV5(LB_VALIDATOR).getCollectionSecurityPolicy(address(d.records)).rulesetOptions, 6);

        // verify() from a broadcast file ...
        string[] memory names = new string[](3);
        (names[0], names[1], names[2]) = ("IDMRecords", "RewardFeeder", "RevenueSplitter");
        address[] memory addrs = new address[](3);
        (addrs[0], addrs[1], addrs[2]) = (address(d.records), address(d.feeder), address(d.splitter));
        string memory bfile = "deployments/test-env-broadcast.preview.json";
        vm.writeFile(bfile, broadcastJson(names, addrs, "0x1"));
        vm.setEnv("DEPLOY_BROADCAST", bfile);
        string memory verified = "deployments/test-env-records-verified.preview.json";
        vm.setEnv("DEPLOY_RECORD", verified);
        records.verify();
        json = vm.readFile(verified);
        assertEq(vm.parseJsonString(json, ".status"), "verified");
        assertEq(vm.parseJsonBytes32(json, ".royaltySplitterTx"), bytes32(uint256(3)));

        // ... or from env, all three or none.
        vm.setEnv("RECORDS_CONTRACT", vm.toString(address(d.records)));
        vm.expectRevert(bytes("set all of RECORDS_CONTRACT, PAYOUT_FEEDER, PAYOUT_SPLITTER, or none"));
        records.verify();
        vm.setEnv("PAYOUT_FEEDER", vm.toString(address(d.feeder)));
        vm.setEnv("PAYOUT_SPLITTER", vm.toString(address(d.splitter)));
        records.verify();

        // A signer change fails verify while it waits, and after it until RECORDS_SIGNER names the new one.
        address rotated = makeAddr("rotated signer");
        vm.prank(deployer);
        d.records.setSigner(rotated);
        vm.expectRevert(bytes("IDMRecords mismatch: a signer change is pending (activate or wait)"));
        records.verify();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(deployer);
        d.records.activateSigner();
        vm.expectRevert(bytes("IDMRecords mismatch: signer"));
        records.verify();
        vm.setEnv("RECORDS_SIGNER", vm.toString(rotated));
        records.verify();

        // Base: HolderRewards and the LabelSplitter.
        mockBase();
        DeployLabel label = new DeployLabel();
        vm.setEnv("REWARDS_KEEPER", vm.toString(rewardsKeeper));
        vm.setEnv("BRIDGE_BURN", vm.toString(burn));
        string memory labelPreview = "deployments/test-env-label.preview.json";
        vm.setEnv("DEPLOY_RECORD", labelPreview);
        DeployLabel.Deployment memory ld = label.run();
        json = vm.readFile(labelPreview);
        assertEq(vm.parseJsonAddress(json, ".labelSplitter"), address(ld.splitter));
        assertEq(vm.parseJsonAddress(json, ".holderRewards"), address(ld.rewards));
        assertEq(vm.parseJsonAddress(json, ".rewardsOwner"), deployer); // REWARDS_OWNER defaults to DEPLOYER
        assertEq(vm.parseJsonUint(json, ".rootDelay"), 12 hours); // REWARDS_DELAY defaults to 12 h
        vm.setEnv("LABEL_SPLITTER", vm.toString(address(ld.splitter)));
        vm.expectRevert(bytes("set both HOLDER_REWARDS and LABEL_SPLITTER, or neither"));
        label.verify();
        vm.setEnv("HOLDER_REWARDS", vm.toString(address(ld.rewards)));
        label.verify();
        json = vm.readFile(labelPreview);
        assertEq(vm.parseJsonString(json, ".status"), "verified");
        assertEq(vm.parseJsonAddress(json, ".sweepTo"), infra);
        vm.setEnv("BRIDGE_BURN", vm.toString(other));
        vm.expectRevert(bytes("LabelSplitter mismatch: burn payee"));
        label.verify();
        vm.setEnv("BRIDGE_BURN", vm.toString(burn));

        // Base: the Stations splitter, paying HolderRewards' shared pool. It reads the verified label record.
        DeployStationsSplit stations = new DeployStationsSplit();
        vm.setEnv("STATIONS_IMD_BURN", vm.toString(imdBurn));
        vm.setEnv("STATIONS_LABEL_RECORD", "deployments/test-env-missing.json");
        vm.expectRevert(bytes("HOLDER_REWARDS: no verified record of it (run DeployLabel verify() first)"));
        stations.run();
        vm.setEnv("STATIONS_LABEL_RECORD", labelPreview);
        string memory stationsPreview = "deployments/test-env-stations.preview.json";
        vm.setEnv("DEPLOY_RECORD", stationsPreview);
        RevenueSplitter ss = stations.run().splitter;
        json = vm.readFile(stationsPreview);
        assertEq(vm.parseJsonString(json, ".network"), "base");
        assertEq(vm.parseJsonAddress(json, ".stationsSplitter"), address(ss));
        assertEq(vm.parseJsonAddress(json, ".holders"), address(ld.rewards));
        assertEq(vm.parseJsonAddress(json, ".idmBurn"), burn);
        vm.setEnv("STATIONS_SPLITTER", vm.toString(address(ss)));
        stations.verify();
        vm.removeFile(stationsPreview);

        vm.removeFile(preview);
        vm.removeFile(bfile);
        vm.removeFile(verified);
        vm.removeFile(labelPreview);
    }
}

/// Rehearsals on forks of the real chains. No transaction leaves the machine: Forge executes the broadcasts locally.
///   FORK_RPC=https://rpc.mainnet.chain.robinhood.com BASE_FORK_RPC=https://mainnet.base.org \
///     forge test --match-contract LabelDeployForkTest
/// Each test is skipped when its RPC is not set.
contract LabelDeployForkTest is LabelDeployFixture {
    uint256 constant SIGNER_KEY = 0x5161E7;

    function test_RobinhoodRehearsal() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        DeployRecords script = new DeployRecords();
        DeployRecords.Config memory c = recordsConfig();
        c.signer = vm.addr(SIGNER_KEY);
        c.validator = script.DEFAULT_VALIDATOR(); // the real ERC721-C validator, as the owner deploys by default
        c.validatorCodehash = script.V5_CODEHASH(); // pinned, as loadConfig() does by default
        c.walletOtc = true; // the owner's decision, the script's default with v5
        script.checkInputs(c); // the real USDG, $IDM, validator, PulseTreasury and ETH/USDG pool
        DeployRecords.Deployment memory d = script.deploy(c);
        script.check(c, d);
        script.summary(c, d, "fork rehearsal");

        // A minted track, as the voucher service signs it: 1M $IDM held at the mint.
        address alice = makeAddr("alice");
        IDMRecords.Voucher memory v = IDMRecords.Voucher(
            alice, 7, keccak256("metadata"), 1, 1, uint64(block.timestamp + 1 hours), 1_000_000e18
        );
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, d.records.voucherDigest(v));
        deal(IDM, alice, 1_000_000e18 - 1);
        vm.prank(alice);
        vm.expectRevert(IDMRecords.BalanceTooLow.selector); // the real $IDM balanceOf
        d.records.mint(v, abi.encodePacked(r, s, sv));
        deal(IDM, alice, 1_000_000e18);
        vm.prank(alice);
        d.records.mint(v, abi.encodePacked(r, s, sv));
        assertEq(d.records.tokenURI(7), "https://theidm.fun/records/7/metadata.json");

        // Royalties in ETH and in WETH (an accepted offer), then the release.
        vm.deal(address(d.splitter), 0.02 ether);
        vm.deal(RH_WETH, RH_WETH.balance + 0.02 ether); // backing for the unwrap
        deal(RH_WETH, address(d.splitter), 0.02 ether);
        uint256 treasuryBefore = TREASURY.balance;
        d.splitter.unwrapWeth();
        d.splitter.release();
        assertEq(TREASURY.balance - treasuryBefore, 0.01 ether);
        assertEq(infra.balance, 0.01 ether);
        assertEq(address(d.feeder).balance, 0.02 ether);

        // The Stations holders' quarter (USDG) and the royalty ETH, fed as the payout keeper does it: all to the pool.
        deal(USDG, address(d.feeder), 1e6);
        vm.prank(keeper);
        (uint256 out, uint256 pooled) = d.feeder.feed(20e6); // 0.02 ETH is ~$45
        assertGt(out, 20e6);
        assertEq(pooled, out + 1e6);
        assertEq(d.records.claimable(7), 1e6 + out);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        vm.prank(alice);
        d.records.claim(ids);
        assertEq(IERC20View(USDG).balanceOf(alice), 1e6 + out);
    }

    /// Limit Break's Creator Token Transfer Validator v5 on Robinhood Chain, with the rules it applies to a collection
    /// that has not configured anything: what holders and marketplaces can do with an IDM Record.
    function test_RobinhoodValidatorV5() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        // The code read on 2026-11-04: Base's v5 byte for byte, except the chain id cached for EIP-712.
        assertEq(LB_VALIDATOR.codehash, 0xcf4eb611d0a4264a3cca483100d883e21545581c69b80e9d0cc29606d4b93dcc);
        address[] memory whitelist = IValidatorV5(LB_VALIDATOR).getListAccounts(0, 1);
        address[] memory authorizers = IValidatorV5(LB_VALIDATOR).getListAccounts(0, 2);
        address paymentProcessor = 0x9a1D00000000fC540e2000560054812452eB5366;
        address openSeaSignedZone = 0x000056F7000000EcE9003ca63978907a00FFD100;
        assertTrue(_has(whitelist, paymentProcessor));
        assertTrue(_has(authorizers, openSeaSignedZone));

        DeployRecords script = new DeployRecords();
        DeployRecords.Config memory c = recordsConfig();
        c.signer = vm.addr(SIGNER_KEY);
        c.validator = script.DEFAULT_VALIDATOR();
        DeployRecords.Deployment memory d = script.deploy(c);
        IDMRecords n = d.records;

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address stranger = makeAddr("some other marketplace");
        IDMRecords.Voucher memory v = IDMRecords.Voucher(alice, 1, keccak256("m"), 1, 1, uint64(block.timestamp + 1 hours), 0);
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, n.voucherDigest(v));
        vm.prank(alice);
        n.mint(v, abi.encodePacked(r, s, sv)); // mints are not checked by the validator

        vm.startPrank(alice);
        n.transferFrom(alice, bob, 1); // the holder moves her own record
        vm.stopPrank();
        assertEq(n.ownerOf(1), bob);

        vm.startPrank(bob);
        n.setApprovalForAll(stranger, true);
        n.setApprovalForAll(paymentProcessor, true);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(); // an operator off the list cannot move it: no sale that skips the royalty
        n.transferFrom(bob, alice, 1);
        vm.prank(paymentProcessor);
        n.transferFrom(bob, alice, 1); // a listed marketplace can
        assertEq(n.ownerOf(1), alice);

        // Contract wallets (a Safe, a smart account): a holder can send a record to one, but under v5's default
        // rules the contract cannot move it on by itself; it can still sell through a listed marketplace.
        ContractWallet safe = new ContractWallet();
        vm.prank(alice);
        n.safeTransferFrom(alice, address(safe), 1);
        vm.expectRevert(bytes4(keccak256("CreatorTokenTransferValidator__OTCNotAllowedForSmartWallets()")));
        safe.send(n, bob, 1);
        safe.approve(n, paymentProcessor);
        vm.prank(paymentProcessor);
        n.transferFrom(address(safe), bob, 1);
        assertEq(n.ownerOf(1), bob);

        // The same for a wallet upgraded with EIP-7702 (an EOA whose code is a delegation).
        vm.etch(bob, abi.encodePacked(hex"ef0100", address(0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B)));
        vm.prank(bob);
        vm.expectRevert(bytes4(keccak256("CreatorTokenTransferValidator__OTCNotAllowedFor7702Delegates()")));
        n.transferFrom(bob, alice, 1);
        vm.prank(paymentProcessor);
        n.transferFrom(bob, alice, 1); // bob approved Payment Processor above
        assertEq(n.ownerOf(1), alice);

        // Owner decision 2026-11-04: allow contract and 7702 wallets. A stranger cannot change the rules; the owner
        // applies them as the script does (step 5a), and the script reads them back.
        vm.prank(stranger);
        vm.expectRevert();
        ITransferValidatorV5(LB_VALIDATOR).setRulesetOfCollection(address(n), 0, address(0), 0, 6);
        vm.prank(deployer);
        ITransferValidatorV5(LB_VALIDATOR).setRulesetOfCollection(address(n), 0, address(0), 0, 6);
        c.walletOtc = true;
        script.check(c, d);
        CollectionSecurityPolicy memory p = ITransferValidatorV5(LB_VALIDATOR).getCollectionSecurityPolicy(address(n));
        assertEq(p.rulesetId, 0);
        assertEq(p.listId, 0); // still Limit Break's default list
        assertEq(p.customRuleset, address(0));
        assertEq(p.globalOptions, 0);
        assertEq(p.rulesetOptions, 6);
        assertEq(p.tokenType, 721);
        assertTrue(IValidatorV5(LB_VALIDATOR).isAccountInListByCollection(address(n), 1, paymentProcessor));
        assertTrue(IValidatorV5(LB_VALIDATOR).isAccountInListByCollection(address(n), 2, openSeaSignedZone));

        // (a) the contract wallet moves its own record now, (b) so does the 7702 wallet, (c) and a plain wallet.
        vm.prank(alice);
        n.safeTransferFrom(alice, address(safe), 1);
        safe.send(n, bob, 1);
        assertEq(n.ownerOf(1), bob);
        vm.prank(bob);
        n.transferFrom(bob, alice, 1);
        assertEq(n.ownerOf(1), alice);
        vm.prank(alice);
        n.transferFrom(alice, bob, 1);
        assertEq(n.ownerOf(1), bob);
        // (d) an unlisted operator is still refused, whoever holds the record: no sale that skips the royalty.
        vm.prank(bob);
        n.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        vm.expectRevert();
        n.transferFrom(bob, alice, 1);
        vm.prank(bob);
        n.safeTransferFrom(bob, address(safe), 1);
        safe.approve(n, stranger);
        vm.prank(stranger);
        vm.expectRevert();
        n.transferFrom(address(safe), alice, 1);
        // (e) a listed marketplace still can.
        vm.prank(paymentProcessor);
        n.transferFrom(address(safe), alice, 1);
        assertEq(n.ownerOf(1), alice);
    }

    function _has(address[] memory list, address a) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    function test_BaseRehearsal() public {
        string memory rpc = vm.envOr("BASE_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        DeployLabel script = new DeployLabel();
        DeployLabel.Config memory c = labelConfig();
        script.checkInputs(c); // the real USDC
        DeployLabel.Deployment memory d = script.deploy(c);
        script.check(c, d);
        script.summary(c, d, "fork rehearsal");

        deal(BASE_USDC, address(d.splitter), 20e6); // x402 sales paid to payTo
        d.splitter.releaseToken(BASE_USDC);
        assertEq(IERC20View(BASE_USDC).balanceOf(address(d.rewards)), 10e6);
        assertEq(IERC20View(BASE_USDC).balanceOf(burn), 5e6);
        assertEq(IERC20View(BASE_USDC).balanceOf(infra), 5e6);
        assertEq(IERC20View(BASE_USDC).balanceOf(address(d.splitter)), 0);

        // A one-leaf root for token 7, held by a plain wallet: anyone pushes it after the delay.
        address alice = makeAddr("alice");
        bytes32 leaf = d.rewards.leaf(7, alice, true, 10e6);
        vm.prank(rewardsKeeper);
        d.rewards.proposeRoot(1, leaf, 10e6, keccak256("epoch 1"));
        vm.warp(block.timestamp + 12 hours);
        assertEq(d.rewards.claim(7, alice, true, 10e6, new bytes32[](0)), 10e6);
        assertEq(IERC20View(BASE_USDC).balanceOf(alice), 10e6);
    }
}
