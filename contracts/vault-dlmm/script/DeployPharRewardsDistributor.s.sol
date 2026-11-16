// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PharRewardsDistributor} from "../src/rewards/PharRewardsDistributor.sol";

interface ISafeLikeRewards {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

interface IVaultLikeRewards {
    function owner() external view returns (address);
    function rewardToken() external view returns (address);
    function decimals() external view returns (uint8);
}

interface IErc20DecRewards {
    function decimals() external view returns (uint8);
}

/// @notice Mainnet (Avalanche C-chain 43114) deployment of the PHAR rewards distributor (design A) for the Pharaoh DLMM USDC/USDt vault.
///         Design and operator procedure: docs/deployment-handoffs/avalanche-dlmm-vault-rewards-distribution.md. NOT RUN by the agent that wrote it.
///
///  One transaction from a throwaway deployer: `new PharRewardsDistributor(PHAR, SAFE, CLAIM_DELAY, CLAIM_DEADLINE)`. The Safe is the owner from the first
///  block (constructor argument; there is no hand-over step and the deployer is never an owner of anything). Nothing is approved, published or funded here:
///  those are Safe transactions (tools/dlmm-rewards-safe-call.sh).
///
///  PRE-FLIGHT (read-only, before the broadcast): chain 43114; the Safe is the Peridot 1-of-1 owned by the Ledger; the vault proxy is owned by the Safe and its
///  `rewardToken()` EQUALS the PHAR constant below (so the token address is not trusted from a document); PHAR has 18 decimals; the deployer is not the Safe or the
///  Ledger and is fresh (nonce 0). POST-CHECKS on what the script produced; the on-chain read-back is ReadBackPharRewardsDistributor below.
/// Environment (public values only): DEPLOYER (must equal the broadcaster) [, CLAIM_DELAY seconds (default 86400), CLAIM_DEADLINE seconds (default 15552000 = 180 days)].
contract DeployPharRewardsDistributor is Script {
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant VAULT = 0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D;
    address internal constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;

    function run() external returns (address distributor) {
        address deployer = vm.envAddress("DEPLOYER");
        uint256 delay = vm.envOr("CLAIM_DELAY", uint256(1 days));
        uint256 deadline = vm.envOr("CLAIM_DEADLINE", uint256(180 days));
        _preflight(deployer, delay, deadline);

        vm.startBroadcast();
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast && sender == deployer, "broadcaster is not DEPLOYER");
        PharRewardsDistributor d = new PharRewardsDistributor(IERC20(PHAR), SAFE, delay, deadline);
        vm.stopBroadcast();

        distributor = address(d);
        _postchecks(d, deployer, delay, deadline);
        console2.log("== DEPLOYED (public address; the wrapper writes it to the addresses file)");
        console2.log("PHAR_DISTRIBUTOR=%s", distributor);
        console2.log("PHAR_DISTRIBUTOR_CODEHASH=%s", vm.toString(distributor.codehash));
    }

    function _preflight(address deployer, uint256 delay, uint256 deadline) internal view {
        require(block.chainid == 43114, "preflight: not Avalanche C-chain (43114)");
        require(deployer != address(0) && deployer != SAFE && deployer != LEDGER, "preflight: DEPLOYER is the Safe, the Ledger or zero");
        require(deployer.code.length == 0, "preflight: DEPLOYER has code");
        require(vm.getNonce(deployer) == 0, "preflight: DEPLOYER nonce != 0 (use a fresh key)");

        ISafeLikeRewards safe = ISafeLikeRewards(SAFE);
        address[] memory owners = safe.getOwners();
        require(owners.length == 1 && owners[0] == LEDGER, "preflight: the Safe's owner is not exactly the Ledger");
        require(safe.getThreshold() == 1, "preflight: Safe threshold != 1");

        require(VAULT.code.length != 0, "preflight: the vault has no code");
        require(IVaultLikeRewards(VAULT).owner() == SAFE, "preflight: the vault's owner is not the Safe");
        require(IVaultLikeRewards(VAULT).rewardToken() == PHAR, "preflight: vault.rewardToken() != the PHAR constant");
        require(PHAR.code.length != 0 && IErc20DecRewards(PHAR).decimals() == 18, "preflight: PHAR has no code or decimals != 18");
        require(IVaultLikeRewards(VAULT).decimals() == 6, "preflight: the vault shares do not have 6 decimals");

        require(delay >= 1 hours && delay <= 14 days, "preflight: CLAIM_DELAY outside 1 hour .. 14 days");
        require(deadline >= delay + 7 days && deadline <= 3 * 365 days, "preflight: CLAIM_DEADLINE must be >= CLAIM_DELAY + 7 days and <= 3 years");
    }

    function _postchecks(PharRewardsDistributor d, address deployer, uint256 delay, uint256 deadline) internal view {
        require(address(d).code.length != 0, "post: no code");
        require(d.owner() == SAFE && d.owner() != deployer, "post: owner is not the Safe");
        require(d.pendingOwner() == address(0), "post: pending owner");
        require(address(d.PHAR()) == PHAR, "post: PHAR");
        require(d.CLAIM_DELAY() == delay && d.CLAIM_DEADLINE() == deadline, "post: windows");
        require(d.epochCount() == 0, "post: epochCount");
        require(vm.getNonce(deployer) == 1, "post: deployer nonce != 1");
    }
}

/// @notice Read-only read-back of a deployed distributor (no broadcast): VERIFY with DISTRIBUTOR=<address> [, EXPECT_DELAY, EXPECT_DEADLINE].
contract ReadBackPharRewardsDistributor is Script {
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant VAULT = 0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D;
    address internal constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;

    function run() external view {
        PharRewardsDistributor d = PharRewardsDistributor(vm.envAddress("DISTRIBUTOR"));
        require(block.chainid == 43114, "not Avalanche C-chain (43114)");
        console2.log("distributor              %s", address(d));
        console2.log("codehash                 %s", vm.toString(address(d).codehash));
        console2.log("owner                    %s", d.owner());
        console2.log("pendingOwner             %s", d.pendingOwner());
        console2.log("PHAR                     %s", address(d.PHAR()));
        console2.log("CLAIM_DELAY              %s", d.CLAIM_DELAY());
        console2.log("CLAIM_DEADLINE           %s", d.CLAIM_DEADLINE());
        console2.log("MIN_CLAIM_WINDOW         %s", d.MIN_CLAIM_WINDOW());
        console2.log("epochCount (next id)     %s", d.epochCount());
        console2.log("PHAR balance             %s", IERC20(PHAR).balanceOf(address(d)));
        console2.log("vault.rewardToken()      %s", IVaultLikeRewards(VAULT).rewardToken());
        console2.log("vault.owner()            %s", IVaultLikeRewards(VAULT).owner());
        require(address(d.PHAR()) == PHAR && IVaultLikeRewards(VAULT).rewardToken() == PHAR, "PHAR mismatch");
        if (vm.envOr("EXPECT_DELAY", uint256(0)) != 0) require(d.CLAIM_DELAY() == vm.envUint("EXPECT_DELAY"), "CLAIM_DELAY differs from EXPECT_DELAY");
        if (vm.envOr("EXPECT_DEADLINE", uint256(0)) != 0) require(d.CLAIM_DEADLINE() == vm.envUint("EXPECT_DEADLINE"), "CLAIM_DEADLINE differs from EXPECT_DEADLINE");
        if (vm.envOr("EXPECT_OWNER_SAFE", false)) require(d.owner() == SAFE, "owner is not the Safe");
    }
}
