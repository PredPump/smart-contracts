// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {FixedProductMarketMaker} from "./FPMM.sol";

library MarketMakerLib {
    function validateInputs(address collateral, uint256 fee) internal pure {
        require(collateral != address(0), "Invalid collateral token");
        require(fee <= 10 ** 18, "Fee must be <= 100%");
    }
}

contract FPMMFactory {
    event FPMMCreated(
        address indexed creator,
        address indexed fpmm,
        address indexed conditionalTokens,
        address collateralToken,
        bytes32[] conditionIds,
        uint256[] outcomeSlotCounts,
        uint256 fee
    );

    function createFPMM(
        IERC20 collateralToken,
        ConditionalTokens conditionalTokens,
        bytes32 conditionId,
        uint256 outcomeSlotCount,
        uint256 fee
    ) external returns (FixedProductMarketMaker) {
        MarketMakerLib.validateInputs(address(collateralToken), fee);

        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        uint256[] memory outcomeSlotCounts = new uint256[](1);
        outcomeSlotCounts[0] = outcomeSlotCount;

        FixedProductMarketMaker fpmm = new FixedProductMarketMaker(
            conditionalTokens,
            collateralToken,
            conditionIds,
            outcomeSlotCounts,
            fee
        );

        emit FPMMCreated(
            tx.origin,
            address(fpmm),
            address(conditionalTokens),
            address(collateralToken),
            conditionIds,
            outcomeSlotCounts,
            fee
        );

        return fpmm;
    }
}

contract CTFFactory {
    mapping(address => bool) public isFPMM;
    FPMMFactory public immutable fpmmFactory;

    constructor() {
        fpmmFactory = new FPMMFactory();
    }

    function createFPMM(
        IERC20 collateralToken,
        address oracle,
        bytes32 questionId,
        uint256 outcomeSlotCount,
        uint256 endTime,
        uint256 fee
    ) external returns (FixedProductMarketMaker) {
        ConditionalTokens conditionalTokens = new ConditionalTokens();

        bytes32 conditionId = conditionalTokens.prepareCondition(
            oracle,
            questionId,
            outcomeSlotCount,
            endTime
        );

        FixedProductMarketMaker fpmm = fpmmFactory.createFPMM(
            collateralToken,
            conditionalTokens,
            conditionId,
            outcomeSlotCount,
            fee
        );

        isFPMM[address(fpmm)] = true;
        return fpmm;
    }

    function isValidFPMM(address fpmmAddress) external view returns (bool) {
        return isFPMM[fpmmAddress];
    }
}
