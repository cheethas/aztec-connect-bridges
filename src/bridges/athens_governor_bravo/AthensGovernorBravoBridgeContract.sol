// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AztecTypes} from "../../aztec/libraries/AztecTypes.sol";
import {ErrorLib} from "../base/ErrorLib.sol";
import {BridgeBase} from "../base/BridgeBase.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AthensFactoryInterface} from "./interfaces/AthensFactoryInterface.sol";

/*//////////////////////////////////////////////////////////////
                        Errors
//////////////////////////////////////////////////////////////*/
error InputAddressInvalid();
error InputAssetBNotEmpty();
error OutputAssetBNotEmpty();

/**
 * @title Athens Governor Bravo Bridge Contract
 * @author Maddiaa <Twitter: @Maddiaa0, Github: @cheethas>
 * @notice Use this contract to anonymously vote on Governor Bravo proposals
 */
contract AthensGovernorBravoBridgeContract is BridgeBase {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            State
    //////////////////////////////////////////////////////////////*/

    /// @notice The Athens Factory contract, all interactions take place through it
    address public athensFactory;

    /*//////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Set address of rollup processor
     * @param _rollupProcessor Address of rollup processor
     * @param _athensFactory Address of Athens Factory
     */
    constructor(address _rollupProcessor, address _athensFactory) BridgeBase(_rollupProcessor) {
        // SUBSIDY = _subsidy;
        athensFactory = _athensFactory;
    }

    /*//////////////////////////////////////////////////////////////
                        Bridge Interactions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A function which returns an _totalInputValue amount of _inputAssetA
     * @param _inputAssetA - Arbitrary ERC20 Governance token -
     * @param _outputAssetA - Equal to zkv(inputAssetA)
     * @return outputValueA - the amount of output asset to return
     * @dev In this case _outputAssetA equals _inputAssetA
     */
    function convert(
        AztecTypes.AztecAsset calldata _inputAssetA,
        AztecTypes.AztecAsset calldata _inputAssetB,
        AztecTypes.AztecAsset calldata _outputAssetA,
        AztecTypes.AztecAsset calldata _outputAssetB,
        uint256 _totalInputValue,
        uint256,
        uint64 _auxData,
        address
    )
        external
        payable
        override(BridgeBase)
        onlyRollup
        returns (
            uint256 outputValueA,
            uint256,
            bool
        )
    {
        // Check the input asset is ERC20
        if (_inputAssetA.assetType != AztecTypes.AztecAssetType.ERC20) {
            revert ErrorLib.InvalidInputA();
        }
        if (_outputAssetA.erc20Address == _inputAssetA.erc20Address) {
            revert ErrorLib.InvalidOutputA();
        }

        // Return the input value of input asset
        outputValueA = _totalInputValue;

        // Approve rollup processor to take input value of input asset
        IERC20(_outputAssetA.erc20Address).approve(ROLLUP_PROCESSOR, _totalInputValue);
        IERC20(_inputAssetA.erc20Address).approve(athensFactory, _totalInputValue);

        // If the input assert if a zkv token, then we want to withdraw funds from the proxy
        // Otherwise we would like to enter TODO: Do we still need other return types?
        (bool enter, , ) = _checkInputs(_inputAssetA, _inputAssetB, _outputAssetA, _outputAssetB);

        if (enter) {
            _allocateVotes(_auxData, _totalInputValue);
        } else {
            _withdrawVotes(_auxData, _totalInputValue);
        }

        return (_totalInputValue, 0, false);
    }

    /** Allocate Votes
     * @notice Batch allocate votes to a proposal
     * @dev This function will credit the rollup with zkv tokens for the input asset
     * @param _auxData - The proposal id
     * @param _totalInputValue - The amount of votes to allocate
     */
    function _allocateVotes(uint64 _auxData, uint256 _totalInputValue) internal {
        AthensFactoryInterface(athensFactory).allocateVote(
            // Allocate vote through the proxy
            _auxData,
            _totalInputValue
        );
    }

    /** Withdraw Votes
     * @notice Batch withdraw votes from a proposal
     * @dev This function will swap zkvTokens for the underlying token
     * @param _auxData - The proposal id
     * @param _totalInputValue - The amount of votes to withdraw
     */
    function _withdrawVotes(uint64 _auxData, uint256 _totalInputValue) internal {
        AthensFactoryInterface(athensFactory).redeemVotingTokens(_auxData, _totalInputValue);
    }

    /** Get ZKV Token
     * @notice Get the zkv token address from the Athens Factory for a given token
     * @param _underlyingAsset - The underlying address
     * @return zkvToken - The zkv token address
     */
    function getZKVToken(address _underlyingAsset) internal returns (address zkvToken) {
        zkvToken = AthensFactoryInterface(athensFactory).zkVoterTokens(_underlyingAsset);
    }

    /** Check Inputs
     * @notice Verify that the correct data has been provided by the rollup
     * @dev Also serves to work out whether the user is wishing to remove tokens from a vote or deposit them
     * @param _inputAssetA Input asset calldata
     * @param _inputAssetB Input asset calldata
     * @param _outputAssetA Output asset calldata
     * @param _outputAssetB Output asset calldata
     */
    function _checkInputs(
        AztecTypes.AztecAsset memory _inputAssetA,
        AztecTypes.AztecAsset memory _inputAssetB,
        AztecTypes.AztecAsset memory _outputAssetA,
        AztecTypes.AztecAsset memory _outputAssetB
    )
        internal
        returns (
            bool,
            address,
            address
        )
    {
        // We are not using assets B
        if (_inputAssetB.assetType != AztecTypes.AztecAssetType.NOT_USED) {
            revert InputAssetBNotEmpty();
        }
        if (_outputAssetB.assetType != AztecTypes.AztecAssetType.NOT_USED) {
            revert OutputAssetBNotEmpty();
        }

        if (_inputAssetA.erc20Address == address(0)) {
            revert InputAddressInvalid();
        }
        if (_outputAssetA.erc20Address == address(0)) {
            revert InputAddressInvalid();
        }

        address underlying;
        address zkvToken;
        address zkvCandidate = getZKVToken(_inputAssetA.erc20Address);

        if (zkvCandidate == address(0)) {
            underlying = _outputAssetA.erc20Address;
            zkvToken = getZKVToken(_outputAssetA.erc20Address);
        } else {
            underlying = _inputAssetA.erc20Address;
            zkvToken = zkvCandidate;
        }

        return (_inputAssetA.erc20Address == underlying, underlying, zkvToken);
    }
}
