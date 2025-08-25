// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAxelarGasService {
    function payNativeGasForContractCallWithToken(
        address, // source
        string calldata, // destinationChain
        string calldata, // destinationContract (address in string form)
        bytes calldata, // payload
        string calldata, // symbol
        uint256, // amount
        address // refundAddress
    ) external payable;

    function payNativeGasForContractCall(
        address sourceAddress,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable;
}

interface IAxelarGateway {
    function gasService() external view returns (address);

    function callContractWithToken(
        string calldata destinationChain,
        string calldata contractAddress,
        bytes calldata payload,
        string calldata symbol,
        uint256 amount
    ) external payable;

    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        external
        payable;

    function tokenAddresses(string memory symbol) external view returns (address);
}

abstract contract IAxelarExecutable {
    address public immutable gateway;

    constructor(address _gateway) {
        gateway = _gateway;
    }

    function _execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal virtual;
    function _executeWithToken(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal virtual returns (bytes memory);

    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external payable {
        require(msg.sender == gateway, "Not gateway");
        _execute(commandId, sourceChain, sourceAddress, payload);
    }

    function executeWithToken(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) external payable returns (bytes memory) {
        require(msg.sender == gateway, "Not gateway");
        return _executeWithToken(commandId, sourceChain, sourceAddress, payload, tokenSymbol, amount);
    }
}

abstract contract AxelarExecutableWithToken {
    IAxelarGateway public immutable gateway;

    constructor(address _gateway) {
        gateway = IAxelarGateway(_gateway);
    }

    function gatewayWithToken() internal view returns (IAxelarGateway) {
        return gateway;
    }

    function _execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal virtual;
    function _executeWithToken(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal virtual;

    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external payable {
        require(msg.sender == address(gateway), "Not gateway");
        _execute(commandId, sourceChain, sourceAddress, payload);
    }

    function executeWithToken(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) external payable {
        require(msg.sender == address(gateway), "Not gateway");
        _executeWithToken(commandId, sourceChain, sourceAddress, payload, tokenSymbol, amount);
    }
}
