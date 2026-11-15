// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPharaohDlmmVault
/// @notice FROZEN external surface (W1) of the Pharaoh DLMM USDC/USDt 3-bin vault. Spec: docs/deployment-handoffs/avalanche-pharaoh-dlmm-vault-spec.md
/// ERC-4626 (asset = USDC) on the ownership NAV of vault-r3/src/r3/PharaohLiquidityVaultR3.sol, plus the DLMM band, the guard, the cap.
/// Anything not listed here (ERC-4626 views, pause, roles inherited from R3) keeps its R3 signature.
interface IPharaohDlmmVault {
    // ------------------------------------------------------------------ types
    struct InitParams {
        address asset;            // USDC
        address pairToken;        // USDt
        address pair;             // Pharaoh DLMM LBPair 0x16888EE58E706C253b821EAA637ae9b2cFeA255C (validated against factory)
        address router;           // Pharaoh DLMMRouter (must be an authorised DLMM manager, validated)
        address factory;          // DLMMFactory (getLBPairInformation(tokenX, tokenY, binStep) == pair)
        address rewarder;         // the pair's hook (getLBHooksParameters), isLinked() == true, codehash pinned below
        bytes32 rewarderImplCodehash; // codehash of the BEACON IMPLEMENTATION, not of the proxy
        address feedAsset;        // Chainlink USDC/USD (8 decimals)
        address feedPair;         // Chainlink USDT/USD (8 decimals)
        uint16  binStep;          // 1
        address owner;            // the Safe
        address rebalancer;       // the keeper wallet
        uint256 depositCap;       // 200_000_000 (USDC, 6 decimals), set HERE, atomically with initialize
        string  name;
        string  symbol;
    }

    struct GuardParams {          // all owner-settable inside the hard bounds listed in the spec section 4
        uint16 legBandBps;            // default 50   : each leg within 1.00 +- 0.50 %
        uint32 maxFeedAge;            // default 93_600 s (26 h; Chainlink stable feeds have a 24 h heartbeat)
        uint16 maxPoolOracleDevBps;   // default 60   : |pool price / oracle ratio - 1|, deposits and rebalance only
        uint32 rebalanceCooldown;     // default 120 s (> the 111 s reward-forfeiture window)
        uint16 maxRebalancesPerDay;   // default 48   (measured max in 30 d: 32)
        uint16 maxSwapBps;            // default 6000 : inventory swap <= 60 % of NAV
        uint16 maxRebalanceLossBps;   // default 50   : oracle-valued NAV after >= before * (1 - 0.50 %)
    }

    // bit flags of guardState().reasons and of GuardTripped
    // 1 FEED_ASSET_STALE_OR_BAD   2 FEED_PAIR_STALE_OR_BAD   4 ASSET_LEG_OUT_OF_BAND   8 PAIR_LEG_OUT_OF_BAND
    // 16 POOL_ORACLE_DEVIATION (live only, never latched)   32 REWARDER_UNLINKED_OR_CODEHASH_CHANGED (live only, never latched)

    // ------------------------------------------------------------------ events
    event BandOpened(uint24 lowerId, uint24 upperId, uint24 activeId, uint256 amountX, uint256 amountY);
    event Rebalanced(
        uint24 oldLowerId, uint24 oldUpperId, uint24 newLowerId, uint24 newUpperId, uint24 activeId,
        bool swapXForY, uint256 swapIn, uint256 swapOut, uint256 navBefore, uint256 navAfter
    );
    event PharHarvested(address indexed token, uint256 amount, uint256 totalSupplyShares, uint256 totalAssets);
    event GuardTripped(address indexed by, uint256 reasons);
    event GuardCleared(address indexed by);
    event GuardParamsSet(GuardParams params);
    event DepositCapSet(uint256 oldCap, uint256 newCap);
    event RedeemedInKind(address indexed owner, address indexed receiver, uint256 shares, uint256 amountX, uint256 amountY);

    // ------------------------------------------------------------------ errors
    error CapExceeded(uint256 cap, uint256 totalAssetsAfter);
    error CapAboveCeiling(uint256 requested, uint256 ceiling);
    error GuardLatched();
    error GuardUnsafe(uint256 reasons);
    error NotOutOfRange(uint24 activeId, uint24 lowerId, uint24 upperId);
    error CooldownActive(uint256 readyAt);
    error DailyRebalanceCapReached();
    error SwapTooLarge(uint256 swapIn, uint256 maxIn);
    error NavLossTooLarge(uint256 navBefore, uint256 navAfter);
    error ActiveIdMoved(uint24 expected, uint24 actual, uint24 idSlippage);
    error GuardStillUnsafe(uint256 reasons);   // clearGuard while live conditions are unsafe
    error ParamOutOfBounds();
    error PairValidationFailed(uint8 check);
    error NoBand();

    // ------------------------------------------------------------------ views (keeper + frontend)
    function depositCap() external view returns (uint256);
    function DEPOSIT_CAP_CEILING() external view returns (uint256);          // implementation immutable, 200_000_000
    function bandState() external view returns (uint24 lowerId, uint24 upperId, uint24 activeId, bool hasBand, bool outOfRange);
    /// live guard evaluation, never reverts (a reverting or stale feed is reported as a reason bit)
    function guardState() external view returns (bool unsafe, bool latched, uint256 reasons);
    /// true when rebalance() would pass every vault-side precondition at this block (before its swap / NAV checks)
    function rebalanceAllowed() external view returns (bool ok, uint256 reasonBits, uint256 readyAt);
    function guardParams() external view returns (GuardParams memory);
    function rebalancesToday() external view returns (uint16);
    function lastRebalanceAt() external view returns (uint48);

    // ------------------------------------------------------------------ rebalancer (keeper wallet)
    /// Exit-triggered re-centre. Requires: band exists, activeId outside [lowerId, upperId], guard safe and not latched, cooldown, daily cap.
    /// Burns the whole band, swaps swapIn of the over-held leg (<= maxSwapBps of NAV, min out vs oracle), re-adds 3 bins (-1,0,+1) around the NEW active id.
    /// expectedActiveId/idSlippage are the DLMM analogue of the R3 spot check. Reverts if NAV after < NAV before * (1 - maxRebalanceLossBps).
    function rebalance(
        uint24 expectedActiveId, uint24 idSlippage,
        bool swapXForY, uint256 swapIn, uint256 swapMinOut,
        uint256 amountXMin, uint256 amountYMin, uint256 deadline
    ) external;
    /// First band, from idle USDC (and idle USDt if any): same checks as rebalance except the out-of-range precondition and the cooldown.
    function openBand(uint24 expectedActiveId, uint24 idSlippage, uint256 swapMinOut, uint256 amountXMin, uint256 amountYMin, uint256 deadline) external;
    /// claims PHAR for the band ids and forwards it to the owner (R3 harvest behaviour); emits PharHarvested
    function harvestRewards() external;

    // ------------------------------------------------------------------ permissionless
    /// latches the guard if a latchable reason (bits 1, 2, 4, 8) holds right now; reverts GuardUnsafe(0) when nothing latchable holds
    function tripGuard() external;

    // ------------------------------------------------------------------ owner (the Safe)
    function clearGuard() external;                                   // only when live conditions are safe, else GuardStillUnsafe
    function setGuardParams(GuardParams calldata p) external;         // hard bounds in the spec section 4
    function setDepositCap(uint256 newCap) external;                  // <= DEPOSIT_CAP_CEILING
    function setRebalancer(address r) external;

    // ------------------------------------------------------------------ exits: NEVER gated by pause, guard, latch, cooldown, keeper, codehash pin
    /// pro-rata burn of the vault's bins and pro-rata idle balances, pays BOTH tokens, makes NO oracle read and NO swap
    function redeemInKind(uint256 shares, address receiver, address owner_) external returns (uint256 amountX, uint256 amountY);
}
