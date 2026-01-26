// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../PErc20.sol";
import "../PTokenInterfaces.sol";
import "./PancakeSwapAdapter.sol";

/**
 * @title VaultExecutor
 * @notice Manages cToken operations for dual investment positions
 * @dev Redeems user cTokens, supplies underlying to the vault, manages settlement withdrawals
 */
contract VaultExecutor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    // Authorized managers who can execute vault operations
    mapping(address => bool) public authorizedManagers;

    // Track underlying balances by user and cToken
    mapping(address => mapping(address => uint256)) public userUnderlyingBalances;

    // Track protocol-supplied amounts by cToken
    mapping(address => uint256) public protocolSuppliedAmounts;

    // Swap adapter for DEX interactions (V2/V3)
    address public swapAdapter;

    uint256 public actionDelay;
    mapping(bytes32 => uint256) public queuedActions;

    // Events
    event UserCTokensRedeemed(
        address indexed user, address indexed cToken, uint256 cTokenAmount, uint256 underlyingAmount
    );

    event UnderlyingSuppliedToProtocol(address indexed cToken, uint256 underlyingAmount, uint256 cTokensMinted);

    event UnderlyingWithdrawnFromProtocol(address indexed cToken, uint256 cTokensRedeemed, uint256 underlyingAmount);

    event SwapAdapterUpdated(address oldAdapter, address newAdapter);
    event AuthorizedManagerUpdated(address indexed manager, bool authorized);
    event ActionDelayUpdated(uint256 newDelay);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);

    modifier onlyAuthorized() {
        require(authorizedManagers[msg.sender], "Not authorized");
        _;
    }

    constructor() Ownable(msg.sender) {
        actionDelay = MIN_ACTION_DELAY;
        emit ActionDelayUpdated(actionDelay);
    }

    /**
     * @notice Redeem user's cTokens and supply underlying back into the market
     * @param user User whose cTokens to redeem
     * @param cToken cToken contract to redeem from
     * @param cTokenAmount Amount of cTokens to redeem
     * @return underlyingAmount Amount of underlying received
     */
    function redeemAndSupplyToProtocol(address user, address cToken, uint256 cTokenAmount)
        external
        onlyAuthorized
        nonReentrant
        returns (uint256 underlyingAmount)
    {
        require(user != address(0), "Invalid user address");
        require(cToken != address(0), "Invalid cToken address");
        require(cTokenAmount > 0, "Amount must be greater than zero");

        PErc20 pToken = PErc20(cToken);

        // Transfer cTokens from user to this contract
        require(pToken.transferFrom(user, address(this), cTokenAmount), "cToken transfer failed");

        // Redeem cTokens for underlying (track delta)
        IERC20 underlying = IERC20(pToken.underlying());
        uint256 preUnderlying = underlying.balanceOf(address(this));
        uint256 redeemResult = pToken.redeem(cTokenAmount);
        require(redeemResult == 0, "Redeem failed");

        uint256 postUnderlying = underlying.balanceOf(address(this));
        underlyingAmount = postUnderlying - preUnderlying;

        // Track user's underlying balance
        userUnderlyingBalances[user][cToken] += underlyingAmount;

        emit UserCTokensRedeemed(user, cToken, cTokenAmount, underlyingAmount);

        // Approve and supply underlying to cToken market under protocol account
        underlying.forceApprove(cToken, underlyingAmount);

        // Supply to cToken market (this will mint cTokens to this contract)
        uint256 preCTokenBal = pToken.balanceOf(address(this));
        uint256 mintResult = pToken.mint(underlyingAmount);
        require(mintResult == 0, "Mint failed");

        // Track protocol-supplied amount using minted delta
        uint256 postCTokenBal = pToken.balanceOf(address(this));
        uint256 cTokensMinted = postCTokenBal - preCTokenBal;
        protocolSuppliedAmounts[cToken] += cTokensMinted;

        emit UnderlyingSuppliedToProtocol(cToken, underlyingAmount, cTokensMinted);

        return underlyingAmount;
    }

    /**
     * @notice Withdraw underlying from protocol account for settlement
     * @param cToken cToken contract to withdraw from
     * @param underlyingAmount Amount of underlying to withdraw
     * @return actualAmount Actual amount withdrawn
     */
    function withdrawUnderlyingFromProtocol(address cToken, uint256 underlyingAmount)
        external
        onlyAuthorized
        nonReentrant
        returns (uint256 actualAmount)
    {
        require(cToken != address(0), "Invalid cToken address");
        require(underlyingAmount > 0, "Amount must be greater than zero");

        PErc20 pToken = PErc20(cToken);

        // Calculate cTokens needed to redeem for the requested underlying amount
        uint256 exchangeRate = pToken.exchangeRateStored();
        uint256 cTokensToRedeem = (underlyingAmount * 1e18) / exchangeRate;

        // Ensure we don't try to redeem more than we have or track
        uint256 availableCTokens = pToken.balanceOf(address(this));
        uint256 trackedCTokens = protocolSuppliedAmounts[cToken];
        if (cTokensToRedeem > availableCTokens) {
            cTokensToRedeem = availableCTokens;
        }
        if (cTokensToRedeem > trackedCTokens) {
            cTokensToRedeem = trackedCTokens;
        }
        if (cTokensToRedeem == 0) {
            return 0;
        }

        // Redeem cTokens for underlying (track delta)
        IERC20 underlying = IERC20(pToken.underlying());
        uint256 preUnderlying = underlying.balanceOf(address(this));
        uint256 redeemResult = pToken.redeem(cTokensToRedeem);
        require(redeemResult == 0, "Redeem failed");

        uint256 postUnderlying = underlying.balanceOf(address(this));
        actualAmount = postUnderlying - preUnderlying;

        // Update protocol-supplied tracking
        protocolSuppliedAmounts[cToken] -= cTokensToRedeem;

        emit UnderlyingWithdrawnFromProtocol(cToken, cTokensToRedeem, actualAmount);

        return actualAmount;
    }

    /**
     * @notice Configure DEX router used for swaps
     */
    function setSwapAdapter(address newAdapter) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setSwapAdapter", newAdapter));
        _consumeAction(actionId);
        address old = swapAdapter;
        swapAdapter = newAdapter;
        emit SwapAdapterUpdated(old, newAdapter);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Swap underlying tokens held by the vault and return amount out
     */
    function swapUnderlying(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        onlyAuthorized
        nonReentrant
        returns (uint256 amountOut)
    {
        require(swapAdapter != address(0), "Adapter not set");
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid tokens");
        require(amountIn > 0, "Zero amount");

        // Try v3 single, fallback to v2
        try PancakeSwapAdapter(swapAdapter)
            .swapV3Single(tokenIn, tokenOut, amountIn, minOut, address(this), 0) returns (uint256 outV3) {
            amountOut = outV3;
        } catch {
            amountOut =
                PancakeSwapAdapter(swapAdapter).swapV2(tokenIn, tokenOut, amountIn, minOut, address(this), address(0));
        }
    }

    /**
     * @notice Swap underlying from cTokenIn's underlying to cTokenOut's underlying, then mint cTokenOut to recipient
     */
    function swapAndMintTo(
        address cTokenIn,
        address cTokenOut,
        address recipient,
        uint256 underlyingInAmount,
        uint256 minUnderlyingOut
    ) external onlyAuthorized nonReentrant returns (uint256 cTokensMinted) {
        require(swapAdapter != address(0), "Adapter not set");
        require(cTokenIn != address(0) && cTokenOut != address(0), "Invalid cTokens");
        require(recipient != address(0), "Invalid recipient");

        IERC20 underlyingIn = IERC20(PErc20(cTokenIn).underlying());
        IERC20 underlyingOut = IERC20(PErc20(cTokenOut).underlying());

        require(underlyingIn.balanceOf(address(this)) >= underlyingInAmount, "Insufficient underlyingIn");

        uint256 amountOut = _swapUnderlyingInternal(
            address(underlyingIn), address(underlyingOut), underlyingInAmount, minUnderlyingOut
        );

        // If the swap output is too small to mint at least 1 unit of cToken,
        // pay the user directly in underlying to avoid rounding to zero.
        uint256 minUnderlyingForOneCToken = PErc20(cTokenOut).exchangeRateStored() / 1e18;
        if (amountOut < minUnderlyingForOneCToken) {
            require(underlyingOut.balanceOf(address(this)) >= amountOut, "Insufficient underlyingOut");
            underlyingOut.safeTransfer(recipient, amountOut);
            return 0;
        }

        // Otherwise mint cTokens directly to recipient
        cTokensMinted = _mintCTokensToInternal(cTokenOut, recipient, amountOut);
    }

    /**
     * @notice Transfer underlying tokens to a recipient
     * @param cToken cToken contract (to identify underlying)
     * @param recipient Address to receive tokens
     * @param amount Amount to transfer
     */
    function transferUnderlying(address cToken, address recipient, uint256 amount)
        external
        onlyAuthorized
        nonReentrant
    {
        require(cToken != address(0), "Invalid cToken address");
        require(recipient != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than zero");

        PErc20 pToken = PErc20(cToken);
        IERC20 underlying = IERC20(pToken.underlying());

        require(underlying.balanceOf(address(this)) >= amount, "Insufficient underlying balance");

        underlying.safeTransfer(recipient, amount);
    }

    /**
     * @notice Mint cTokens directly to a recipient
     * @param cToken cToken contract
     * @param recipient Address to receive cTokens
     * @param underlyingAmount Amount of underlying to supply
     * @return cTokensMinted Amount of cTokens minted
     */
    function mintCTokensTo(address cToken, address recipient, uint256 underlyingAmount)
        external
        onlyAuthorized
        nonReentrant
        returns (uint256 cTokensMinted)
    {
        return _mintCTokensToInternal(cToken, recipient, underlyingAmount);
    }

    function _mintCTokensToInternal(address cToken, address recipient, uint256 underlyingAmount)
        internal
        returns (uint256 cTokensMinted)
    {
        require(cToken != address(0), "Invalid cToken address");
        require(recipient != address(0), "Invalid recipient address");
        require(underlyingAmount > 0, "Amount must be greater than zero");

        PErc20 pToken = PErc20(cToken);
        IERC20 underlying = IERC20(pToken.underlying());

        require(underlying.balanceOf(address(this)) >= underlyingAmount, "Insufficient underlying balance");

        // Approve and mint (track delta)
        uint256 preCTokenBal = pToken.balanceOf(address(this));
        underlying.forceApprove(cToken, underlyingAmount);
        uint256 mintResult = pToken.mint(underlyingAmount);
        require(mintResult == 0, "Mint failed");

        // Transfer only the newly minted cTokens to recipient
        uint256 postCTokenBal = pToken.balanceOf(address(this));
        cTokensMinted = postCTokenBal - preCTokenBal;
        require(pToken.transfer(recipient, cTokensMinted), "cToken transfer failed");

        if (recipient == address(this)) {
            protocolSuppliedAmounts[cToken] += cTokensMinted;
        }

        return cTokensMinted;
    }

    function _swapUnderlyingInternal(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        require(swapAdapter != address(0), "Adapter not set");
        require(tokenIn != address(0) && tokenOut != address(0), "Invalid tokens");
        require(amountIn > 0, "Zero amount");

        // Ensure the adapter holds the input tokens for router pull
        IERC20(tokenIn).safeTransfer(swapAdapter, amountIn);

        // Try v3 single, fallback to v2
        try PancakeSwapAdapter(swapAdapter)
            .swapV3Single(tokenIn, tokenOut, amountIn, minOut, address(this), 0) returns (uint256 outV3) {
            amountOut = outV3;
        } catch {
            amountOut =
                PancakeSwapAdapter(swapAdapter).swapV2(tokenIn, tokenOut, amountIn, minOut, address(this), address(0));
        }
    }

    /**
     * @notice Pull underlying from a user and mint cTokens to a recipient
     * @param cToken cToken contract
     * @param fromUser Address to pull underlying from (must approve this contract)
     * @param recipient Address to receive minted cTokens
     * @param underlyingAmount Amount of underlying to pull and supply
     * @return cTokensMinted Amount of cTokens minted
     */
    function pullUnderlyingAndMintTo(address cToken, address fromUser, address recipient, uint256 underlyingAmount)
        external
        onlyAuthorized
        nonReentrant
        returns (uint256 cTokensMinted)
    {
        require(cToken != address(0), "Invalid cToken address");
        require(fromUser != address(0), "Invalid user address");
        require(recipient != address(0), "Invalid recipient address");
        require(underlyingAmount > 0, "Amount must be greater than zero");

        PErc20 pToken = PErc20(cToken);
        IERC20 underlying = IERC20(pToken.underlying());

        // Pull underlying from user
        underlying.safeTransferFrom(fromUser, address(this), underlyingAmount);

        // Approve and mint (track delta)
        uint256 preCTokenBal = pToken.balanceOf(address(this));
        underlying.forceApprove(cToken, underlyingAmount);
        uint256 mintResult = pToken.mint(underlyingAmount);
        require(mintResult == 0, "Mint failed");

        uint256 postCTokenBal = pToken.balanceOf(address(this));
        cTokensMinted = postCTokenBal - preCTokenBal;

        // Transfer minted cTokens to recipient if needed
        if (recipient != address(this)) {
            require(pToken.transfer(recipient, cTokensMinted), "cToken transfer failed");
        }

        // Track protocol-supplied amount
        protocolSuppliedAmounts[cToken] += cTokensMinted;

        emit UnderlyingSuppliedToProtocol(cToken, underlyingAmount, cTokensMinted);
    }

    /**
     * @notice Get user's underlying balance for a specific cToken
     * @param user User address
     * @param cToken cToken address
     */
    function getUserUnderlyingBalance(address user, address cToken) external view returns (uint256) {
        return userUnderlyingBalances[user][cToken];
    }

    /**
     * @notice Get protocol's supplied amount for a cToken
     * @param cToken cToken address
     */
    function getProtocolSuppliedAmount(address cToken) external view returns (uint256) {
        return protocolSuppliedAmounts[cToken];
    }

    /**
     * @notice Set authorized manager status
     * @param manager Address to authorize/deauthorize
     * @param authorized Authorization status
     */
    function setAuthorizedManager(address manager, bool authorized) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setAuthorizedManager", manager, authorized));
        _consumeAction(actionId);
        authorizedManagers[manager] = authorized;
        emit AuthorizedManagerUpdated(manager, authorized);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Emergency function to withdraw any ERC20 token
     * @param token Token to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("emergencyWithdraw", token, to, amount));
        _consumeAction(actionId);
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
        emit ActionExecuted(actionId);
    }

    function setActionDelay(uint256 newDelay) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setActionDelay", newDelay));
        _consumeAction(actionId);
        require(newDelay >= actionDelay, "Delay cannot decrease");
        require(newDelay >= MIN_ACTION_DELAY, "Delay too short");
        actionDelay = newDelay;
        emit ActionDelayUpdated(newDelay);
        emit ActionExecuted(actionId);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        require(queuedActions[actionId] != 0, "Action not queued");
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function queueSetSwapAdapter(address newAdapter) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setSwapAdapter", newAdapter)));
    }

    function queueSetAuthorizedManager(address manager, bool authorized) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setAuthorizedManager", manager, authorized)));
    }

    function queueEmergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyOwner
        returns (bytes32 actionId)
    {
        actionId = _queueAction(keccak256(abi.encode("emergencyWithdraw", token, to, amount)));
    }

    function queueSetActionDelay(uint256 newDelay) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setActionDelay", newDelay)));
    }

    function _queueAction(bytes32 actionId) internal returns (bytes32) {
        require(queuedActions[actionId] == 0, "Action already queued");
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
        return actionId;
    }

    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = queuedActions[actionId];
        require(executeAfter != 0, "Action not queued");
        require(block.timestamp >= executeAfter, "Action not ready");
        delete queuedActions[actionId];
    }
}
