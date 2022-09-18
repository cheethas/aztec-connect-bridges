// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {BridgeTestBase} from "./../../aztec/base/BridgeTestBase.sol";
import {AztecTypes} from "../../../aztec/libraries/AztecTypes.sol";

// Example-specific imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAthensGovernorBravoBridgeContract} from "../../../bridges/athens_governor_bravo/interfaces/IAthensGovernorBravoBridgeContract.sol";
import {AthensGovernorBravoBridgeContract} from "../../../bridges/athens_governor_bravo/AthensGovernorBravoBridgeContract.sol";
import {ErrorLib} from "../../../bridges/base/ErrorLib.sol";
import {ISubsidy, Subsidy} from "../../../aztec/Subsidy.sol";
import {AthensFactory} from "../../../../lib/governor-of-athens/src/AthensFactory.sol";

/**
 * @notice The purpose of this test is to test the bridge in an environment that is as close to the final deployment
 *         as possible without spinning up all the rollup infrastructure (sequencer, proof generator etc.).
 */
contract ExampleE2ETest is BridgeTestBase {
    address constant COMPOUND_TOKEN = address(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    address constant COMPOUNT_GOVERNANCE = address(0xc0Da02939E1441F497fd74F78cE7Decb17B66529);

    AthensFactory athensFactory;
    AthensGovernorBravoBridgeContract bridge;

    // To store the id of the example bridge after being added
    uint256 private id;

    function setUp() public {
        // Deploy factory contract
        athensFactory = new AthensFactory();

        // Deploy a new example bridge with knowledge of the rollup processor and the just deployed factory
        bridge = new AthensGovernorBravoBridgeContract(address(ROLLUP_PROCESSOR), address(athensFactory));

        // Set the bridge in the factory
        athensFactory.setBridge(address(bridge));

        // Use the label cheatcode to mark the address with "Example Bridge" in the traces
        vm.label(address(bridge), "Athens Bridge");
        vm.label(address(athensFactory), "Athens Factory");

        // Impersonate the multi-sig to add a new bridge
        vm.startPrank(MULTI_SIG);

        // List the example-bridge with a gasLimit of 120k
        // WARNING: If you set this value too low the interaction will fail for seemingly no reason!
        // OTOH if you se it too high bridge users will pay too much
        ROLLUP_PROCESSOR.setSupportedBridge(address(bridge), 520000);

        // List COMPOUND with a gasLimit of 100k
        // Note: necessary for assets which are not already registered on RollupProcessor
        // Call https://etherscan.io/address/0xFF1F2B4ADb9dF6FC8eAFecDcbF96A2B351680455#readProxyContract#F25 to get
        // addresses of all the listed ERC20 tokens
        ROLLUP_PROCESSOR.setSupportedAsset(COMPOUND_TOKEN, 500000);

        vm.stopPrank();

        // Fetch the id of the example bridge
        id = ROLLUP_PROCESSOR.getSupportedBridgesLength();
    }

    function testEnterVotePosition() external {
        // Deploy proxy and zka token
        uint256 proposalId = 124;
        uint8 vote = 1;

        uint256 depositAmount = 1e18;

        // Grant the rollup compound tokens
        deal(address(COMPOUND_TOKEN), address(ROLLUP_PROCESSOR), depositAmount);

        // Newly created proxy will have an id of 0
        athensFactory.createVoterProxy(COMPOUND_TOKEN, COMPOUNT_GOVERNANCE, proposalId, vote);
        uint64 proxyId = 0;
        address zkvToken = address(athensFactory.zkVoterTokens(COMPOUND_TOKEN));

        _supportTokens(COMPOUND_TOKEN, zkvToken);

        AztecTypes.AztecAsset memory inputAsset = getRealAztecAsset(COMPOUND_TOKEN);
        AztecTypes.AztecAsset memory outputAsset = getRealAztecAsset(zkvToken);

        uint256 bridgeCalldata = encodeBridgeCallData(id, inputAsset, emptyAsset, outputAsset, emptyAsset, proxyId);
        sendDefiRollup(bridgeCalldata, depositAmount);

        uint256 balanceAfter = IERC20(zkvToken).balanceOf(address(ROLLUP_PROCESSOR));
        assertEq(balanceAfter, depositAmount);
    }

    function testEnterThenExitVotePosition() external {
        // Deploy proxy and zka token
        uint256 proposalId = 124;
        uint8 vote = 1;

        uint256 depositAmount = 1e18;

        // Grant the rollup compound tokens
        deal(address(COMPOUND_TOKEN), address(ROLLUP_PROCESSOR), depositAmount);

        // Newly created proxy will have an id of 0
        athensFactory.createVoterProxy(COMPOUND_TOKEN, COMPOUNT_GOVERNANCE, proposalId, vote);
        uint64 proxyId = 0;
        address zkvToken = address(athensFactory.zkVoterTokens(COMPOUND_TOKEN));

        _supportTokens(COMPOUND_TOKEN, zkvToken);

        AztecTypes.AztecAsset memory inputAsset = getRealAztecAsset(COMPOUND_TOKEN);
        AztecTypes.AztecAsset memory outputAsset = getRealAztecAsset(zkvToken);

        uint256 bridgeCalldata = encodeBridgeCallData(id, inputAsset, emptyAsset, outputAsset, emptyAsset, proxyId);
        sendDefiRollup(bridgeCalldata, depositAmount);

        uint256 exitBridgeCalldata = encodeBridgeCallData(id, outputAsset, emptyAsset, inputAsset, emptyAsset, proxyId);
        sendDefiRollup(exitBridgeCalldata, depositAmount);
    }

    function _supportTokens(address input, address output) internal {
        // Add tokens if they are not supported
        if (!isSupportedAsset(input)) {
            vm.prank(MULTI_SIG);
            ROLLUP_PROCESSOR.setSupportedAsset(input, 50000);
        }
        vm.prank(MULTI_SIG);
        ROLLUP_PROCESSOR.setSupportedAsset(output, 50000);
    }
}
