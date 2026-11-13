# IDM Records contracts

Smart contracts of IDM Records, the onchain music label of [theidm.fun](https://theidm.fun): the record NFT
collection with its USDG reward pot, the fee splitters, the feeders that swap royalty ETH in the ETH/USDG Uniswap v4
pool, the x402 sales rewards on Base and the Arc to Base USDC forwarder.

Nothing here is deployed yet. This repository is published for review before the mainnet deploy.

## Scope

| File | Lines | Chain | What it does |
| --- | ---: | --- | --- |
| `src/IDMRecords.sol` | 579 | Robinhood Chain 4663 | ERC-721 collection, cap 1000. Mint by EIP-712 voucher from a signer service; only the voucher's `to` may submit it. USDG reward pot per token (`deposit`, `depositPool`, `claim`). ERC-2981 royalty, ERC721-C transfer validator (Limit Break v5), 48 h signer rotation, two-step ownership. |
| `src/RewardFeeder.sol` | 111 | Robinhood | Keeper-only: swaps the ETH it receives to USDG in the ETH/USDG pool and pays it into the collection's shared pool. Owner-set price floor `minUsdgPerEth`. No withdrawal. |
| `src/TreasuryFeeder.sol` | 97 | Robinhood | Keeper-only: swaps USDG to ETH in the same pool and sends it to the $IDM treasury. Owner-set price ceiling `maxUsdgPerEth`. |
| `src/EthPoolSwap.sol` | 94 | Robinhood | Shared exact-input swap against the v4 PoolManager (`unlock` callback) used by both feeders. |
| `src/KeeperOwned.sol` | 59 | Robinhood | Owner / keeper roles of the feeders. |
| `src/RevenueSplitter.sol` | 144 | Robinhood, Base | Ownerless push splitter for ETH and ERC-20 with fixed payees and shares; optional WETH unwrap; ETH-only payee whose tokens go to a sink. |
| `src/HolderRewards.sol` | 292 | Base 8453 | USDC rewards for record holders, paid against keeper-posted Merkle roots with a delay, guardian revoke, pushed or pulled claims. |
| `src/ArcForwarder.sol` | 136 | Arc 5042 | Ownerless: sends all its USDC to a fixed recipient on Base with Circle CCTP v2. |
| `script/*.s.sol` | 1449 | | Deploy scripts with dry run, on-chain checks (`verify()`), pinned code hashes and price band checks. In scope as far as they set security-relevant parameters. |

Out of scope: `lib/` (vendored upstream code, see `DEPENDENCIES.md`), the $IDM token and its hook (already live),
the off-chain services (voucher signer, payout keeper, rewards keeper). Comments that point to `docs/...` or `bot/...`
refer to the label's private main repository; what an auditor needs from them is summarised below.

## Money flow

```text
NFT royalty (ETH/WETH, Robinhood) -> royalty splitter -> 50% RewardFeeder -> USDG -> IDMRecords pool (holders claim)
                                                      -> 25% $IDM treasury
                                                      -> 25% infra
x402 sale (USDC, Arc)  -> ArcForwarder --CCTP--> LabelSplitter (Base)
x402 sale (USDC, Base) -> LabelSplitter -> 50% HolderRewards (holders claim on Base)
                                        -> 25% burn wallet, 25% infra
Station fee            -> Stations splitter -> 1/4 holders, 1/4 $IDM, 1/4 IMD burn, 1/4 infra
```

## Trust model

- **Owner** (intended: a Safe). Sets the voucher signer (48 h delay, 7 day window, instant revoke), base URI until
  frozen, royalty (max 10%), transfer validator until locked, feeder keeper and price band. Cannot mint, move tokens,
  or take USDG from the pot.
- **Voucher signer** (server key). Decides who may mint which token in which drop, the wallet limit and the $IDM
  hold floor. A leaked signer key can mint the remaining supply to wallets it controls until the owner revokes it;
  it cannot touch minted tokens or rewards.
- **Keeper** (server key). Calls `feed` / `swap` only. Since the 2026-11-13 fixes the swap must land inside the
  owner's band, so a leaked keeper key can lose at most the band's gap on what the feeder holds.
- **Splitters and ArcForwarder** have no owner and no admin: payees, shares and recipients are fixed at deploy.

## Fixed after the internal review (2026-11-13)

1. `mint` accepted a voucher from any sender, so a bot could spend listed holders' wallet limits at opening or mint
   into a contract that cannot move the record. Now `msg.sender` must equal `v.to`.
2. `feed(minOut)` / `swap(minOut)` trusted the keeper's own minimum, so a leaked keeper key could sandwich the feeder
   through the pool (fork PoC: 5 ETH fed for $1.45). Now each feeder holds an owner-set band; the deploy sets it 25%
   from the pool price and `verify()` rejects a band outside 0-50%. PoCs: `test_Poc_LeakedKeeperSandwichHitsTheFloor`,
   `test_Poc_LeakedKeeperSandwichHitsTheCeiling` in `test/RewardFeeder.fork.t.sol`.

## Known and accepted

- USDG is Paxos's upgradeable token: it can be paused and addresses frozen. A frozen holder's claim fails and stays
  owed. A freeze of the collection itself, or a sender-side fee, would stop payouts.
- USDG sent to the collection without `deposit`, credit on never-minted ids, and up to 1 unit of rounding dust per
  record stay in the contract. No sweep, by design.
- Rewards follow the NFT; a seller can claim before a sale.
- The $IDM floor is checked against the balance at mint time (flash-borrowable); the real gate is the signer
  service's 7- and 21-day minimum balance.
- A splitter payee that rejects ETH blocks that splitter's ETH releases (push payouts, fixed payees).
- The feeders' pool is fixed. If its liquidity leaves, funds wait in the feeder.
- `lockTransferValidator()` and `freezeMetadata()` are one-way; no script calls them.

## Build and test

Foundry 1.8.x, solc 0.8.26 (pinned in `foundry.toml`). All dependencies are vendored; nothing is downloaded.

```sh
forge build
forge test                                    # unit, fuzz and invariant tests; fork tests skip
FORK_RPC=https://rpc.mainnet.chain.robinhood.com \
BASE_FORK_RPC=https://mainnet.base.org \
forge test                                    # + Robinhood and Base fork tests, deploy rehearsals, PoCs
ARC_FORK_RPC=<Arc RPC> forge test --match-contract ArcForwarderForkTest
```

Expected: 115 pass without forks; 132 pass with the Robinhood and Base forks (the 2 Arc fork tests need `ARC_FORK_RPC`).

`shasum -a 256 -c DEPENDENCY_SHA256SUMS` checks every vendored file.

## Fixed addresses used by the scripts

| | Address |
| --- | --- |
| Robinhood Chain USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Robinhood Chain WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Robinhood Chain v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| $IDM (hold token) | `0x4Fe9f3823791c8b187B81aB8B7398d793FEd28f6` |
| $IDM treasury (PulseTreasury) | `0xAb64b47daA0f68e50BDF776e73B4245D78575a6c` |
| Limit Break Transfer Validator v5 | `0x721C008fdff27BF06E7E123956E2Fe03B63342e3` |
| Base USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

## Licence

MIT (`LICENSE`). Vendored files keep their upstream licences.
