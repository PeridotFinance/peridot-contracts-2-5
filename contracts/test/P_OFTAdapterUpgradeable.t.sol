// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import {Vm} from "forge-std/Vm.sol";

import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {ERC20Mock} from "@layerzerolabs/oft-evm-upgradeable/test/mocks/ERC20Mock.sol";

import {P_OFTAdapterUpgradeable} from "../contracts/layerzero/P_OFTAdapterUpgradeable.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract P_OFTAdapterUpgradeableTest is TestHelperOz5 {
    using OptionsBuilder for bytes;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    uint32 internal constant A_EID = 1;
    uint32 internal constant B_EID = 2;

    address internal proxyAdmin = makeAddr("proxyAdmin");

    address internal userA = address(0xA11);
    address internal userB = address(0xB11);

    uint256 internal constant INITIAL_BALANCE = 100 ether;

    ERC20Mock internal tokenA;
    ERC20Mock internal tokenB;

    P_OFTAdapterUpgradeable internal adapterA;
    P_OFTAdapterUpgradeable internal adapterB;

    function setUp() public override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        tokenA = new ERC20Mock("P", "P");
        tokenB = new ERC20Mock("P", "P");

        adapterA = P_OFTAdapterUpgradeable(
            _deployContractAndProxy(
                type(P_OFTAdapterUpgradeable).creationCode,
                abi.encode(address(tokenA), address(endpoints[A_EID])),
                abi.encodeWithSelector(
                    P_OFTAdapterUpgradeable.initialize.selector,
                    address(this)
                )
            )
        );

        adapterB = P_OFTAdapterUpgradeable(
            _deployContractAndProxy(
                type(P_OFTAdapterUpgradeable).creationCode,
                abi.encode(address(tokenB), address(endpoints[B_EID])),
                abi.encodeWithSelector(
                    P_OFTAdapterUpgradeable.initialize.selector,
                    address(this)
                )
            )
        );

        adapterA.setPeer(B_EID, addressToBytes32(address(adapterB)));
        adapterB.setPeer(A_EID, addressToBytes32(address(adapterA)));

        // fund userA on chain A; seed inventory on chain B adapter (lock/unlock requires destination escrow)
        tokenA.mint(userA, INITIAL_BALANCE);
        tokenB.mint(address(adapterB), INITIAL_BALANCE);
    }

    function test_send_locks_and_unlocks() public {
        uint256 tokensToSend = 1 ether;

        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            B_EID,
            addressToBytes32(userB),
            tokensToSend,
            tokensToSend,
            options,
            "",
            ""
        );

        MessagingFee memory fee = adapterA.quoteSend(sendParam, false);

        assertEq(tokenA.balanceOf(userA), INITIAL_BALANCE);
        assertEq(tokenA.balanceOf(address(adapterA)), 0);
        assertEq(tokenB.balanceOf(userB), 0);
        assertEq(tokenB.balanceOf(address(adapterB)), INITIAL_BALANCE);

        vm.startPrank(userA);
        tokenA.approve(address(adapterA), tokensToSend);
        adapterA.send{value: fee.nativeFee}(sendParam, fee, payable(userA));
        vm.stopPrank();

        // deliver to adapterB
        verifyPackets(B_EID, addressToBytes32(address(adapterB)));

        // source: locked
        assertEq(tokenA.balanceOf(userA), INITIAL_BALANCE - tokensToSend);
        assertEq(tokenA.balanceOf(address(adapterA)), tokensToSend);

        // dest: unlocked from escrow
        assertEq(tokenB.balanceOf(userB), tokensToSend);
        assertEq(
            tokenB.balanceOf(address(adapterB)),
            INITIAL_BALANCE - tokensToSend
        );
    }

    function test_inbound_rate_limit_blocks_credit_on_destination() public {
        uint256 tokensToSend = 1 ether;

        // Limit inbound (credit) on destination adapter for messages coming from A_EID
        adapterB.setRateLimit(A_EID, false, 0.5 ether, 0);

        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            B_EID,
            addressToBytes32(userB),
            tokensToSend,
            tokensToSend,
            options,
            "",
            ""
        );

        MessagingFee memory fee = adapterA.quoteSend(sendParam, false);

        vm.startPrank(userA);
        tokenA.approve(address(adapterA), tokensToSend);
        adapterA.send{value: fee.nativeFee}(sendParam, fee, payable(userA));
        vm.stopPrank();

        _processOnePacketExpectRevert(
            B_EID,
            addressToBytes32(address(adapterB)),
            P_OFTAdapterUpgradeable.RateLimitExceeded.selector
        );
    }

    function test_insufficient_inventory_reverts_on_credit() public {
        // Deploy fresh destination adapter without seeding inventory
        ERC20Mock tokenB2 = new ERC20Mock("P", "P");
        P_OFTAdapterUpgradeable adapterB2 = P_OFTAdapterUpgradeable(
            _deployContractAndProxy(
                type(P_OFTAdapterUpgradeable).creationCode,
                abi.encode(address(tokenB2), address(endpoints[B_EID])),
                abi.encodeWithSelector(
                    P_OFTAdapterUpgradeable.initialize.selector,
                    address(this)
                )
            )
        );

        adapterA.setPeer(B_EID, addressToBytes32(address(adapterB2)));
        adapterB2.setPeer(A_EID, addressToBytes32(address(adapterA)));

        uint256 tokensToSend = 1 ether;
        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            B_EID,
            addressToBytes32(userB),
            tokensToSend,
            tokensToSend,
            options,
            "",
            ""
        );
        MessagingFee memory fee = adapterA.quoteSend(sendParam, false);

        vm.startPrank(userA);
        tokenA.approve(address(adapterA), tokensToSend);
        adapterA.send{value: fee.nativeFee}(sendParam, fee, payable(userA));
        vm.stopPrank();

        // Credit should fail because adapterB2 has 0 inventory
        _processOnePacketExpectRevertData(
            B_EID,
            addressToBytes32(address(adapterB2)),
            abi.encodeWithSelector(
                P_OFTAdapterUpgradeable.InsufficientInventory.selector,
                uint256(0),
                tokensToSend
            )
        );
    }

    function test_emergency_withdraw_requires_pause() public {
        // fund adapterA escrow then try to withdraw while not paused
        tokenA.mint(address(adapterA), 2 ether);
        vm.expectRevert(
            P_OFTAdapterUpgradeable.EmergencyWithdrawRequiresPause.selector
        );
        adapterA.emergencyWithdraw(address(0xBEEF), 1 ether);

        adapterA.setPaused(true);
        adapterA.emergencyWithdraw(address(0xBEEF), 1 ether);
        assertEq(tokenA.balanceOf(address(0xBEEF)), 1 ether);
    }

    function test_only_owner_can_set_rate_limit() public {
        vm.prank(userA);
        vm.expectRevert();
        adapterA.setRateLimit(B_EID, true, 1 ether, 0);
    }

    function test_proxy_upgrade_via_peridot_proxy_admin() public {
        // OZ v5 TransparentUpgradeableProxy deploys its own ProxyAdmin. Record logs to capture it.
        vm.recordLogs();

        ERC20Mock token = new ERC20Mock("P", "P");
        P_OFTAdapterUpgradeable impl1 = new P_OFTAdapterUpgradeable(
            address(token),
            address(endpoints[A_EID])
        );
        P_OFTAdapterUpgradeableV2 impl2 = new P_OFTAdapterUpgradeableV2(
            address(token),
            address(endpoints[A_EID])
        );

        bytes memory initData = abi.encodeWithSelector(
            P_OFTAdapterUpgradeable.initialize.selector,
            address(this)
        );
        PeridotTransparentProxy proxy = new PeridotTransparentProxy(
            address(impl1),
            address(this),
            initData
        );

        address proxyAdminAddr = _findErc1967AdminChangedNewAdmin(
            vm.getRecordedLogs()
        );
        ProxyAdmin(proxyAdminAddr).upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(impl2),
            ""
        );
        assertEq(P_OFTAdapterUpgradeableV2(address(proxy)).version(), 2);
    }

    function _processOnePacketExpectRevert(
        uint32 _dstEid,
        bytes32 _dstAddress,
        bytes4 _selector
    ) internal {
        DoubleEndedQueue.Bytes32Deque storage queue = packetsQueue[_dstEid][
            _dstAddress
        ];
        bytes32 guid = queue.popBack();
        bytes memory packetBytes = packets[guid];
        bytes memory opts = optionsLookup[guid];

        // validate first (this is what verifyPackets does before lzReceive)
        this.validatePacket(packetBytes, bytes(""));

        // now execute destination lzReceive and assert the revert comes from adapter credit logic
        vm.expectRevert(_selector);
        this.lzReceive(packetBytes, opts);
    }

    function _processOnePacketExpectRevertData(
        uint32 _dstEid,
        bytes32 _dstAddress,
        bytes memory _revertData
    ) internal {
        DoubleEndedQueue.Bytes32Deque storage queue = packetsQueue[_dstEid][
            _dstAddress
        ];
        bytes32 guid = queue.popBack();
        bytes memory packetBytes = packets[guid];
        bytes memory opts = optionsLookup[guid];

        this.validatePacket(packetBytes, bytes(""));

        vm.expectRevert(_revertData);
        this.lzReceive(packetBytes, opts);
    }

    function _findErc1967AdminChangedNewAdmin(
        Vm.Log[] memory logs
    ) internal pure returns (address newAdmin) {
        // AdminChanged(address,address)
        bytes32 sig = keccak256("AdminChanged(address,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                (, newAdmin) = abi.decode(logs[i].data, (address, address));
                return newAdmin;
            }
        }
        revert("AdminChanged not found");
    }

    function test_paused_blocks_debit() public {
        adapterA.setPaused(true);

        uint256 tokensToSend = 1 ether;
        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            B_EID,
            addressToBytes32(userB),
            tokensToSend,
            tokensToSend,
            options,
            "",
            ""
        );
        MessagingFee memory fee = adapterA.quoteSend(sendParam, false);

        vm.startPrank(userA);
        tokenA.approve(address(adapterA), tokensToSend);
        vm.expectRevert(P_OFTAdapterUpgradeable.AdapterPaused.selector);
        adapterA.send{value: fee.nativeFee}(sendParam, fee, payable(userA));
        vm.stopPrank();
    }

    function test_outbound_rate_limit_blocks_debit() public {
        adapterA.setRateLimit(B_EID, true, 0.5 ether, 0);

        uint256 tokensToSend = 1 ether;
        bytes memory options = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            B_EID,
            addressToBytes32(userB),
            tokensToSend,
            tokensToSend,
            options,
            "",
            ""
        );
        MessagingFee memory fee = adapterA.quoteSend(sendParam, false);

        vm.startPrank(userA);
        tokenA.approve(address(adapterA), tokensToSend);
        vm.expectRevert(P_OFTAdapterUpgradeable.RateLimitExceeded.selector);
        adapterA.send{value: fee.nativeFee}(sendParam, fee, payable(userA));
        vm.stopPrank();
    }

    function _deployContractAndProxy(
        bytes memory _bytecode,
        bytes memory _constructorArgs,
        bytes memory _initializeArgs
    ) internal returns (address addr) {
        bytes memory creation = bytes.concat(
            abi.encodePacked(_bytecode),
            _constructorArgs
        );
        assembly {
            addr := create(0, add(creation, 0x20), mload(creation))
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        return
            address(
                new TransparentUpgradeableProxy(
                    addr,
                    proxyAdmin,
                    _initializeArgs
                )
            );
    }
}

contract P_OFTAdapterUpgradeableV2 is P_OFTAdapterUpgradeable {
    constructor(
        address _token,
        address _lzEndpoint
    ) P_OFTAdapterUpgradeable(_token, _lzEndpoint) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}
