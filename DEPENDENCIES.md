# Dependencies

Solidity 0.8.26, Cancun, optimizer 200, via IR, metadata hash `none`. Tested with Foundry 1.8.5. Dependencies are
vendored files, not submodules; building downloads nothing. `DEPENDENCY_SHA256SUMS` lists every vendored file.

| Path | Upstream revision | Included scope |
| --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | Production `src/` and licenses; the real PoolManager in tests |
| `lib/v4-periphery` | [Uniswap/v4-periphery `9969eec44cfdf07e24b41de47f40276a58401976`](https://github.com/Uniswap/v4-periphery/tree/9969eec44cfdf07e24b41de47f40276a58401976) | Unmodified `test/shared/HookMiner.sol` and LICENSE |
| `lib/forge-std` | [foundry-rs/forge-std v1.17.0 `f3dae6e6ee381f25eb6a246f7da9b85c91a68219`](https://github.com/foundry-rs/forge-std/tree/f3dae6e6ee381f25eb6a246f7da9b85c91a68219) | Test `src/` and licenses |
| `lib/solmate` | [transmissions11/solmate `4b47a19038b798b4a33d9749d25e570443520647`](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | PoolManager's `Owned.sol` dependency and LICENSE |

Every file matches the official upstream archive at the listed commit, unmodified.

`test/helpers/PoolRouter.sol` is an MIT test helper copied unchanged from
[identity-md-launches/launch-1118-pixel-pool](https://github.com/identity-md-launches/launch-1118-pixel-pool/tree/661f8bf).
Vendored files keep their upstream MIT, Apache or BUSL terms; the label's own code is MIT.
