// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC3156FlashBorrower, IERC3156FlashLender} from "../PTokenInterfaces.sol";

contract SimpleFlashLoanVaultUpgradeable is Initializable, IERC3156FlashLender, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    uint256 public feeBps = 5;
    bool public paused;

    mapping(address => bool) public tokenAllowed;

    event TokenAllowed(address indexed token, bool allowed);
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event PausedUpdated(bool paused);
    event FlashLoanExecuted(
        address indexed receiver,
        address indexed token,
        uint256 amount,
        uint256 fee
    );
    event LiquidityDeposited(address indexed token, address indexed from, uint256 amount);
    event LiquidityWithdrawn(address indexed token, address indexed to, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        require(owner_ != address(0), "Vault: zero owner");
        __Ownable_init(owner_);
    }

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        require(token != address(0), "Vault: zero token");
        tokenAllowed[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 100, "Vault: fee too high");
        uint256 oldFeeBps = feeBps;
        feeBps = newFeeBps;
        emit FeeUpdated(oldFeeBps, newFeeBps);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedUpdated(paused_);
    }

    function depositLiquidity(address token, uint256 amount) external {
        require(tokenAllowed[token], "Vault: token not allowed");
        require(amount > 0, "Vault: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityDeposited(token, msg.sender, amount);
    }

    function withdrawLiquidity(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Vault: zero recipient");
        require(amount > 0, "Vault: zero amount");
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(token, to, amount);
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        if (!tokenAllowed[token] || paused) {
            return 0;
        }
        return IERC20(token).balanceOf(address(this));
    }

    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        require(tokenAllowed[token], "Vault: token not allowed");
        return (amount * feeBps) / 10000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(!paused, "Vault: paused");
        require(tokenAllowed[token], "Vault: token not allowed");
        require(amount > 0, "Vault: zero amount");

        IERC20 tokenContract = IERC20(token);
        require(
            tokenContract.balanceOf(address(this)) >= amount,
            "Vault: insufficient liquidity"
        );

        tokenContract.safeTransfer(address(receiver), amount);

        uint256 fee = flashFee(token, amount);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, fee, data) ==
                CALLBACK_SUCCESS,
            "Vault: callback failed"
        );

        tokenContract.safeTransferFrom(
            address(receiver),
            address(this),
            amount + fee
        );

        emit FlashLoanExecuted(address(receiver), token, amount, fee);
        return true;
    }
}
