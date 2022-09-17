// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Aztec.
pragma solidity >=0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AztecTypes} from "../../aztec/libraries/AztecTypes.sol";
import {ErrorLib} from "../base/ErrorLib.sol";
import {BridgeBase} from "../base/BridgeBase.sol";
import {ISubsidy} from "../../aztec/interfaces/ISubsidy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Ideas
// If the first bit is checked, then the aux data is to create a new shadow court voter contract
//  - The second bit will be the vote - Not including abstain cus its dumb
//  - The last x bytes will contain the proposalId, this will be stored within the shadow court voter contract
//
// If the first bit is not checked, then the aux data is to execute a vote on an existing shadow court voter contract
//   - The proxy that they would like to vote on will be encoded in the aux data

// If the 3rd bit is set then it will execute the data to vote

// Maybe have a mapping in the bridge of supported protocols that can be added to later on.
// This will allow us to be able to store less info in the proxys / deploy new vote contracts internally

pragma solidity 0.8.15;

// Voter proxy that votes on proposals
interface CleisthenesVoterInterface {
    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    function initialize(
        address _factoryAddress,
        address _govAddress,
        address _tokenAddress,
        uint256 _proposalId,
        uint8 _vote
    ) external;

    function executeVote() external;

    function delegate() external;

    function underlyingToken() external returns (address);
}

// Factory that generates proposals
interface AthensFactoryInterface {
    // Events
    event CliesthenesVoterCreated(
        uint64 indexed auxData,
        address indexed governorAddress,
        uint256 indexed proposalId,
        address voterCloneAddress,
        uint8 vote
    );
    event CliesthenesVoterTokenERC20Created(address indexed underlyingToken, address indexed syntheticToken);

    function hasVoteExpired(address tokenAddress, uint256 voteId) external returns (bool);

    function createVoterProxy(
        address _tokenAddress,
        address _governorAddress,
        uint256 _proposalId,
        uint8 _vote
    ) external returns (AthensVoter clone);

    function allocateVote(uint64 _auxData, uint256 _totalInputValue) external;

    function voterProxies(uint64) external returns (address);

    function syntheticVoterTokens(address) external returns (address);

    function unwrapVotes(uint256) external returns (address);
}

error InputAddressInvalid();

/**
 * @title An example bridge contract.
 * @author Aztec Team
 * @notice You can use this contract to immediately get back what you've deposited.
 * @dev This bridge demonstrates the flow of assets in the convert function. This bridge simply returns what has been
 *      sent to it.
 */
contract AthensGovernorBravoBridgeContract is BridgeBase {
    // ISubsidy public immutable SUBSIDY;
    using SafeERC20 for IERC20;

    address public athensFactory;

    /**
     * @notice Set address of rollup processor
     * @param _rollupProcessor Address of rollup processor
     */
    constructor(address _rollupProcessor, address _athensFactory) BridgeBase(_rollupProcessor) {
        // SUBSIDY = _subsidy;
        athensFactory = _athensFactory;
    }

    /**
     * @notice A function which returns an _totalInputValue amount of _inputAssetA
     * @param _inputAssetA - Arbitrary ERC20 token
     * @param _outputAssetA - Equal to _inputAssetA
     * @param _rollupBeneficiary - Address of the contract which receives subsidy in case subsidy was set for a given
     *                             criteria
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
        address _rollupBeneficiary
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
        if (_inputAssetA.assetType != AztecTypes.AztecAssetType.ERC20) revert ErrorLib.InvalidInputA();
        if (_outputAssetA.erc20Address != _inputAssetA.erc20Address) revert ErrorLib.InvalidOutputA();

        // Return the input value of input asset
        outputValueA = _totalInputValue;

        // Approve rollup processor to take input value of input asset
        IERC20(_outputAssetA.erc20Address).approve(ROLLUP_PROCESSOR, _totalInputValue);

        // If the input assert if a zkv token, then we want to withdraw funds from the proxy
        // Otherwise we would like to enter
        (bool enter, address underlyingAddress, address zkvAddress) = _checkInputs(
            _inputAssetA,
            _inputAssetB,
            _outputAssetA,
            _outputAssetB
        );

        if (enter) {
            _allocateVotes(_auxData, _totalInputValue);
        } else {
            _withdrawVotes(_totalInputValue);
        }

        return (_totalInputValue, 0, false);
    }

    function _allocateVotes(uint64 _auxData, uint256 _totalInputValue) internal {
        AthensFactoryInterface(athensFactory).allocateVote(
            // Allocate vote through the proxy
            _auxData,
            _totalInputValue
        );
    }

    function _withdrawVotes(uint256 _totalInputValue) internal {
        AthensFactoryInterface(athensFactory).unwrapVotes(_totalInputValue);
    }

    function getZKVToken(address _underlyingAsset) internal returns (address zkvToken) {
        zkvToken = AthensFactoryInterface(athensFactory).syntheticVoterTokens(_underlyingAsset);
    }

    function _checkInputs(
        AztecTypes.AztecAsset memory _inputAssetA,
        AztecTypes.AztecAsset memory _inputAssetB,
        AztecTypes.AztecAsset memory _outputAssetA,
        AztecTypes.AztecAsset memory _outputAssetB
    )
        internal
        view
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

    /**
     * @notice Computes the criteria that is passed when claiming subsidy.
     * @param _inputAssetA The input asset
     * @param _outputAssetA The output asset
     * @return The criteria
     */
    function computeCriteria(
        AztecTypes.AztecAsset calldata _inputAssetA,
        AztecTypes.AztecAsset calldata,
        AztecTypes.AztecAsset calldata _outputAssetA,
        AztecTypes.AztecAsset calldata,
        uint64
    ) public view override(BridgeBase) returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_inputAssetA.erc20Address, _outputAssetA.erc20Address)));
    }
}
