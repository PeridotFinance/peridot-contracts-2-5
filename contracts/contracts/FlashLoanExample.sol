// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PTokenInterfaces.sol";
import "./EIP20Interface.sol";

/**
 * @title Flash Loan Example Contract
 * @notice Example contract demonstrating how to use Peridot flash loans
 * @dev This contract implements the IERC3156FlashBorrower interface
 */
contract FlashLoanExample is IERC3156FlashBorrower {
    // Events
    event FlashLoanExecuted(address indexed token, uint256 amount, uint256 fee, bytes32 action);

    // Errors
    error UnauthorizedFlashLoan();
    error InvalidFlashLoanData();
    error FlashLoanFailed();

    // Constants
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // State variables
    address public owner;
    mapping(address => bool) public authorizedLenders;

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAuthorizedLender() {
        require(authorizedLenders[msg.sender], "Unauthorized lender");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Authorize a PToken contract to initiate flash loans to this contract
     * @param lender The PToken contract address to authorize
     */
    function authorizeLender(address lender) external onlyOwner {
        authorizedLenders[lender] = true;
    }

    /**
     * @notice Revoke authorization for a PToken contract
     * @param lender The PToken contract address to revoke
     */
    function revokeLender(address lender) external onlyOwner {
        authorizedLenders[lender] = false;
    }

    /**
     * @notice Execute a flash loan
     * @param pToken The PToken contract to borrow from
     * @param token The underlying token to borrow
     * @param amount The amount to borrow
     * @param action The action to execute (encoded as bytes32)
     * @param extraData Additional data for the action
     */
    function executeFlashLoan(address pToken, address token, uint256 amount, bytes32 action, bytes calldata extraData)
        external
        onlyOwner
    {
        // Prepare data for the flash loan callback
        bytes memory data = abi.encode(action, extraData, msg.sender);

        // Execute flash loan
        bool success = IERC3156FlashLender(pToken).flashLoan(IERC3156FlashBorrower(this), token, amount, data);

        if (!success) {
            revert FlashLoanFailed();
        }
    }

    /**
     * @notice ERC-3156 Flash loan callback
     * @param initiator The address that initiated the flash loan
     * @param token The token being borrowed
     * @param amount The amount being borrowed
     * @param fee The fee to be paid
     * @param data Additional data passed from the flash loan
     * @return The keccak256 hash of "ERC3156FlashBorrower.onFlashLoan"
     */
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        onlyAuthorizedLender
        returns (bytes32)
    {
        // Decode the data
        (bytes32 action, bytes memory extraData, address originalCaller) = abi.decode(data, (bytes32, bytes, address));

        // Verify the initiator is this contract (security check)
        if (initiator != address(this)) {
            revert UnauthorizedFlashLoan();
        }

        // Execute the specified action
        _executeAction(action, token, amount, fee, extraData, originalCaller);

        // Approve the lender to take back the loan + fee
        EIP20Interface(token).approve(msg.sender, amount + fee);

        // Emit event
        emit FlashLoanExecuted(token, amount, fee, action);

        return CALLBACK_SUCCESS;
    }

    /**
     * @notice Execute the specified action with the borrowed funds
     * @param action The action identifier
     * @param token The borrowed token
     * @param amount The borrowed amount
     * @param fee The loan fee
     * @param extraData Additional action-specific data
     * @param originalCaller The address that initiated the flash loan
     */
    function _executeAction(
        bytes32 action,
        address token,
        uint256 amount,
        uint256 fee,
        bytes memory extraData,
        address originalCaller
    ) internal {
        if (action == keccak256("ARBITRAGE")) {
            _executeArbitrage(token, amount, fee, extraData);
        } else if (action == keccak256("LIQUIDATION")) {
            _executeLiquidation(token, amount, fee, extraData);
        } else if (action == keccak256("COLLATERAL_SWAP")) {
            _executeCollateralSwap(token, amount, fee, extraData);
        } else if (action == keccak256("SIMPLE_TRANSFER")) {
            _executeSimpleTransfer(token, amount, fee, extraData, originalCaller);
        } else {
            revert InvalidFlashLoanData();
        }
    }

    /**
     * @notice Example arbitrage action
     */
    function _executeArbitrage(address token, uint256 amount, uint256 fee, bytes memory extraData) internal {
        // Decode arbitrage parameters
        (address targetExchange, uint256 minProfit) = abi.decode(extraData, (address, uint256));

        // Example: Simple arbitrage logic
        // 1. Trade on target exchange
        // 2. Ensure profit covers fee + minimum profit
        // Note: This is a simplified example - real arbitrage would involve
        // actual DEX interactions, price checks, etc.

        require(minProfit > fee, "Arbitrage not profitable");
        // Add actual arbitrage logic here
    }

    /**
     * @notice Example liquidation action
     */
    function _executeLiquidation(address token, uint256 amount, uint256 fee, bytes memory extraData) internal {
        // Decode liquidation parameters
        (address borrower, address collateralToken, uint256 repayAmount) =
            abi.decode(extraData, (address, address, uint256));

        // Example liquidation logic:
        // 1. Use flash loan to repay borrower's debt
        // 2. Seize collateral
        // 3. Sell collateral to repay flash loan + fee + profit

        // Add actual liquidation logic here
    }

    /**
     * @notice Example collateral swap action
     */
    function _executeCollateralSwap(address token, uint256 amount, uint256 fee, bytes memory extraData) internal {
        // Decode swap parameters
        (address newCollateralToken, uint256 swapRatio) = abi.decode(extraData, (address, uint256));

        // Example collateral swap logic:
        // 1. Withdraw current collateral
        // 2. Swap to new collateral token
        // 3. Deposit new collateral
        // 4. Ensure health factor remains adequate

        // Add actual collateral swap logic here
    }

    /**
     * @notice Simple transfer example (for testing)
     */
    function _executeSimpleTransfer(
        address token,
        uint256 amount,
        uint256 fee,
        bytes memory extraData,
        address originalCaller
    ) internal {
        // Decode transfer parameters
        address recipient = abi.decode(extraData, (address));

        // Transfer some of the borrowed amount (keeping enough for fee)
        uint256 transferAmount = amount - fee - 1; // Keep 1 extra token for safety
        EIP20Interface(token).transfer(recipient, transferAmount);

        // The remaining tokens will be used to repay the loan
    }

    /**
     * @notice Emergency function to withdraw tokens (only owner)
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        EIP20Interface(token).transfer(owner, amount);
    }

    /**
     * @notice Emergency function to withdraw ETH (only owner)
     */
    function emergencyWithdrawETH() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}
}
