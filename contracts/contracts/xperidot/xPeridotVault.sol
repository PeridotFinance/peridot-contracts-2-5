// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // moved to xperidot folder

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title xPeridotVault
 * @author Peridot
 * @notice ERC20 share token vault for PERIDOT tokens with revenue sharing
 * @dev Users deposit PERIDOT tokens and receive xPERIDOT shares that appreciate via revenue addition
 */
contract xPeridotVault is ERC20, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    
    /// @notice The underlying PERIDOT token
    IERC20 public immutable peridotToken;
    
    /// @notice Total PERIDOT tokens held in the vault
    uint256 public totalPInVault;

    // --- Events ---
    
    event Deposit(address indexed user, uint256 peridotAmount, uint256 sharesAmount);
    event Withdraw(address indexed user, uint256 sharesAmount, uint256 peridotAmount);
    event RevenueAdded(address indexed admin, uint256 amount);

    // --- Constructor ---
    
    constructor(
        address _peridotToken,
        string memory _name,
        string memory _symbol,
        address _owner
    ) ERC20(_name, _symbol) Ownable(_owner) {
        require(_peridotToken != address(0), "Invalid PERIDOT token");
        peridotToken = IERC20(_peridotToken);
    }

    // --- Admin Functions ---
    
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Core Vault Functions ---
    
    /**
     * @notice Deposit PERIDOT tokens and receive xPERIDOT shares
     * @param amount Amount of PERIDOT tokens to deposit
     * @return shares Amount of xPERIDOT shares minted
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(amount > 0, "Amount must be greater than 0");
        
        // Calculate shares to mint
        shares = previewDeposit(amount);
        
        // Transfer PERIDOT from user
        peridotToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update vault balance
        totalPInVault += amount;
        
        // Mint shares to user
        _mint(msg.sender, shares);
        
        emit Deposit(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw PERIDOT tokens by burning xPERIDOT shares
     * @param shares Amount of xPERIDOT shares to burn
     * @return amount Amount of PERIDOT tokens received
     */
    function withdraw(uint256 shares) external nonReentrant whenNotPaused returns (uint256 amount) {
        require(shares > 0, "Shares must be greater than 0");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");
        
        // Calculate PERIDOT amount to withdraw
        amount = previewWithdraw(shares);
        require(amount > 0, "Amount must be greater than 0");
        require(totalPInVault >= amount, "Insufficient vault balance");
        
        // Burn shares from user
        _burn(msg.sender, shares);
        
        // Update vault balance
        totalPInVault -= amount;
        
        // Transfer PERIDOT to user
        peridotToken.safeTransfer(msg.sender, amount);
        
        emit Withdraw(msg.sender, shares, amount);
    }

    /**
     * @notice Admin function to add revenue to the vault
     * @dev Increases totalPInVault without minting shares, improving exchange rate
     * @param amount Amount of PERIDOT tokens to add as revenue
     */
    function addRevenue(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer PERIDOT from admin
        peridotToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Increase vault balance (improves exchange rate)
        totalPInVault += amount;
        
        emit RevenueAdded(msg.sender, amount);
    }

    // --- View Functions ---
    
    /**
     * @notice Get the current exchange rate of PERIDOT per xPERIDOT
     * @return Exchange rate scaled by 1e18
     */
    function exchangeRate() public view returns (uint256) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) {
            return 1e18; // 1:1 when no shares exist
        }
        return (totalPInVault * 1e18) / totalShares;
    }

    /**
     * @notice Preview how many xPERIDOT shares would be minted for a PERIDOT deposit
     * @param peridotAmount Amount of PERIDOT tokens to deposit
     * @return shares Amount of xPERIDOT shares that would be minted
     */
    function previewDeposit(uint256 peridotAmount) public view returns (uint256 shares) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0 || totalPInVault == 0) {
            // First deposit: 1:1 ratio
            return peridotAmount;
        }
        // shares = amount * totalShares / totalPInVault
        return (peridotAmount * totalShares) / totalPInVault;
    }

    /**
     * @notice Preview how many PERIDOT tokens would be received for burning xPERIDOT shares
     * @param shares Amount of xPERIDOT shares to burn
     * @return peridotAmount Amount of PERIDOT tokens that would be received
     */
    function previewWithdraw(uint256 shares) public view returns (uint256 peridotAmount) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) {
            return 0;
        }
        // amount = shares * totalPInVault / totalShares
        return (shares * totalPInVault) / totalShares;
    }

    /**
     * @notice Get vault statistics
     * @return totalShares Total xPERIDOT shares in circulation
     * @return totalPeridot Total PERIDOT tokens in vault
     * @return currentExchangeRate Current PERIDOT per xPERIDOT exchange rate
     */
    function getVaultStats() external view returns (
        uint256 totalShares,
        uint256 totalPeridot,
        uint256 currentExchangeRate
    ) {
        totalShares = totalSupply();
        totalPeridot = totalPInVault;
        currentExchangeRate = exchangeRate();
    }
}
