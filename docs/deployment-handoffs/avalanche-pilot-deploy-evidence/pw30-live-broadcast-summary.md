# PW30 live broadcast summary (Avalanche C-Chain, chain 43114)

Source: `contracts/broadcast/DeployAvalancheCashOnlyLending.s.sol/43114/run-latest.json` (Foundry broadcast record, commit `4bfb1549`), script `DeployAvalancheCashOnlyLending.s.sol`, signed by the Ledger deployer `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`. Generated from the stored transactions and receipts; nothing was queried or sent.

- Transactions: 30 (all receipts status `0x1`; `pending` list empty; no replaced, dropped or reverted transactions in the record)
- Nonces: 48 to 77, contiguous, one per transaction, no gaps or reuse
- Blocks: 99846691 to 99846919 (229 blocks span; deploy block = first receipt block 99846691); broadcast timestamp 2026-11-09 11:45:07 UTC
- Effective gas price: 3587500075 wei (3.5875 gwei) (identical on all receipts)
- Total gas used: **20,158,862**
- AVAX spent on gas (sum of gasUsed x effectiveGasPrice): **0.072319919 AVAX** (72319918936914650 wei). This excludes the seed capital sent to the markets (WAVAX and USDC seeds are token transfers inside tx 18, held by the markets forever), which is not gas.

| # | Nonce | Contract / function | Tx hash | Gas used | Block | Status |
|---|---|---|---|---|---|---|
| 0 | 48 | deploy AvalanchePriceOracle at `0x74eb16d81fd3b484c97ecddcdbd4cf644016c84f` | `0x0bc121a47102cf9dc666f34d355d90e24d2de545e11555409a4f7d01c3027701` | 900,516 | 99846691 | success |
| 1 | 49 | deploy GuardedAvalanchePriceOracle at `0x7bab5406cb4929f9b9492e1b2a43b65bf93aafc0` | `0x9e8f95dfefbc4421f049b75cf432085850860b5653edcec5041c54588188c302` | 429,689 | 99846718 | success |
| 2 | 50 | deploy Unitroller at `0xbe938cd7c25e0e4d0604fa3f9f0a8b5b67b3d51a` | `0x6800aade54aa1eb2dffe2e7442db8d9e60b136e8380b8aa361bb8272a8bc7dae` | 401,362 | 99846727 | success |
| 3 | 51 | deploy PeridottrollerAvalanche at `0x4419ad340b3a4cf71303c7247dda3aff9bf41ad6` | `0x773f7351f70fc25af48cfe8fce5cf32c190b5e01ef1979eaeb58dba1fa8422ee` | 5,294,149 | 99846733 | success |
| 4 | 52 | Unitroller/controller._setPendingImplementation(address) | `0x7e5edc7667d2132b885647614f458968e42342134ecbcc0f0f3dd379ca6dc7ae` | 47,519 | 99846741 | success |
| 5 | 53 | PeridottrollerAvalanche._become(address) | `0xc9650abf82c16e654c0521ae7d73a8f7f16df0644ecd47fb3d2072a269f1c946` | 58,427 | 99846749 | success |
| 6 | 54 | deploy ConfigurableJumpRateModelV2 at `0xe5a82bf40b493cf37c06851a934370f3f0896263` | `0x4d292893b2a6a1dd5544a6afdcbd80a309c78920ab58283cfa5cbd6506579bc7` | 676,173 | 99846759 | success |
| 7 | 55 | deploy PErc20Delegate at `0xab5a72e10ee33e19b7fe119c6771886141624f11` | `0x011e3708c784bb7a7d20c74dcae8f5c857602c2c105323dc70c6be47671c5544` | 4,616,815 | 99846770 | success |
| 8 | 56 | Unitroller/controller._setPriceOracle(address) | `0xd6bf0643a76cc247185ade1e75cc36100e8855b0b4c45348f68122a8b6725b8e` | 53,249 | 99846774 | success |
| 9 | 57 | Unitroller/controller._setCloseFactor(uint256) | `0xfb77898c6862d611cc00f7759c361a245d706a4f9f820a9fffc0146f0bedc613` | 52,543 | 99846782 | success |
| 10 | 58 | Unitroller/controller._setLiquidationIncentive(uint256) | `0x8f796e7e3dfad2f86cd8e0fa5530bf9ed5c2c5936abfd95170c92da5ea417ac1` | 52,900 | 99846791 | success |
| 11 | 59 | Unitroller/controller._setPauseGuardian(address) | `0x13abae5e620ca463abd59cd7a4c8cfcdd7b74973c6862b26077534c3fafe78aa` | 53,427 | 99846799 | success |
| 12 | 60 | deploy AvalancheMarketBootstrapper at `0xf8541dfef0e5a5aa4c158196eb8db318ef77dd4c` | `0x69225ea15cec8bce022c230d2dae7c39b1ac29f45d31efc97aeb118a83aa77b7` | 1,988,789 | 99846804 | success |
| 13 | 61 | deploy PErc20Delegator (pWAVAX) at `0x12f1f4fc057a76f473b781ce2fa88e55ef8581b1` | `0xab37ee62e41c343fda37ed27e9b07fead9007febd7f1cd15f6410d2e4b193ce0` | 1,769,344 | 99846812 | success |
| 14 | 62 | deploy PErc20Delegator (pUSDC) at `0x0f7849cd9e54ffb027aacaeec82007cca9470098` | `0xc0f49b00f6e4ab82632829f39ca555f53891a73c4312824e7007fefc76ff8f7b` | 1,778,550 | 99846817 | success |
| 15 | 63 | Unitroller/controller._setPendingAdmin(address) | `0xfd700e6648f0ee1cec44d9243b1c7077c79fc835bedb7d489f4391411162f4f7` | 47,475 | 99846828 | success |
| 16 | 64 | WAVAX.approve(address,uint256) | `0x1e5005ffd4536180077b4359548d73e689dced142a41437bcd5ae7d4f69a9983` | 46,147 | 99846834 | success |
| 17 | 65 | USDC.approve(address,uint256) | `0x2371109c4e7d089aa86d103284edf14c2d1d95ba601bb1d225e8d67153794f8a` | 55,437 | 99846844 | success |
| 18 | 66 | AvalancheMarketBootstrapper.bootstrap(address,address,uint256,uint256,uint256,uint256,uint256) | `0xdf287f4aa6b6df5d17cfa21002544c5a19d88f39650b3b78404ae66457373c1b` | 1,272,342 | 99846851 | success |
| 19 | 67 | WAVAX.approve(address,uint256) | `0x908dbf2823ad26cfff590a8ac2d9a530e5eba1b29ab2032ae5a20999d43c0f85` | 26,151 | 99846858 | success |
| 20 | 68 | USDC.approve(address,uint256) | `0x98f734cad54d830cc43d72723b5dd729a7a72b51534dd1dac79be649c7d69a39` | 35,501 | 99846865 | success |
| 21 | 69 | Unitroller/controller._acceptAdmin() | `0x8da156b259fce4b47b9782e33b386b87a37cdf527592f0ae0d1e37e7e1816fa1` | 34,919 | 99846872 | success |
| 22 | 70 | pWAVAX._acceptAdmin() | `0x070803a6c48f16aeb87665fcb8891634772416135056c27fa8e429a11430ec15` | 42,898 | 99846877 | success |
| 23 | 71 | pUSDC._acceptAdmin() | `0x7ab88a6328841b096beaeac31991402fb078c95a78b364351a07090d69a844e2` | 42,898 | 99846879 | success |
| 24 | 72 | AvalanchePriceOracle.configureFeed(address,address,uint32) | `0x01a362d890cac0a9674d23d5f302c1fe35bb51473cb19469ca5e9f0f47ff0d6d` | 57,721 | 99846886 | success |
| 25 | 73 | AvalanchePriceOracle.configureFeed(address,address,uint32) | `0xe72cfc1b9af8e23b14af127050713efea32b2431d1789841e91f9f45fc70666e` | 57,721 | 99846891 | success |
| 26 | 74 | AvalanchePriceOracle.registerMarket(address,address) | `0x8fba8f3faf05c7b1397a97842e9cabc0f9e32ad2edf4c5b845afe4b8a0d9d384` | 82,143 | 99846899 | success |
| 27 | 75 | AvalanchePriceOracle.registerMarket(address,address) | `0x084412f35700372728ccd0fa6d4a7fa345adf0b489da319d33d7ecd4e5df1b1e` | 89,309 | 99846907 | success |
| 28 | 76 | Unitroller/controller._setBorrowCashFloor(address,uint256) (pWAVAX) | `0x1512db115c25751753e374ced1b117fe3dc2d2f64da630e049d7e17f7eaec4dd` | 37,406 | 99846915 | success |
| 29 | 77 | Unitroller/controller._setBorrowCashFloor(address,uint256) (pUSDC) | `0x5e808011608fee3e0e353c71457fa4e810ae154d049ac054977f44d52693deb5` | 57,342 | 99846919 | success |
