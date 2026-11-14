# IDM Records contracts

Smart contracts of IDM Records, the onchain music label of [theidm.fun](https://theidm.fun): the record NFT
collection with its USDG reward pot, the fee splitters, the feeders that swap royalty ETH in the ETH/USDG Uniswap v4
pool, the x402 sales rewards on Base and the Arc to Base USDC forwarder.

Nothing here is deployed yet. This repository is published for review before the mainnet deploy.

## Scope

| File | Lines | Chain | What it does |
| --- | ---: | --- | --- |
| `src/IDMRecords.sol` | 587 | Robinhood Chain 4663 | ERC-721 collection, cap 1000. Mint by EIP-712 voucher from a signer service; only the voucher's `to` may submit it, and only for ids the owner opened (`mintableUpTo`, drop by drop). USDG reward pot per token (`deposit`, `depositPool`, `claim`). ERC-2981 royalty, ERC721-C transfer validator (Limit Break v5), 48 h signer rotation, two-step ownership. |
| `src/RewardFeeder.sol` | 122 | Robinhood | Keeper-only: swaps the ETH it receives (up to `maxEthIn` per call) to USDG in the ETH/USDG pool and pays all USDG held into the collection's shared pool. Owner-set price floor `minUsdgPerEth`. No withdrawal. |
| `src/TreasuryFeeder.sol` | 109 | Robinhood | Keeper-only: swaps USDG (up to `maxUsdgIn` per call) to ETH in the same pool and sends all ETH held to the $IDM treasury. Owner-set price ceiling `maxUsdgPerEth`. The $IDM payee of both Robinhood splitters. |
| `src/EthPoolSwap.sol` | 94 | Robinhood | Shared exact-input swap against the v4 PoolManager (`unlock` callback) used by both feeders. |
| `src/KeeperOwned.sol` | 59 | Robinhood | Owner / keeper roles of the feeders. |
| `src/RevenueSplitter.sol` | 145 | Robinhood, Base | Ownerless push splitter for ETH and ERC-20 with fixed payees and shares; optional WETH unwrap; ETH-only payee whose tokens go to a sink. |
| `src/HolderRewards.sol` | 336 | Base 8453 | USDC rewards for record holders, paid against keeper-posted Merkle roots with a delay, guardian revoke, pushed (plain accounts only) or pulled claims. |
| `src/ArcForwarder.sol` | 136 | Arc 5042 | Ownerless: sends all its USDC to a fixed recipient on Base with Circle CCTP v2. |
| `script/*.s.sol` | 1510 | | Deploy scripts with dry run, on-chain checks (`verify()`), pinned code hashes and price band checks. In scope as far as they set security-relevant parameters. |

Out of scope: `lib/` (vendored upstream code, see `DEPENDENCIES.md`), the $IDM token and its hook (already live),
the off-chain services (voucher signer, payout keeper, rewards keeper). Comments that point to `docs/...` or `bot/...`
refer to the label's private main repository; what an auditor needs from them is summarised below.

## Money flow

```text
NFT royalty (ETH/WETH/USDG, Robinhood) -> royalty splitter -> 50% RewardFeeder -> USDG -> IDMRecords pool (holders claim)
                                                           -> 25% TreasuryFeeder -> ETH -> $IDM treasury (buy and burn)
                                                           -> 25% infra
x402 sale (USDC, Arc)  -> ArcForwarder --CCTP--> LabelSplitter (Base)
x402 sale (USDC, Base) -> LabelSplitter -> 50% HolderRewards (holders claim on Base)
                                        -> 25% burn wallet, 25% infra
Station fee            -> Stations splitter -> 1/4 holders, 1/4 $IDM (Robinhood: the same TreasuryFeeder), 1/4 IMD burn,
                                               1/4 infra
```

## Trust model

- **Owner** (intended: a Safe). Sets the voucher signer (48 h delay, 7 day window, instant revoke), which token ids
  vouchers may mint (`setMintableUpTo`), base URI until frozen, royalty (max 10%), the transfer validator (no lock),
  feeder keeper and price band. Cannot mint, move tokens, or take USDG from the pot. A validator that refuses
  transfers would stop them until the owner changes it.
- **Voucher signer** (server key). Decides who may mint which open token in which drop, the wallet limit and the
  $IDM hold floor. A leaked signer key can mint the open, unminted ids of the current drop (and take credits gifted
  to them) until the owner revokes it; it cannot touch minted tokens or their rewards.
- **Keeper** (server key). Calls `feed` / `swap` only, and chooses when: a pool deposit is shared by the records
  minted at that moment, so feed timing decides which holders get money collected before or during a drop (the
  operator feeds before each drop opens). Since the 2026-11-13 fixes the swap must land inside the owner's band, so a
  leaked keeper key can lose at most the band's gap on what the feeder holds. The band is an absolute price set at
  deploy, not a share of the market: as ETH moves, that gap grows on one side, so the owner keeps it near the pool
  price (`setFloor` / `setCeiling`; nothing in the contract bounds it).
- **Rewards keeper and guardian** (Base). The keeper posts Merkle roots; each waits `rootDelay` (12 h) and the owner
  or the guardian can revoke it then. Once a root matures nothing stops it, so the deploy requires a guardian and a
  watcher runs with its key.
- **Splitters and ArcForwarder** have no owner and no admin: payees, shares and recipients are fixed at deploy.

## Fixed after the internal review (2026-11-13)

1. `mint` accepted a voucher from any sender, so a bot could spend listed holders' wallet limits at opening or mint
   into a contract that cannot move the record. Now `msg.sender` must equal `v.to`.
2. `feed(minOut)` / `swap(minOut)` trusted the keeper's own minimum, so a leaked keeper key could sandwich the feeder
   through the pool (fork PoC: 5 ETH fed for $1.45). Now each feeder holds an owner-set band; the deploy sets it 25%
   from the pool price and `verify()` rejects a band outside 0-50%. PoCs: `test_Poc_LeakedKeeperSandwichHitsTheFloor`,
   `test_Poc_LeakedKeeperSandwichHitsTheCeiling` in `test/RewardFeeder.fork.t.sol`.

## Fixed after the IMD swarm audit (2026-11-13)

The first swarm pass (job `71b19999-9a93-444e-9971-32ce0ebbadb8`, `audit-imported-code`, commit `6a404a6`) found no
critical or high issue. Fixed in this commit:

1. A blocking validator plus `lockTransferValidator()` could freeze every record for good: the lock is removed.
2. A leaked signer key could mint all unminted ids in one transaction and keep most of every later pool deposit:
   vouchers now mint only ids up to the owner-set `mintableUpTo` (`test_mintableUpTo_boundsWhatAVoucherCanMint`).
3. 1 wei of ETH (or 1 unit of USDG) sent to a feeder failed the price band and held back the rest: dust under
   0.01 USDG waits for the next swap (`test_Poc_DustDoesNotBlockTheFeeders`, fork).
4. An operator approved for all could push a contract holder's USDG into it: a holder with code claims only itself
   (`test_claim_operatorCannotPushRewardsIntoAContract`).

## Fixed after the IMD swarm audit panel (2026-11-14)

The four-seat panel (job `88d4aa11-292b-4c18-95c5-dc9f3083f63b`, `template: audit`, commit `3a2e794`; report at
https://api.imd.fun/jobs/88d4aa11-292b-4c18-95c5-dc9f3083f63b/report.md) confirmed the four fixes above and found
1 medium, 4 low and 5 info, no critical or high. Fixed in this commit:

1. Medium: `RewardFeeder.feed` swapped all its ETH in the call that pools its USDG, so ETH the band could not take in
   one swap (a moved market, thin liquidity, a large balance) kept the holders' USDG in the feeder. Now
   `feed(maxEthIn, minOut)` bounds the swap and `feed(0, 0)` pools without one (`test/FeederSlices.t.sol`, the
   panel's proof against the fix).
2. Low: the mirror in `TreasuryFeeder.swap`. Now `swap(maxUsdgIn, minOut)`; `swap(0, 0)` sends the ETH held.
3. Low: in `HolderRewards`, a root giving one token less than it already took made the other claims revert. A claim
   now pays what the root's total still covers; the rest stays owed (`test_Poc_PerTokenDecreasePaysWhatTheTotalCovers`).
4. Low: `HolderRewards` pushed USDC into a contract account when the keeper's leaf said `pushable`. An account with
   code on Base (EIP-7702 wallets included) is now paid only when it claims itself
   (`test_StrangerCannotPushUsdcIntoAContractAccount`).
5. Info: one failed transfer reverted the whole `claimMany` batch. A leaf that cannot be paid is skipped with
   `ClaimFailed` (`test_ClaimManySkipsALeafItCannotPay`).
6. Info: a royalty paid in USDG sent the treasury's quarter to infra (the treasury was an ETH-only payee). The royalty
   splitter now pays its burn quarter to the TreasuryFeeder, deployed before it, so token royalties are burned too.
7. Info: the deploy no longer allows a HolderRewards without a guardian.

Documented instead of changed (trust model above, known risks below): the absolute band, the keeper's feed timing,
the seller's claim window on Base.

## Hardened after a self re-check (2026-11-14)

- `DeployStationsSplit` on Robinhood reads the IDM Records royalty receiver on chain and requires it to be a
  `RevenueSplitter` paying this RewardFeeder and TreasuryFeeder, so a stale deployment record cannot point the Stations
  splitter at an orphan TreasuryFeeder (`test_RobinhoodInputChecks`).
- A deployment record of an earlier step is accepted only if its `chainId` is the chain being deployed to.
- Off-chain (main repo): the payout keeper runs each action on its own and, when a swap reverts, sends the same call
  again without the swap (`feed(0, 0)` / `swap(0, 0)`), so pooling and the ETH send never wait on a swap.

## Known and accepted

- USDG is Paxos's upgradeable token: it can be paused and addresses frozen. A frozen holder's claim fails and stays
  owed. A freeze of the collection itself, or a sender-side fee, would stop payouts.
- USDG sent to the collection without `deposit`, credit on never-minted ids, and up to 1 unit of rounding dust per
  record stay in the contract. No sweep, by design.
- Rewards follow the NFT; a seller can claim before a sale. On Base the leaf names the holder at the root's block, so
  a seller can still claim there until a root built after the sale matures (keeper cadence plus 12 h).
- The $IDM floor is checked against the balance at mint time (flash-borrowable); the real gate is the signer
  service's 7- and 21-day minimum balance.
- A splitter payee that rejects ETH blocks that splitter's ETH releases (push payouts, fixed payees).
- The feeders' pool is fixed. If its liquidity leaves, funds wait in the feeder.
- `freezeMetadata()` is one-way; no script calls it.

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

Expected: 121 pass without forks; 139 pass with the Robinhood and Base forks. The 2 Arc fork tests need
`ARC_FORK_RPC`. The default profile only reads `deployments/`, so the 3 tests of the deploy record files skip;
`FOUNDRY_PROFILE=deploy forge test` runs them too (142 pass with the forks). The deploy scripts write their records,
so they run under that profile: `FOUNDRY_PROFILE=deploy forge script ...`.

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
