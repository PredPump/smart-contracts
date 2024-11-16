// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {FixedProductMarketMaker} from "./FPMM.sol";

contract FPMMFactory {
    // Events
    event FPMMCreated(
        address indexed creator,
        address indexed fpmm,
        address indexed conditionalTokens,
        address collateralToken,
        bytes32[] conditionIds,
        uint256[] outcomeSlotCounts,
        uint256 fee
    );

    // State variables
    // ConditionalTokens public conditionalTokens;
    mapping(address => bool) public isFPMM;
    uint256 public fpmmCount;

    constructor() {
      
    }

    function createFPMM(
    IERC20 collateralToken,
    address oracle,
    bytes32 questionId,
    uint256 outcomeSlotCount,
    uint256 endTime,
    uint256 fee
) external returns (FixedProductMarketMaker) {
    require(address(collateralToken) != address(0), "Invalid collateral token");
    require(fee <= 10 ** 18, "Fee must be <= 100%");

    // Deploy ConditionalTokens first
    ConditionalTokens conditionalTokens = new ConditionalTokens();

    // Prepare condition
    bytes32 conditionId = conditionalTokens.prepareCondition(
        oracle,
        questionId,
        outcomeSlotCount,
        endTime
    );

    // Setup arrays for FPMM constructor
    bytes32[] memory conditionIds = new bytes32[](1);
    conditionIds[0] = conditionId;

    uint256[] memory outcomeSlotCounts = new uint256[](1);
    outcomeSlotCounts[0] = outcomeSlotCount;

    // Create FPMM with the new ConditionalTokens
    FixedProductMarketMaker fpmm = new FixedProductMarketMaker(
        conditionalTokens,
        collateralToken,
        conditionIds,
        outcomeSlotCounts,
        fee
    );

    // Register FPMM
    isFPMM[address(fpmm)] = true;
    fpmmCount++;

    emit FPMMCreated(
        msg.sender,
        address(fpmm),
        address(conditionalTokens),
        address(collateralToken),
        conditionIds,
        outcomeSlotCounts,
        fee
    );

    return fpmm;
}

    function getFPMMCount() external view returns (uint256) {
        return fpmmCount;
    }

    function isValidFPMM(address fpmmAddress) external view returns (bool) {
        return isFPMM[fpmmAddress];
    }
}
