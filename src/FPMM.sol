// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "./helper/SafeMath.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {CTHelpers} from "./helper/CTHelpers.sol";
import {IERC1155Receiver} from "../lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";



library CeilDiv {
    // calculates ceil(x/y)
    function ceildiv(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x > 0) return ((x - 1) / y) + 1;
        return x / y;
    }
}

contract FixedProductMarketMaker is ERC20, IERC1155Receiver {
    event FPMMFundingAdded(address indexed funder, uint256[] amountsAdded, uint256 sharesMinted);
    event FPMMFundingRemoved(
        address indexed funder, uint256[] amountsRemoved, uint256 collateralRemovedFromFeePool, uint256 sharesBurnt
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

    using SafeMath for uint256;
    using CeilDiv for uint256;

    uint256 constant HUNDRED = 100;
    uint256 constant ONE = 10 ** 18;

    ConditionalTokens public conditionalTokens;
    IERC20 public collateralToken;
    bytes32[] public conditionIds;
    uint256 public fee;
    uint256 internal feePoolWeight;

    uint256[] outcomeSlotCounts;
    bytes32[][] collectionIds;
    uint256[] positionIds;
    mapping(address => uint256) withdrawnFees;
    mapping(address => uint256) public withdrawableFeesByUser;
    uint256 internal totalWithdrawnFees;

    constructor(
        ConditionalTokens _conditionalTokens,
        IERC20 _collateralToken,
        bytes32[] memory _conditionIds,
        uint256[] memory _outcomeSlotCounts,
        uint256 _fee
    ) ERC20("FPMM", "FPMM") {
        require(address(_conditionalTokens) != address(0), "conditional tokens is zero");
        require(address(_collateralToken) != address(0), "collateral token is zero");
        require(_conditionIds.length > 0, "condition ids empty");
        require(_outcomeSlotCounts.length == _conditionIds.length, "outcome slots length mismatch");

        conditionalTokens = _conditionalTokens;
        collateralToken = _collateralToken;
        conditionIds = _conditionIds;
        outcomeSlotCounts = _outcomeSlotCounts;
        fee = _fee;

        // Initialize collection IDs
        collectionIds = new bytes32[][](_conditionIds.length);
        for (uint256 i = 0; i < _conditionIds.length; i++) {
            collectionIds[i] = new bytes32[](1);
            collectionIds[i][0] = bytes32(0);
        }

        // Initialize position IDs for binary outcomes
        positionIds = new uint256[](2);
        for (uint256 i = 0; i < positionIds.length; i++) {
            positionIds[i] = CTHelpers.getPositionId(
                IERC20(_collateralToken),
                CTHelpers.getCollectionId(
                    bytes32(0), // Parent collection
                    _conditionIds[0], // First condition
                    1 << i // Outcome index (1=1, 2=2)
                )
            );
        }
    }

    function getPoolBalances() public view returns (uint256[] memory) {
        address[] memory thises = new address[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            thises[i] = address(this);
        }
        return conditionalTokens.balanceOfBatch(thises, positionIds);
    }

    function generateBasicPartition(uint256 outcomeSlotCount) private pure returns (uint256[] memory partition) {
        partition = new uint256[](outcomeSlotCount);
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            partition[i] = 1 << i;
        }
    }

    // function splitPositionThroughAllConditions(uint amount) private {
    //     for (uint i = conditionIds.length - 1; int(i) >= 0; i--) {
    //         uint[] memory partition = generateBasicPartition(
    //             outcomeSlotCounts[i]
    //         );
    //         for (uint j = 0; j < collectionIds[i].length; j++) {
    //             conditionalTokens.splitPosition(
    //                 collateralToken,
    //                 collectionIds[i][j],
    //                 conditionIds[i],
    //                 partition,
    //                 amount
    //             );
    //         }
    //     }
    // }

    function splitPositionThroughAllConditions(uint256 amount) private {
        // For first condition, split collateral
        conditionalTokens.splitPosition(
            collateralToken,
            bytes32(0), // Start with no parent
            conditionIds[0],
            generateBasicPartition(outcomeSlotCounts[0]),
            amount
        );

        // For subsequent conditions, split the outcome tokens from previous split
        for (uint256 i = 1; i < conditionIds.length; i++) {
            bytes32 parentCollection =
                CTHelpers.getCollectionId(bytes32(0), conditionIds[i - 1], 1 << (outcomeSlotCounts[i - 1] - 1));

            conditionalTokens.splitPosition(
                collateralToken,
                parentCollection, // Use previous condition as parent
                conditionIds[i],
                generateBasicPartition(outcomeSlotCounts[i]),
                amount
            );
        }
    }

    function mergePositionsThroughAllConditions(uint256 amount) private {
        for (uint256 i = 0; i < conditionIds.length; i++) {
            uint256[] memory partition = generateBasicPartition(outcomeSlotCounts[i]);
            for (uint256 j = 0; j < collectionIds[i].length; j++) {
                conditionalTokens.mergePositions(
                    collateralToken, collectionIds[i][j], conditionIds[i], partition, amount
                );
            }
        }
    }

    function collectedFees() external view returns (uint256) {
        return feePoolWeight.sub(totalWithdrawnFees);
    }

    function withdrawFees(address account) public {
        uint256 rawAmount = feePoolWeight.mul(balanceOf(account)) / totalSupply();
        uint256 withdrawableAmount = rawAmount.sub(withdrawnFees[account]);
        if (withdrawableAmount > 0) {
            withdrawnFees[account] = rawAmount;
            totalWithdrawnFees = totalWithdrawnFees.add(withdrawableAmount);
            require(collateralToken.transfer(account, withdrawableAmount), "withdrawal transfer failed");
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal {
        if (from != address(0)) {
            withdrawFees(from);
        }

        uint256 totalSupply = totalSupply();
        uint256 withdrawnFeesTransfer = totalSupply == 0 ? amount : feePoolWeight.mul(amount) / totalSupply;

        if (from != address(0)) {
            withdrawnFees[from] = withdrawnFees[from].sub(withdrawnFeesTransfer);
            totalWithdrawnFees = totalWithdrawnFees.sub(withdrawnFeesTransfer);
        } else {
            feePoolWeight = feePoolWeight.add(withdrawnFeesTransfer);
        }
        if (to != address(0)) {
            withdrawnFees[to] = withdrawnFees[to].add(withdrawnFeesTransfer);
            totalWithdrawnFees = totalWithdrawnFees.add(withdrawnFeesTransfer);
        } else {
            feePoolWeight = feePoolWeight.sub(withdrawnFeesTransfer);
        }
    }

    function addFunding(uint256 addedFunds, uint256[] calldata distributionHint) external {
        require(addedFunds > 0, "funding must be non-zero");
        require(distributionHint.length == positionIds.length, "hint length does not match");

        // Transfer the funding to the market maker
        require(collateralToken.transferFrom(msg.sender, address(this), addedFunds), "funding transfer failed");

        // Calculate the amount of outcome tokens to mint
        uint256[] memory sendAmounts = new uint256[](positionIds.length);
        uint256 poolShareSupply = totalSupply();

        if (poolShareSupply == 0) {
            // Initial funding
            require(distributionHint.length == positionIds.length, "hint length does not match");
            uint256 initialPoolWeight = 0;
            for (uint256 i = 0; i < distributionHint.length; i++) {
                require(distributionHint[i] > 0, "invalid distribution hint");
                initialPoolWeight = initialPoolWeight + distributionHint[i];
            }

            for (uint256 i = 0; i < sendAmounts.length; i++) {
                sendAmounts[i] = (addedFunds * distributionHint[i]) / initialPoolWeight;
            }

            poolShareSupply = addedFunds;
        } else {
            // Calculate amounts proportional to current balances
            for (uint256 i = 0; i < sendAmounts.length; i++) {
                sendAmounts[i] = addedFunds;
            }
        }

        // Approve collateral for splitting
        require(collateralToken.approve(address(conditionalTokens), addedFunds), "approval for splits failed");

        uint256[] memory partition = generateBasicPartition(outcomeSlotCounts[0]);

        // Split collateral into outcome tokens
        conditionalTokens.splitPosition(collateralToken, bytes32(0), conditionIds[0], partition, addedFunds);

        // Mint pool shares
        _mint(msg.sender, poolShareSupply);

        emit FPMMFundingAdded(msg.sender, sendAmounts, poolShareSupply);
    }

    function removeFunding(uint256 sharesToBurn) external {
        uint256[] memory poolBalances = getPoolBalances();

        uint256[] memory sendAmounts = new uint256[](poolBalances.length);

        uint256 poolShareSupply = totalSupply();
        for (uint256 i = 0; i < poolBalances.length; i++) {
            sendAmounts[i] = poolBalances[i].mul(sharesToBurn) / poolShareSupply;
        }

        uint256 collateralRemovedFromFeePool = collateralToken.balanceOf(address(this));

        _burn(msg.sender, sharesToBurn);
        collateralRemovedFromFeePool = collateralRemovedFromFeePool.sub(collateralToken.balanceOf(address(this)));

        conditionalTokens.safeBatchTransferFrom(address(this), msg.sender, positionIds, sendAmounts, "");

        emit FPMMFundingRemoved(msg.sender, sendAmounts, collateralRemovedFromFeePool, sharesToBurn);
    }

    function onERC1155Received(
        address, /* operator */
        address, /* from */
        uint256, /* id */
        uint256, /* value */
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address, /* operator */
        address, /* from */
        uint256[] calldata, /* ids */
        uint256[] calldata, /* values */
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function calcBuyAmount(uint256 investmentAmount, uint256 outcomeIndex) public view returns (uint256) {
        require(outcomeIndex < 2, "invalid outcome index");

        uint256[] memory balances = new uint256[](2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionIds[0];
        ids[1] = positionIds[1];

        address[] memory addresses = new address[](2);
        addresses[0] = address(this);
        addresses[1] = address(this);

        balances = conditionalTokens.balanceOfBatch(addresses, ids);

        // Add this check to prevent division by zero
        require(balances[0] > 0 && balances[1] > 0, "insufficient pool liquidity");

        // Calculate the buy amount using the CPMM formula
        uint256 investmentAmountMinusFees = investmentAmount - (investmentAmount * fee) / 1e20;
        uint256 buyTokenPoolBalance = balances[outcomeIndex];
        uint256 otherPoolBalance = balances[outcomeIndex ^ 1];

        return (investmentAmountMinusFees * buyTokenPoolBalance) / (otherPoolBalance + investmentAmountMinusFees);
    }

    function calcSellAmount(uint256 returnAmount, uint256 outcomeIndex)
        public
        view
        returns (uint256 outcomeTokenSellAmount)
    {
        // First check user's balance
        uint256 userBalance = conditionalTokens.balanceOf(msg.sender, positionIds[outcomeIndex]);
        require(userBalance > 0, "No tokens to sell");

        uint256[] memory poolBalances = getPoolBalances();
        uint256 sellTokenPoolBalance = poolBalances[outcomeIndex];
        uint256 otherPoolBalance = poolBalances[outcomeIndex ^ 1];

        // Calculate amount needed with fee included
        uint256 feeAmount = returnAmount.mul(fee).div(ONE);
        uint256 totalAmount = returnAmount.add(feeAmount);

        // Calculate required tokens based on constant product formula
        uint256 requiredTokens = totalAmount.mul(sellTokenPoolBalance).div(otherPoolBalance);

        // Check if user has enough
        require(requiredTokens <= userBalance, "Insufficient balance");

        return requiredTokens;
    }

    // function buy(
    //     uint investmentAmount,
    //     uint outcomeIndex,
    //     uint minOutcomeTokensToBuy
    // ) external returns (uint) {
    //     require(outcomeIndex < positionIds.length, "Invalid outcome index");
    //     require(investmentAmount > 0, "Investment amount must be positive");

    //     // Calculate fee amount (2% fee)
    //     uint feeAmount = (investmentAmount * 2) / 100;
    //     uint investmentAmountMinusFee = investmentAmount - feeAmount;

    //     // Calculate how many outcome tokens the user should receive
    //     uint outcomeTokensToBuy = calcBuyAmount(investmentAmount, outcomeIndex);
    //     require(
    //         outcomeTokensToBuy >= minOutcomeTokensToBuy,
    //         "Slippage limit hit"
    //     );

    //     // Transfer the investment amount from user
    //     require(
    //         collateralToken.transferFrom(
    //             msg.sender,
    //             address(this),
    //             investmentAmount
    //         ),
    //         "Transfer of collateral failed"
    //     );

    //     // Split the collateral into outcome tokens
    //     require(
    //         collateralToken.approve(
    //             address(conditionalTokens),
    //             investmentAmountMinusFee
    //         ),
    //         "Approval for conditional tokens failed"
    //     );

    //     uint[] memory partition = generateBasicPartition(outcomeSlotCounts[0]);

    //     conditionalTokens.splitPosition(
    //         collateralToken,
    //         bytes32(0),
    //         conditionIds[0],
    //         partition,
    //         investmentAmountMinusFee
    //     );

    //     // Transfer the outcome tokens to the buyer
    //     conditionalTokens.safeTransferFrom(
    //         address(this),
    //         msg.sender,
    //         positionIds[outcomeIndex],
    //         outcomeTokensToBuy,
    //         ""
    //     );

    //     // Distribute fees to liquidity providers based on their share
    //     uint totalSupply = totalSupply();
    //     if (totalSupply > 0) {
    //         for (uint i = 0; i < positionIds.length; i++) {
    //             uint256 balance = conditionalTokens.balanceOf(
    //                 address(this),
    //                 positionIds[i]
    //             );
    //             if (balance > 0) {
    //                 //TODO: this is the share of the fee that the holder has not this address
    //                 uint share = balanceOf(address(this));
    //                 console2.log("share on function", share);
    //                 uint holderFee = (feeAmount * share) / totalSupply;
    //                 console2.log("holderFee on function", holderFee);
    //                 withdrawableFeesByUser[address(this)] += holderFee;
    //             }
    //         }
    //     }

    //     emit FPMMBuy(
    //         msg.sender,
    //         investmentAmount,
    //         feeAmount,
    //         outcomeIndex,
    //         outcomeTokensToBuy
    //     );

    //     return outcomeTokensToBuy;
    // }

    function buy(uint256 investmentAmount, uint256 outcomeIndex, uint256 minOutcomeTokensToBuy) external {
        uint256 outcomeTokensToBuy = calcBuyAmount(investmentAmount, outcomeIndex);
        require(outcomeTokensToBuy >= minOutcomeTokensToBuy, "minimum buy amount not reached");

        require(collateralToken.transferFrom(msg.sender, address(this), investmentAmount), "cost transfer failed");

        uint256 feeAmount = investmentAmount.mul(fee) / ONE;
        feePoolWeight = feePoolWeight.add(feeAmount);
        uint256 investmentAmountMinusFees = investmentAmount.sub(feeAmount);
        require(
            investmentAmountMinusFees > 0 && investmentAmountMinusFees <= investmentAmount, "Invalid amount after fees"
        );
        require(
            collateralToken.approve(address(conditionalTokens), investmentAmountMinusFees), "approval for splits failed"
        );
        splitPositionThroughAllConditions(investmentAmountMinusFees);

        conditionalTokens.safeTransferFrom(address(this), msg.sender, positionIds[outcomeIndex], outcomeTokensToBuy, "");

        emit FPMMBuy(msg.sender, investmentAmount, feeAmount, outcomeIndex, outcomeTokensToBuy);
    }

    // function sell(
    //     uint returnAmount,
    //     uint outcomeIndex,
    //     uint maxOutcomeTokensToSell
    // ) external {
    //     uint outcomeTokensToSell = calcSellAmount(returnAmount, outcomeIndex);
    //     require(
    //         outcomeTokensToSell <= maxOutcomeTokensToSell,
    //         "maximum sell amount exceeded"
    //     );

    //     conditionalTokens.safeTransferFrom(
    //         msg.sender,
    //         address(this),
    //         positionIds[outcomeIndex],
    //         outcomeTokensToSell,
    //         ""
    //     );

    //     uint feeAmount = returnAmount.mul(fee) / (HUNDRED.sub(fee));
    //     feePoolWeight = feePoolWeight.add(feeAmount);
    //     uint returnAmountPlusFees = returnAmount.add(feeAmount);
    //     mergePositionsThroughAllConditions(returnAmountPlusFees);

    //     require(
    //         collateralToken.transfer(msg.sender, returnAmount),
    //         "return transfer failed"
    //     );

    //     emit FPMMSell(
    //         msg.sender,
    //         returnAmount,
    //         feeAmount,
    //         outcomeIndex,
    //         outcomeTokensToSell
    //     );
    // }

    function sell(uint256 returnAmount, uint256 outcomeIndex, uint256 maxOutcomeTokensToSell) external {
        uint256 outcomeTokensToSell = calcSellAmount(returnAmount, outcomeIndex);
        require(outcomeTokensToSell <= maxOutcomeTokensToSell, "maximum sell amount exceeded");

        conditionalTokens.safeTransferFrom(
            msg.sender, address(this), positionIds[outcomeIndex], outcomeTokensToSell, ""
        );

        uint256 feeAmount = returnAmount.mul(fee) / (ONE.sub(fee));
        feePoolWeight = feePoolWeight.add(feeAmount);
        uint256 returnAmountPlusFees = returnAmount.add(feeAmount);
        mergePositionsThroughAllConditions(returnAmountPlusFees);

        require(collateralToken.transfer(msg.sender, returnAmount), "return transfer failed");

        emit FPMMSell(msg.sender, returnAmount, feeAmount, outcomeIndex, outcomeTokensToSell);
    }

    function getSharePrice() public view returns (uint256) {
    uint256[] memory poolBalances = getPoolBalances();
    uint256 totalShares = totalSupply();

    
    // If no shares exist, return initial price (1:1)
    if (totalShares == 0) return ONE;
    
    // Get total collateral in the pool
    uint256 totalCollateral = collateralToken.balanceOf(address(conditionalTokens));

    
    // Each share represents a proportional claim on the pool's collateral
    // Price = total_collateral / total_shares
    return totalCollateral.mul(ONE).div(totalShares);
}

function getIndividualOutcomePrice(uint256[] memory balances, uint256 outcomeIndex) public pure returns (uint256) {
    uint256 outcomeBalance = balances[outcomeIndex];
    uint256 otherBalance = balances[outcomeIndex ^ 1];  // XOR to get opposite position
    
    // Price = opposite_balance / (my_balance + opposite_balance)
    return otherBalance.mul(ONE).div(outcomeBalance.add(otherBalance));
}

function getOutcomeTokenPrices() public view returns (uint256 yesPrice, uint256 noPrice) {
    uint256[] memory balances = getPoolBalances();
    require(balances[0] > 0 && balances[1] > 0, "insufficient pool liquidity");

    // For 1 collateralToken (e.g., 1 USDC) worth of shares, how many outcome tokens?
    // Using the CPMM formula from calcBuyAmount but for 1 collateralToken
    uint256 oneCollateral = ONE;  // 1e18 to match precision
    uint256 feeAmount = oneCollateral.mul(fee).div(ONE);
    uint256 investmentAmountMinusFees = oneCollateral.sub(feeAmount);

    // Calculate YES price (outcome 0)
    uint256 yesTokenAmount = investmentAmountMinusFees.mul(balances[0]).div(balances[1].add(investmentAmountMinusFees));
    yesPrice = oneCollateral.mul(ONE).div(yesTokenAmount);  // Cost per token in collateralToken

    // Calculate NO price (outcome 1)
    uint256 noTokenAmount = investmentAmountMinusFees.mul(balances[1]).div(balances[0].add(investmentAmountMinusFees));
    noPrice = oneCollateral.mul(ONE).div(noTokenAmount);    // Cost per token in collateralToken
}

// For a more user-friendly version that shows prices for a specific investment amount
function getSharePricesForAmount(uint256 investmentAmount) public view returns (
    uint256 yesTokens,
    uint256 yesUnitPrice,    // Price per YES token
    uint256 noTokens,
    uint256 noUnitPrice      // Price per NO token
) {
    // Calculate tokens you'd get for the investment
    yesTokens = calcBuyAmount(investmentAmount, 0);  // YES tokens
    noTokens = calcBuyAmount(investmentAmount, 1);   // NO tokens

    // Calculate unit prices (in collateralToken with 18 decimals)
    yesUnitPrice = investmentAmount.mul(ONE).div(yesTokens);
    noUnitPrice = investmentAmount.mul(ONE).div(noTokens);
}

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {}

    function getPositionId(uint256 outcomeIndex) public view returns (bytes32) {
        return bytes32(positionIds[outcomeIndex]);
    }

    function feesWithdrawableBy(address account) public view returns (uint256) {
        return withdrawableFeesByUser[account];
    }

    function withdrawFees() external {
        uint256 withdrawableFees = withdrawableFeesByUser[msg.sender];
        require(withdrawableFees > 0, "No fees to withdraw");

        withdrawableFeesByUser[msg.sender] = 0;
        collateralToken.transfer(msg.sender, withdrawableFees);
    }
}

// for proxying purposes
contract FixedProductMarketMakerData {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowances;
    uint256 internal _totalSupply;

    bytes4 internal constant _INTERFACE_ID_ERC165 = 0x01ffc9a7;
    mapping(bytes4 => bool) internal _supportedInterfaces;

    event FPMMFundingAdded(address indexed funder, uint256[] amountsAdded, uint256 sharesMinted);
    event FPMMFundingRemoved(
        address indexed funder, uint256[] amountsRemoved, uint256 collateralRemovedFromFeePool, uint256 sharesBurnt
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

    ConditionalTokens internal conditionalTokens;
    IERC20 internal collateralToken;
    bytes32[] internal conditionIds;
    uint256 internal fee;
    uint256 internal feePoolWeight;

    uint256[] internal outcomeSlotCounts;
    bytes32[][] internal collectionIds;
    uint256[] internal positionIds;
    mapping(address => uint256) internal withdrawnFees;
    uint256 internal totalWithdrawnFees;
}
