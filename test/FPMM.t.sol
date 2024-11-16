// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {FixedProductMarketMaker} from "../src/FPMM.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {ERC20Mock} from "../src/ERC20Mock.sol";
import {CTHelpers} from "../src/helper/CTHelpers.sol";
import {console2} from "forge-std/console2.sol";
import {CTFFactory} from "../src/CTFFactory.sol";

contract FPMMTest is Test {
    FixedProductMarketMaker public fpmm;
    ConditionalTokens public conditionalTokens;
    ERC20Mock public collateralToken;
    CTFFactory public ctfFactory;
    bytes32 public conditionId;
    uint256[] public positionIds;

    address public constant ORACLE = address(0x1);
    address public constant ALICE = address(0x2);
    address public constant BOB = address(0x3);

    bytes32 public constant QUESTION_ID = bytes32("Test Question 1");
    uint256 public constant OUTCOME_SLOTS = 2; // Binary outcome
    uint256 public constant HUNDRED = 100;
    uint256 public constant ONE = 10 ** 18;
    uint256 public constant FEE = 2; // 2% fee

    event FPMMFundingAdded(
        address indexed funder,
        uint256[] amountsAdded,
        uint256 sharesMinted
    );

    event FPMMBuy(
        address indexed buyer,
        uint256 investmentAmount,
        uint256 feeAmount,
        uint256 indexed outcomeIndex,
        uint256 outcomeTokensBought
    );

    event FPMMSell(
        address indexed seller,
        uint256 returnAmount,
        uint256 feeAmount,
        uint256 indexed outcomeIndex,
        uint256 outcomeTokensSold
    );

    function setUp() public {
        vm.startPrank(ALICE);
        // Deploy contracts
        collateralToken = new ERC20Mock("Test Token", "TEST");

        // Setup condition
        conditionId = conditionalTokens.prepareCondition(
            ORACLE,
            QUESTION_ID,
            OUTCOME_SLOTS,
            block.timestamp + 1 days
        );

        // Calculate position IDs for binary outcomes
        positionIds = new uint256[](2);
        for (uint256 i = 0; i < positionIds.length; i++) {
            bytes32 collectionId = CTHelpers.getCollectionId(
                bytes32(0), // Parent collection
                conditionId, // Our condition
                1 << i // Outcome index (1=1, 2=2)
            );
            positionIds[i] = CTHelpers.getPositionId(
                ERC20Mock(collateralToken),
                collectionId
            );
        }

        // Initialize FPMM
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        uint256[] memory outcomeSlotCounts = new uint256[](1);
        outcomeSlotCounts[0] = OUTCOME_SLOTS;

        // fpmm = new FixedProductMarketMaker(conditionalTokens, collateralToken, conditionIds, outcomeSlotCounts, FEE);

        fpmm = ctfFactory.createFPMM(
            collateralToken,
            ORACLE,
            QUESTION_ID,
            OUTCOME_SLOTS,
            block.timestamp + 1 days,
            FEE
        );

        conditionalTokens = fpmm.conditionalTokens();

        // Mint initial tokens
        collateralToken.mint(ALICE, 1000 ether);
        collateralToken.mint(BOB, 1000 ether);

        vm.label(ORACLE, "Oracle");
        vm.label(ALICE, "Alice");
        vm.label(BOB, "Bob");
        vm.stopPrank();
    }

    function test_InitialState() public view {
        assertEq(fpmm.name(), "FPMM");
        assertEq(fpmm.symbol(), "FPMM");
        assertEq(fpmm.totalSupply(), 0);
        assertEq(fpmm.fee(), FEE);
    }

    function test_InitialLiquidityProvision() public {
        vm.startPrank(ALICE);

        uint256 addedFunds = 100 ether;
        uint256[] memory distributionHint = new uint256[](positionIds.length);
        // Calculate expected amounts based on distribution hint
        uint256[] memory expectedAmounts = new uint256[](positionIds.length);
        uint256 totalHint = 0;

        // First pass: sum up distribution hints
        for (uint256 i = 0; i < positionIds.length; i++) {
            distributionHint[i] = 1;
            totalHint += distributionHint[i];
        }

        // Second pass: calculate expected amounts proportionally
        for (uint256 i = 0; i < positionIds.length; i++) {
            expectedAmounts[i] = (addedFunds * distributionHint[i]) / totalHint;
        }

        collateralToken.approve(address(fpmm), addedFunds);

        vm.expectEmit(true, false, false, true);
        // Use calculated expected amounts instead of distribution hint
        emit FPMMFundingAdded(ALICE, expectedAmounts, addedFunds);

        fpmm.addFunding(addedFunds, distributionHint);

        assertEq(fpmm.balanceOf(ALICE), addedFunds);
        vm.stopPrank();
    }

    function test_Buy() public {
        test_InitialLiquidityProvision();

        vm.startPrank(BOB);
        uint256 investmentAmount = 10 ether;
        uint256 outcomeIndex = 0;

        uint256 expectedTokens = fpmm.calcBuyAmount(
            investmentAmount,
            outcomeIndex
        );
        uint256 expectedFee = (investmentAmount * FEE) / ONE;

        console2.log("expectedTokens", expectedTokens);
        console2.log("expectedFee", expectedFee);

        collateralToken.approve(address(fpmm), investmentAmount);

        vm.expectEmit(true, false, false, true);
        emit FPMMBuy(
            BOB,
            investmentAmount,
            expectedFee,
            outcomeIndex,
            expectedTokens
        );

        fpmm.buy(investmentAmount, outcomeIndex, expectedTokens);
        vm.stopPrank();
    }

    function test_Sell() public {
        test_Buy();

        vm.startPrank(BOB);
        uint256 returnAmount = 5 ether;
        uint256 outcomeIndex = 0;

        uint256 tokensToSell = fpmm.calcSellAmount(returnAmount, outcomeIndex);
        uint256 expectedFee = (returnAmount * FEE) / ONE;

        conditionalTokens.setApprovalForAll(address(fpmm), true);

        vm.expectEmit(true, false, false, true);
        emit FPMMSell(
            BOB,
            returnAmount,
            expectedFee,
            outcomeIndex,
            tokensToSell
        );

        fpmm.sell(returnAmount, outcomeIndex, tokensToSell);
        vm.stopPrank();
    }

    function test_FeeCollection() public {
        test_Buy();

        uint256 feeBalance = fpmm.feesWithdrawableBy(BOB);
        console2.log("feeBalance", feeBalance);
        assertGt(feeBalance, 0);
    }

    function test_FeeWithdrawal() public {
        test_FeeCollection();

        vm.startPrank(BOB);
        uint256 withdrawableBefore = fpmm.feesWithdrawableBy(BOB);
        fpmm.withdrawFees(BOB);
        uint256 withdrawableAfter = fpmm.feesWithdrawableBy(BOB);

        assertGt(withdrawableBefore, 0);
        assertEq(withdrawableAfter, 0);
        vm.stopPrank();
    }

    function test_OracleResolution() public {
        test_Buy();

        vm.startPrank(ORACLE);
        uint256[] memory payouts = new uint256[](OUTCOME_SLOTS);
        payouts[0] = 1;
        payouts[1] = 0;

        conditionalTokens.reportPayouts(QUESTION_ID, payouts);
        vm.stopPrank();

        // Verify condition is resolved
        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
    }

    function testFail_AddZeroLiquidity() public {
        vm.startPrank(ALICE);
        uint256[] memory distributionHint = new uint256[](positionIds.length);
        fpmm.addFunding(0, distributionHint);
        vm.stopPrank();
    }

    function testFail_InvalidOutcomeIndex() public {
        test_InitialLiquidityProvision();

        vm.startPrank(BOB);
        uint256 investmentAmount = 10 ether;
        uint256 invalidOutcomeIndex = 99;

        collateralToken.approve(address(fpmm), investmentAmount);
        fpmm.buy(investmentAmount, invalidOutcomeIndex, 0);
        vm.stopPrank();
    }

    function testFail_InsufficientApproval() public {
        test_InitialLiquidityProvision();

        vm.startPrank(BOB);
        uint256 investmentAmount = 10 ether;
        uint256 outcomeIndex = 0;

        // Don't approve tokens
        fpmm.buy(investmentAmount, outcomeIndex, 0);
        vm.stopPrank();
    }

    //Test User Flow
    function test_UserBuyAndCheckPosition() public {
        test_Buy();

        vm.startPrank(BOB);
        // For YES position (index 0)
        bytes32 collectionId = conditionalTokens.getCollectionId(
            bytes32(0), // parentCollectionId
            conditionId, // your market's condition ID
            1 // 0b01 for YES position
        );
        // Get position ID directly from conditional tokens
        uint256 positionId = conditionalTokens.getPositionId(
            collateralToken, // USDC or whatever collateral
            collectionId
        );
        // conditionalTokens.getCollectionId(bytes32(0), conditionId, indexSet);
        // bytes32 positionId = fpmm.getPositionId(0);
        // uint position = conditionalTokens.getPositionId(collateralToken, positionId);
        uint256 balance = conditionalTokens.balanceOf(BOB, positionId);
        assertGt(balance, 0);
        // uint balance = conditionalTokens.balanceOf(BOB, position);
        // assertGt(balance, 0);
        vm.stopPrank();
    }
}

contract JakeVsMike is Test {
    FixedProductMarketMaker public fpmm;
    ConditionalTokens public conditionalTokens;
    CTFFactory public ctfFactory;
    ERC20Mock public collateralToken;
    bytes32 public conditionId;
    uint256[] public positionIds;

    address public constant ORACLE = address(0x1);
    address public constant ALICE = address(0x2); //LP Provider
    address public constant BOB = address(0x3); // User 1
    address public constant BRIAN = address(0x4); // User 2

    bytes32 public constant QUESTION_ID =
        bytes32("Who will win ? Jake or Mike");
    uint256 public constant OUTCOME_SLOTS = 2; // Binary outcome
    uint256 public constant HUNDRED = 100;
    uint256 public constant ONE = 10 ** 18;
    uint256 public constant FEE = 2; // 2% fee

    event FPMMFundingAdded(
        address indexed funder,
        uint256[] amountsAdded,
        uint256 sharesMinted
    );

    event FPMMBuy(
        address indexed buyer,
        uint256 investmentAmount,
        uint256 feeAmount,
        uint256 indexed outcomeIndex,
        uint256 outcomeTokensBought
    );

    event FPMMSell(
        address indexed seller,
        uint256 returnAmount,
        uint256 feeAmount,
        uint256 indexed outcomeIndex,
        uint256 outcomeTokensSold
    );

    function setUp() public {
        // Deploy contracts
        vm.startPrank(ALICE);
        collateralToken = new ERC20Mock("Test Token", "TEST");
        ctfFactory = new CTFFactory();

        // Calculate position IDs for binary outcomes
        positionIds = new uint256[](2);
        for (uint256 i = 0; i < positionIds.length; i++) {
            bytes32 collectionId = CTHelpers.getCollectionId(
                bytes32(0), // Parent collection
                conditionId, // Our condition
                1 << i // Outcome index (1=1, 2=2)
            );
            positionIds[i] = CTHelpers.getPositionId(
                ERC20Mock(collateralToken),
                collectionId
            );
        }

        // Initialize FPMM
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        uint256[] memory outcomeSlotCounts = new uint256[](1);
        outcomeSlotCounts[0] = OUTCOME_SLOTS;

        fpmm = ctfFactory.createFPMM(
            collateralToken,
            ALICE,
            QUESTION_ID,
            OUTCOME_SLOTS,
            block.timestamp + 1 days,
            FEE
        );

        conditionalTokens = fpmm.conditionalTokens();

        conditionId = conditionalTokens.getConditionId(
            ALICE,
            QUESTION_ID,
            OUTCOME_SLOTS
        );

        // Mint initial tokens
        collateralToken.mint(ALICE, 10000 ether);
        collateralToken.mint(BOB, 10000 ether);
        collateralToken.mint(BRIAN, 10000 ether);

        vm.label(ORACLE, "Oracle");
        vm.label(ALICE, "Alice");
        vm.label(BOB, "Bob");
    }

    function test_InitialState() public view {
        console2.logBytes32(conditionId);
        assertEq(fpmm.name(), "FPMM");
        assertEq(fpmm.symbol(), "FPMM");
        assertEq(fpmm.totalSupply(), 0);
        assertEq(fpmm.fee(), FEE);
    }

    function test_Alice_Fund_Pool() public {
        vm.startPrank(ALICE);

        uint256 addedFunds = 1000 ether;
        uint256[] memory distributionHint = new uint256[](positionIds.length);
        // Calculate expected amounts based on distribution hint
        uint256[] memory expectedAmounts = new uint256[](positionIds.length);
        uint256 totalHint = 0;

        // First pass: sum up distribution hints
        for (uint256 i = 0; i < positionIds.length; i++) {
            distributionHint[i] = 1;
            totalHint += distributionHint[i];
        }

        // Second pass: calculate expected amounts proportionally
        for (uint256 i = 0; i < positionIds.length; i++) {
            expectedAmounts[i] = (addedFunds * distributionHint[i]) / totalHint;
        }

        collateralToken.approve(address(fpmm), addedFunds);

        vm.expectEmit(true, false, false, true);
        // Use calculated expected amounts instead of distribution hint
        emit FPMMFundingAdded(ALICE, expectedAmounts, addedFunds);

        fpmm.addFunding(addedFunds, distributionHint);

        assertEq(fpmm.balanceOf(ALICE), addedFunds);
        vm.stopPrank();
    }

    function test_Bob_Buys_Shares_Jake_No() public {
        test_Alice_Fund_Pool();

        vm.startPrank(BOB);
        uint256 investmentAmount = 10 ether;
        uint256 outcomeIndex = 1;

        uint256 expectedTokens = fpmm.calcBuyAmount(
            investmentAmount,
            outcomeIndex
        );
        uint256 expectedFee = (investmentAmount * FEE) / ONE;

        console2.log("expectedTokens", expectedTokens);
        console2.log("expectedFee", expectedFee);

        collateralToken.approve(address(fpmm), investmentAmount);

        vm.expectEmit(true, false, false, true);
        emit FPMMBuy(
            BOB,
            investmentAmount,
            expectedFee,
            outcomeIndex,
            expectedTokens
        );

        fpmm.buy(investmentAmount, outcomeIndex, expectedTokens);
        vm.stopPrank();
    }

    function test_Brian_Buys_Shares_Mike_Yes() public {
        test_Bob_Buys_Shares_Jake_No();

        console2.log(
            "BRIAN PREVIOUS BALANCE",
            collateralToken.balanceOf(BRIAN)
        );
        vm.startPrank(BRIAN);
        uint256 investmentAmount = 10 ether;
        uint256 outcomeIndex = 0;

        uint256 expectedTokens = fpmm.calcBuyAmount(
            investmentAmount,
            outcomeIndex
        );
        uint256 expectedFee = (investmentAmount * FEE) / ONE;

        console2.log("expectedTokens", expectedTokens);
        console2.log("expectedFee", expectedFee);

        collateralToken.approve(address(fpmm), investmentAmount);

        vm.expectEmit(true, false, false, true);
        emit FPMMBuy(
            BRIAN,
            investmentAmount,
            expectedFee,
            outcomeIndex,
            expectedTokens
        );

        fpmm.buy(investmentAmount, outcomeIndex, expectedTokens);
        console2.log("BRIAN AFTER BALANCE", collateralToken.balanceOf(BRIAN));
        vm.stopPrank();
    }

    function test_Alice_Report_Payout() public {
        test_Brian_Buys_Shares_Mike_Yes();

        vm.startPrank(ALICE);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.warp(2 days);

        conditionalTokens.reportPayouts(QUESTION_ID, payouts);

        vm.stopPrank();

        vm.startPrank(BRIAN);

        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = 1; // Mike's position
        indexSets[1] = 2; // Jake's position

        bytes32 conditionIds = CTHelpers.getConditionId(
            ALICE,
            QUESTION_ID,
            OUTCOME_SLOTS
        );

        conditionalTokens.redeemPositions(
            collateralToken,
            bytes32(0),
            conditionIds,
            indexSets
        );

        uint256 balance = collateralToken.balanceOf(BRIAN);
        assertGt(balance, 0);

        vm.stopPrank();

        vm.startPrank(BOB);

        // He shouldnt get anything

        conditionalTokens.redeemPositions(
            collateralToken,
            bytes32(0),
            conditionIds,
            indexSets
        );

        uint256 balance2 = collateralToken.balanceOf(BOB);
        assertGt(balance2, 0);
    }

    function test_Get_Collateral_Value_Of_Single_Share() public {
        test_Brian_Buys_Shares_Mike_Yes();

        (uint256 yesPrice, uint256 noPrice) = fpmm.getOutcomeTokenPrices();
        // console2.log(value);
    }
}
