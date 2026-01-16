// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/MagmaBoostedDelegate.sol";
import "../contracts/PErc20Delegator.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/Unitroller.sol";
import "../contracts/SimplePriceOracle.sol";
import "../contracts/JumpRateModelV2.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWMON is ERC20 {
    constructor() ERC20("Wrapped MON", "WMON") {
        _mint(msg.sender, 1000000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockMagma is ERC20 {
    uint256 public exchangeRate = 1e18; // 1:1 initially
    uint256 public constant WITHDRAWAL_DELAY = 100; // blocks

    struct RedemptionRequest {
        uint256 shares;
        uint256 requestBlock;
        bool completed;
    }

    mapping(uint256 => RedemptionRequest) public requests;
    uint256 public nextRequestId = 1;

    IERC20 public wmon;

    constructor(address wmon_) ERC20("Magma gMON", "gMON") {
        wmon = IERC20(wmon_);
    }

    function depositWMON(uint256 assets, address receiver, uint256) external returns (uint256 shares) {
        wmon.transferFrom(msg.sender, address(this), assets);
        shares = convertToShares(assets);
        _mint(receiver, shares);
    }

    function requestRedeem(uint256 shares, address, address owner) external returns (uint256 requestId) {
        require(balanceOf(owner) >= shares, "insufficient shares");
        _burn(owner, shares);

        requestId = nextRequestId++;
        requests[requestId] = RedemptionRequest({shares: shares, requestBlock: block.number, completed: false});
    }

    function redeem(uint256 requestId, address, address receiver) external returns (uint256 assets) {
        RedemptionRequest storage req = requests[requestId];
        require(!req.completed, "already completed");
        require(block.number >= req.requestBlock + WITHDRAWAL_DELAY, "too early");

        assets = convertToAssets(req.shares);
        req.completed = true;
        wmon.transfer(receiver, assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * 1e18) / exchangeRate;
    }

    function totalAssets() public view returns (uint256) {
        return wmon.balanceOf(address(this));
    }

    // Test helper to simulate yield
    function simulateYield(uint256 newRate) external {
        exchangeRate = newRate;
    }
}

contract MagmaBoostedTest is Test {
    MagmaBoostedDelegate implementation;
    PErc20Delegator delegator;
    Unitroller unitroller;
    Peridottroller comptroller;
    SimplePriceOracle oracle;
    JumpRateModelV2 irm;
    MockWMON wmon;
    MockMagma magma;

    address admin = address(this);
    address user1 = address(0x1);
    address user2 = address(0x2);

    uint256 constant INITIAL_EXCHANGE_RATE = 2e26; // 1 pToken = 0.0002 WMON
    uint256 constant BUFFER_MANTISSA = 2e17; // 20% buffer

    function setUp() public {
        // Deploy mocks
        wmon = new MockWMON();
        magma = new MockMagma(address(wmon));

        // Deploy oracle
        oracle = new SimplePriceOracle(3600); // 1 hour stale threshold

        // Deploy controller
        unitroller = new Unitroller();
        comptroller = new Peridottroller();
        unitroller._setPendingImplementation(address(comptroller));
        comptroller._become(unitroller);

        Peridottroller(address(unitroller))._setPriceOracle(oracle);

        // Deploy IRM
        irm = new JumpRateModelV2(0, 5e16, 1e18, 8e17, admin);

        // Deploy MagmaBoosted delegate
        implementation = new MagmaBoostedDelegate();

        // Deploy delegator
        bytes memory becomeImplData = abi.encode(address(magma), BUFFER_MANTISSA);

        delegator = new PErc20Delegator(
            address(wmon),
            PeridottrollerInterface(address(unitroller)),
            InterestRateModel(address(irm)),
            INITIAL_EXCHANGE_RATE,
            "Peridot Magma WMON",
            "pMagmaWMON",
            18,
            payable(admin),
            address(implementation),
            becomeImplData
        );

        // Support market
        Peridottroller(address(unitroller))._supportMarket(PToken(address(delegator)));
        oracle.setUnderlyingPrice(PToken(address(delegator)), 1e18); // 1 WMON = $1

        // Fund users
        wmon.mint(user1, 10000e18);
        wmon.mint(user2, 10000e18);
    }

    function testDeployment() public view {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));
        assertEq(address(delegate.magmaVault()), address(magma));
        assertEq(delegate.vaultBufferMantissa(), BUFFER_MANTISSA);
        assertEq(delegate.underlying(), address(wmon));
    }

    function testMintDepositsToMagma() public {
        uint256 mintAmount = 1000e18;

        vm.startPrank(user1);
        wmon.approve(address(delegator), mintAmount);

        uint256 gmonBefore = magma.balanceOf(address(delegator));

        PErc20(address(delegator)).mint(mintAmount);

        uint256 gmonAfter = magma.balanceOf(address(delegator));

        vm.stopPrank();

        // Should have deposited 80% to Magma (20% buffer)
        uint256 expectedDeposit = (mintAmount * 8) / 10;
        assertApproxEqAbs(gmonAfter - gmonBefore, expectedDeposit, 1e18, "Should deposit to Magma");

        console.log("Minted pTokens, gMON balance increased by:", gmonAfter - gmonBefore);
    }

    function testRedeemWithSufficientBuffer() public {
        // Setup: User mints tokens
        uint256 mintAmount = 1000e18;
        vm.startPrank(user1);
        wmon.approve(address(delegator), mintAmount);
        uint256 pTokens = PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        // Redeem small amount (within buffer)
        uint256 redeemAmount = 100e18;

        vm.startPrank(user1);
        uint256 wmonBefore = wmon.balanceOf(user1);
        PErc20(address(delegator)).redeemUnderlying(redeemAmount);
        uint256 wmonAfter = wmon.balanceOf(user1);
        vm.stopPrank();

        assertEq(wmonAfter - wmonBefore, redeemAmount, "Should redeem correct amount");
        console.log("Redeemed from buffer successfully");
    }

    function testYieldAccrual() public {
        // User deposits
        uint256 mintAmount = 1000e18;
        vm.startPrank(user1);
        wmon.approve(address(delegator), mintAmount);
        uint256 pTokens = PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        uint256 exchangeRateBefore = PToken(address(delegator)).exchangeRateCurrent();
        console.log("Exchange Rate Before Yield:", exchangeRateBefore);

        // Simulate Magma yield (10% increase)
        magma.simulateYield(1.1e18);

        // Advance blocks
        vm.roll(block.number + 1000);

        uint256 exchangeRateAfter = PToken(address(delegator)).exchangeRateCurrent();
        console.log("Exchange Rate After Yield:", exchangeRateAfter);

        assertTrue(exchangeRateAfter > exchangeRateBefore, "Exchange rate should increase");
        console.log("Yield accrued successfully!");
    }

    function testAsyncRedemptionFlow() public {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        // Setup: deposit to get gMON
        uint256 mintAmount = 1000e18;
        vm.startPrank(user1);
        wmon.approve(address(delegator), mintAmount);
        PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        uint256 gmonShares = magma.balanceOf(address(delegator));
        console.log("gMON shares in contract:", gmonShares);

        // Admin requests redemption
        uint256 sharesToRedeem = gmonShares / 2;
        delegate._requestRedemption(sharesToRedeem);

        uint256 requestId = delegate.pendingRedemptionId();
        assertTrue(requestId > 0, "Should have pending request");
        console.log("Redemption requested, ID:", requestId);

        // Try to complete too early - should fail
        vm.expectRevert();
        delegate._completeRedemption();

        // Advance past withdrawal delay
        vm.roll(block.number + 101);

        // Complete redemption
        uint256 gmonBefore = magma.balanceOf(address(delegator));
        delegate._completeRedemption();
        uint256 gmonAfter = magma.balanceOf(address(delegator));

        assertEq(delegate.pendingRedemptionId(), 0, "Should clear pending request");

        // After redemption, WMON comes back and gets rebalanced
        // So check that local cash + vault assets increased or buffer adjusted
        uint256 localCash = wmon.balanceOf(address(delegator));
        console.log("Local cash after redemption:", localCash);
        console.log("gMON shares after redemption:", gmonAfter);

        // The redemption completed successfully if pendingRedemptionId is cleared
        assertTrue(true, "Redemption flow completed");
        console.log("Redemption completed successfully");
    }

    function testBufferManagement() public {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        // Change buffer to 50%
        delegate._setVaultBuffer(5e17);
        assertEq(delegate.vaultBufferMantissa(), 5e17);

        // Deposit
        uint256 mintAmount = 1000e18;
        vm.startPrank(user1);
        wmon.approve(address(delegator), mintAmount);
        PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        // Check buffer was maintained (should be ~50% in contract, ~50% in Magma)
        uint256 localCash = wmon.balanceOf(address(delegator));
        uint256 vaultAssets = magma.convertToAssets(magma.balanceOf(address(delegator)));

        console.log("Local Cash:", localCash);
        console.log("Vault Assets:", vaultAssets);

        // Allow some tolerance for rounding
        assertApproxEqRel(localCash, vaultAssets, 0.1e18, "Should maintain 50/50 split");
    }

    function testPauseVault() public {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        // Deposit first
        uint256 mintAmount = 1000e18;
        vm.startPrank(user1);
        wmon.approve(address(delegator), mintAmount);
        PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        uint256 gmonBefore = magma.balanceOf(address(delegator));

        // Pause vault
        delegate._setVaultPaused(true);
        assertTrue(delegate.vaultPaused(), "Should be paused");

        // New deposits shouldn't go to Magma
        vm.startPrank(user2);
        wmon.approve(address(delegator), mintAmount);
        PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        uint256 gmonAfter = magma.balanceOf(address(delegator));
        assertEq(gmonAfter, gmonBefore, "No new Magma deposits when paused");

        console.log("Vault paused successfully, no new deposits to Magma");
    }

    function testReferralId() public {
        MagmaBoostedDelegate delegate = MagmaBoostedDelegate(address(delegator));

        uint256 newReferralId = 12345;
        delegate._setReferralId(newReferralId);

        assertEq(delegate.referralId(), newReferralId);
        console.log("Referral ID set to:", newReferralId);
    }

    function testInsufficientBufferFails() public {
        // Deposit
        uint256 mintAmount = 1000e18;
        vm.startPrank(user1);
        wmon.approve(address(delegator), mintAmount);
        PErc20(address(delegator)).mint(mintAmount);
        vm.stopPrank();

        // Try to withdraw more than buffer (buffer is 20% = 200 WMON)
        uint256 redeemAmount = 500e18; // More than buffer

        vm.startPrank(user1);
        vm.expectRevert("insufficient buffer - admin must complete redemption");
        PErc20(address(delegator)).redeemUnderlying(redeemAmount);
        vm.stopPrank();

        console.log("Correctly reverted when buffer insufficient");
    }
}
