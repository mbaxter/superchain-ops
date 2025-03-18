// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {SignFromJson as OriginalSignFromJson} from "script/SignFromJson.s.sol";
import {Simulation} from "@base-contracts/script/universal/Simulation.sol";
import {console2 as console} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {GnosisSafe} from "safe-contracts/GnosisSafe.sol";
import {LibString} from "solady/utils/LibString.sol";
import "@eth-optimism-bedrock/src/dispute/lib/Types.sol";
import {AnchorStateRegistry} from "@eth-optimism-bedrock/src/dispute/AnchorStateRegistry.sol";
import {DisputeGameFactory} from "@eth-optimism-bedrock/src/dispute/DisputeGameFactory.sol";
import {FaultDisputeGame} from "@eth-optimism-bedrock/src/dispute/FaultDisputeGame.sol";
import {PermissionedDisputeGame} from "@eth-optimism-bedrock/src/dispute/PermissionedDisputeGame.sol";
import {SystemConfig} from "@eth-optimism-bedrock/src/L1/SystemConfig.sol";

contract SignFromJson is OriginalSignFromJson {
    using LibString for string;

    // Chains for this task.
    string l1ChainName = vm.envString("L1_CHAIN_NAME");
    string l2ChainName = vm.envString("L2_CHAIN_NAME");

    // Safe contract for this task.
    GnosisSafe ownerSafe = GnosisSafe(payable(vm.envAddress("OWNER_SAFE")));
    GnosisSafe councilSafe = GnosisSafe(payable(vm.envAddress("COUNCIL_SAFE")));
    GnosisSafe foundationSafe = GnosisSafe(payable(vm.envAddress("FOUNDATION_SAFE")));

    // The slot used to store the livenessGuard address in GnosisSafe.
    // See https://github.com/safe-global/safe-smart-account/blob/186a21a74b327f17fc41217a927dea7064f74604/contracts/base/GuardManager.sol#L30
    bytes32 livenessGuardSlot = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    SystemConfig systemConfig = SystemConfig(vm.envAddress("SYSTEM_CONFIG"));

    // DisputeGameFactoryProxy address.
    DisputeGameFactory dgfProxy;
    AnchorStateRegistry asr = AnchorStateRegistry(0x90eF2c5E9bf293AD04d53539ae5ed726af8e4D2d);
    // Store initial asr settings
    address initAsrSuperchainConfig;
    address initAsrPortal;
    // Store expected post state variables
    bytes32 expectedOutputRoot = 0x5ee91fddc0f8d728b93db3356fc915f4f138b7720da4ed5f08c3e01453add911;
    uint256 expectedL2Seq = 124082;

    address[] extraStorageAccessAddresses;

    function setUp() public {
        dgfProxy = DisputeGameFactory(systemConfig.disputeGameFactory());
        extraStorageAccessAddresses.push(address(asr));
        // INSERT NEW PRE CHECKS HERE
        precheckASR();
    }
    
    function precheckASR() internal {
        FaultDisputeGame currentGame = FaultDisputeGame(address(dgfProxy.gameImpls(GameType(GameTypes.PERMISSIONED_CANNON))));
        address currentAsr = address(currentGame.anchorStateRegistry());
        require(currentAsr == address(asr), "pre-asr-10");

        initAsrSuperchainConfig = address(asr.superchainConfig());
        initAsrPortal = address(asr.portal());

        require(address(asr.disputeGameFactory()) == address(dgfProxy), "pre-asr-20");
        
        // Check starting root is 0xdead
        (Hash root, uint256 l2seq) = asr.getAnchorRoot();
        require(root.raw() == 0xdead000000000000000000000000000000000000000000000000000000000000, "pre-asr-30");
        require(l2seq == 0x0, "pre-asr-40");
    }
    
    function postcheckASR() internal view {
        // Check contract references are unchanged
        require(address(asr.superchainConfig()) == initAsrSuperchainConfig, "post-asr-10");
        require(address(asr.portal()) == initAsrPortal, "post-asr-20");
        require(address(asr.disputeGameFactory()) == address(dgfProxy), "post-asr-30");
        
        // Check starting root is updated as expected
        (Hash root, uint256 l2seq) = asr.getAnchorRoot();
        require(root.raw() == expectedOutputRoot, "post-asr-40");
        require(l2seq == expectedL2Seq, "post-asr-50");
    }

    function getCodeExceptions() internal view override returns (address[] memory) {
        // Safe owners will appear in storage in the LivenessGuard when added, and they are allowed
        // to have code AND to have no code.
        address[] memory securityCouncilSafeOwners = councilSafe.getOwners();

        // To make sure we probably handle all signers whether or not they have code, first we count
        // the number of signers that have no code.
        uint256 numberOfSafeSignersWithNoCode;
        for (uint256 i = 0; i < securityCouncilSafeOwners.length; i++) {
            if (securityCouncilSafeOwners[i].code.length == 0) {
                numberOfSafeSignersWithNoCode++;
            }
        }

        // Then we extract those EOA addresses into a dedicated array.
        uint256 trackedSignersWithNoCode;
        address[] memory safeSignersWithNoCode = new address[](numberOfSafeSignersWithNoCode);
        for (uint256 i = 0; i < securityCouncilSafeOwners.length; i++) {
            if (securityCouncilSafeOwners[i].code.length == 0) {
                safeSignersWithNoCode[trackedSignersWithNoCode] = securityCouncilSafeOwners[i];
                trackedSignersWithNoCode++;
            }
        }

        // Here we add the standard (non Safe signer) exceptions.
        address[] memory shouldHaveCodeExceptions = new address[](numberOfSafeSignersWithNoCode);
        // And finally, we append the Safe signer exceptions.
        for (uint256 i = 0; i < safeSignersWithNoCode.length; i++) {
            shouldHaveCodeExceptions[i] = safeSignersWithNoCode[i];
        }

        return shouldHaveCodeExceptions;
    }

    function getAllowedStorageAccess() internal view override returns (address[] memory allowed) {
        allowed = new address[](5 + extraStorageAccessAddresses.length);
        allowed[0] = address(dgfProxy);
        allowed[1] = address(ownerSafe);
        allowed[2] = address(councilSafe);
        allowed[3] = address(foundationSafe);
        address livenessGuard = address(uint160(uint256(vm.load(address(councilSafe), livenessGuardSlot))));
        allowed[4] = livenessGuard;

        for (uint256 i = 0; i < extraStorageAccessAddresses.length; i++) {
            allowed[5 + i] = extraStorageAccessAddresses[i];
        }
        return allowed;
    }

    /// @notice Checks the correctness of the deployment
    function _postCheck(Vm.AccountAccess[] memory accesses, Simulation.Payload memory) internal view override {
        console.log("Running post-deploy assertions");

        checkStateDiff(accesses);
        // INSERT NEW POST CHECKS HERE
        postcheckASR();

        console.log("All assertions passed!");
    }

}
