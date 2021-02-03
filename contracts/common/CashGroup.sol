// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "./Market.sol";
import "../storage/StorageLayoutV1.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @dev Cash group tokens as it is represented in storage.
 * Total storage is: 92 bytes
 * TODO: refactor this so that each token can be read separately. Consider storing
 * transferFee bool as the high order bit of decimalPlaces
 */
struct CashGroupTokens {
    // The asset token that represents the cash side of the liquidity pool
    address assetToken;
    bool assetTokenHasTransferFee;
    uint8 assetDecimalPlaces;

    // The underlying token of the assetToken
    address underlyingToken;
    bool underlyingTokenHasTransferFee;
    uint8 underlyingDecimalPlaces;

    // Perpetual liquidity token address for this cash group
    address perpetualLiquidityToken;
}

/**
 * @dev Cash group when loaded into memory
 */
struct CashGroupParameters {
    uint currencyId;
    uint maxMarketIndex;
    Rate assetRate;
    bytes32 data;
}

library CashGroup {
    using SafeMath for uint256;
    using SafeInt256 for int;

    uint internal constant CASH_GROUP_STORAGE_SLOT = 12;

    // Offsets for the bytes of the different parameters
    // TODO: benchmark if the current method is better than just allocating them to memory
    uint internal constant RATE_ORACLE_TIME_WINDOW = 8;
    uint internal constant LIQUIDITY_FEE = 16;
    uint internal constant LIQUIDITY_TOKEN_HAIRCUT = 24;
    uint internal constant DEBT_BUFFER = 32;
    uint internal constant FCASH_HAIRCUT = 40;
    uint internal constant RATE_SCALAR = 48;

    uint internal constant DAY = 86400;
    // We use six day weeks to ensure that all time references divide evenly
    uint internal constant WEEK = DAY * 6;
    uint internal constant MONTH = DAY * 30;
    uint internal constant QUARTER = DAY * 90;
    uint internal constant YEAR = QUARTER * 4;

    // Max offsets used for bitmap
    uint internal constant MAX_DAY_OFFSET = 90;
    uint internal constant MAX_WEEK_OFFSET = 354;
    uint internal constant MAX_MONTH_OFFSET = 2124;
    uint internal constant MAX_QUARTER_OFFSET = 7200;
    uint internal constant WEEK_BIT_OFFSET = 91;
    uint internal constant MONTH_BIT_OFFSET = 136;
    uint internal constant QUARTER_BIT_OFFSET = 196;
    int internal constant TOKEN_HAIRCUT_DECIMALS = 100;


    /**
     * @notice These are the predetermined market offsets for trading, they are 1-indexed because
     * the 0 index means that no markets are listed for the cash group.
     * @dev This is a function because array types are not allowed to be constants yet.
     */
    function getTradedMarket(uint index) internal pure returns (uint) {
        assert (index != 0);

        if (index == 1) return QUARTER;
        if (index == 2) return 2 * QUARTER;
        if (index == 3) return YEAR;
        if (index == 4) return 2 * YEAR;
        if (index == 5) return 5 * YEAR;
        if (index == 6) return 7 * YEAR;
        if (index == 7) return 10 * YEAR;
        if (index == 8) return 15 * YEAR;
        if (index == 9) return 20 * YEAR;
    }

    /**
     * @notice Returns the current reference time which is how all the AMM dates are
     * calculated.
     */
    function getReferenceTime(uint blockTime) internal pure returns (uint) {
        return blockTime.sub(blockTime % QUARTER);
    }

    /**
     * @notice Truncates a date to midnight UTC time
     */
    function getTimeUTC0(uint time) internal pure returns (uint) {
        return time.sub(time % DAY);
    }

    /**
     * @notice Determines if the maturity falls on one of the valid on chain market dates.
     */
    function isValidMaturity(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) internal pure returns (bool) {
        uint maxMarketIndex = cashGroup.maxMarketIndex;
        require(maxMarketIndex > 0, "CG: no markets listed");
        require(maxMarketIndex < 10, "CG: market index bound");

        if (maturity % QUARTER != 0) return false;
        uint tRef = getReferenceTime(blockTime);

        for (uint i = 1; i <= maxMarketIndex; i++) {
            if (maturity == tRef.add(getTradedMarket(i))) return true;
        }

        return false;
    }

    /**
     * @notice Determines if an idiosyncratic maturity is valid and returns the bit reference
     * that is the case.
     *
     * @return 0 if invalid, otherwise the 1-indexed bit reference of the maturity
     */
    function isValidIdiosyncraticMaturity(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) internal pure returns (uint) {
        uint tRef = getReferenceTime(blockTime);
        uint maxMaturity = tRef.add(getTradedMarket(cashGroup.maxMarketIndex));
        if (maturity > maxMaturity) return 0;

        return getBitNumFromMaturity(blockTime, maturity);
    }

    /**
     * @notice Given a bit number and the reference time of the first bit, returns the bit number
     * of a given maturity.
     */
    function getBitNumFromMaturity(
       uint blockTime,
       uint maturity
    ) internal pure returns (uint) {
        uint blockTimeUTC0 = getTimeUTC0(blockTime);

        if (maturity % DAY != 0) return 0;
        if (blockTimeUTC0 >= maturity) return 0;

        // Overflow check done above
        uint daysOffset = (maturity - blockTimeUTC0) / DAY;
        uint blockTimeDays = blockTimeUTC0 / DAY;

        // These if statements need to fall through to the next one
        if (daysOffset <= MAX_DAY_OFFSET) return daysOffset;
        if (daysOffset <= MAX_WEEK_OFFSET) {
            uint offset = daysOffset - MAX_DAY_OFFSET + (blockTimeDays % 6);
            // Ensures that the maturity specified falls on the actual day, otherwise division
            // will truncate it
            if (offset % 6 != 0) return 0;

            // TODO: consider changing the initial bit offset
            return WEEK_BIT_OFFSET + offset / 6;
        }

        if (daysOffset <= MAX_MONTH_OFFSET) {
            uint offset = daysOffset - MAX_WEEK_OFFSET + (blockTimeDays % 30);
            if (offset % 30 != 0) return 0;

            return MONTH_BIT_OFFSET + offset / 30;
        }

        if (daysOffset <= MAX_QUARTER_OFFSET) {
            uint offset = daysOffset - MAX_MONTH_OFFSET + (blockTimeDays % 90);
            if (offset % 90 != 0) return 0;

            return QUARTER_BIT_OFFSET + offset / 90;
        }

        return 0;
    }

    /**
     * @notice Given a bit number and a block time returns the maturity that the bit number
     * should reference. Bit numbers are one indexed.
     */
    function getMaturityFromBitNum(
        uint blockTime,
        uint bitNum
    ) internal pure returns (uint) {
        require(bitNum != 0, "CG: bit num underflow");
        require(bitNum <= 256, "CG: bit num overflow");
        uint blockTimeUTC0 = getTimeUTC0(blockTime);

        if (bitNum <= WEEK_BIT_OFFSET - 1) {
            return blockTimeUTC0 + bitNum * DAY;
        }

        if (bitNum <= MONTH_BIT_OFFSET - 1) {
            uint firstBit = blockTimeUTC0 + MAX_DAY_OFFSET * DAY - (blockTimeUTC0 % WEEK);
            return firstBit + (bitNum - WEEK_BIT_OFFSET) * WEEK;
        }

        if (bitNum <= QUARTER_BIT_OFFSET - 1) {
            uint firstBit = blockTimeUTC0 + MAX_WEEK_OFFSET * DAY - (blockTimeUTC0 % MONTH);
            return firstBit + (bitNum - MONTH_BIT_OFFSET) * MONTH;
        }

        uint firstBit = blockTimeUTC0 + MAX_MONTH_OFFSET * DAY - (blockTimeUTC0 % QUARTER);
        return firstBit + (bitNum - QUARTER_BIT_OFFSET) * QUARTER;
    }

    /**
     * @notice Returns the rate scalar scaled by time to maturity. The rate scalar multiplies
     * the ln() portion of the liquidity curve as an inverse so it increases with time to 
     * maturity. The effect of the rate scalar on slippage must decrease with time to maturity.
     */
    function getRateScalar(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) internal pure returns (int) {
        int scalar = int(uint16(bytes2(cashGroup.data << RATE_SCALAR)));
        int rateScalar = scalar
            .mul(int(Market.IMPLIED_RATE_TIME))
            .div(int(timeToMaturity));

        require(rateScalar > 0, "CG: rate scalar underflow");
        return rateScalar;
    }

    function annualizeUintValue(
        uint value,
        uint timeToMaturity
    ) private pure returns (uint) {
        return value.mul(timeToMaturity).div(Market.IMPLIED_RATE_TIME);
    }
    
    /**
     * @notice Returns liquidity fees scaled by time to maturity. The liquidity fee is denominated
     * in basis points and will decrease with time to maturity.
     */
    function getLiquidityFee(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) internal pure returns (uint) {
        uint liquidityFee = uint(uint8(bytes1(cashGroup.data << LIQUIDITY_FEE))) * Market.BASIS_POINT;
        return annualizeUintValue(liquidityFee, timeToMaturity);
    }

    function getLiquidityHaircut(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) internal pure returns (uint) {
        // TODO: unclear how this should be calculated
        uint liquidityTokenHaircut = uint(uint8(bytes1(cashGroup.data << LIQUIDITY_TOKEN_HAIRCUT)));
        return liquidityTokenHaircut;
    }

    function getfCashHaircut(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        // TODO: unclear how this should be calculated
        return uint(uint8(bytes1(cashGroup.data << FCASH_HAIRCUT))) * Market.BASIS_POINT;
    }

    function getDebtBuffer(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        return uint(uint8(bytes1(cashGroup.data << DEBT_BUFFER))) * Market.BASIS_POINT;
    }

    function getRateOracleTimeWindow(
        CashGroupParameters memory cashGroup
    ) internal pure returns (uint) {
        // This is denominated in minutes in storage
        return uint(uint8(bytes1(cashGroup.data << RATE_ORACLE_TIME_WINDOW))) * 60;
    }

    /**
     * @notice Called if totalLiquidity is equal to zero. Will initialize the market with the
     * settings supplied by the perpetual liquidity token. This includes setting the initial proportion
     * and the initial rate anchor.
     *
     * TODO: is this a stateful function or not?
     function initializeMarket(
       CashGroupParameters cashGroup,
       uint maturity,
       uint blockTime,
       address perpetualTokenAddress
     ) internal view returns (Market memory) {
        require(CashGroup.isValidMaturity(cashGroup, maturity, blockTime), "Cash Group: invalid maturity");
        uint timeToMaturity = maturity - blockTime;
        uint rateAnchor = LiquidityCurve.initializeRateAnchor(cashGroup.gRateAnchor, timeToMaturity);

        // TODO: calculate initial amounts and transfer them to market
        uint initialfCash;
        uint initialCash;

        Market memory market = Market({
            totalfCash: initialfCash,
            totalCurrentCash: initialCash,
            totalLiquidity: initialCash,
            rateAnchor: rateAnchor,
            lastDailyRate: 0
        })
        market.lastDailyRate = LiquidityCurve.getDailyRate(cashGroup, market, timeToMaturity);

        return market;
     }
     */

    function getCashGroupStorageBytes(uint currencyId) private view returns(bytes32) {
        bytes32 slot = keccak256(abi.encode(currencyId, CASH_GROUP_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }

        return data;
    }

    /**
     * @notice Converts cash group storage object into memory object
     */
    function buildCashGroup(
        uint currencyId
    ) internal view returns (CashGroupParameters memory) {
        bytes32 data = getCashGroupStorageBytes(currencyId);
        Rate memory assetRate = ExchangeRate.buildAssetRate(currencyId);

        return CashGroupParameters({
            currencyId: currencyId,
            assetRate: assetRate,
            maxMarketIndex: uint(uint8(bytes1(data))),
            data: data
        });
    }

}

contract MockCashGroup is StorageLayoutV1 {
    using CashGroup for CashGroupParameters;

    function setAssetRateMapping(
        uint id,
        RateStorage calldata rs
    ) external {
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setCashGroup(
        uint id,
        CashGroupParameterStorage calldata cg
    ) external {
        cashGroupMapping[id] = cg;
    }

    function getTradedMarket(uint index) public pure returns (uint) {
        return CashGroup.getTradedMarket(index);
    }

    function isValidMaturity(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) public pure returns (bool) {
        bool isValid = cashGroup.isValidMaturity(maturity, blockTime);
        if (maturity < blockTime) assert(!isValid);

        return isValid;
    }

    function getIdiosyncraticBitNumber(
       CashGroupParameters memory cashGroup,
       uint maturity,
       uint blockTime
    ) public pure returns (uint) {
        uint bitNum = cashGroup.isValidIdiosyncraticMaturity(maturity, blockTime);
        // We one index the bitNum so its max it 256
        assert(bitNum < 256);

        return bitNum;
    }

    function getMaturityFromBitNum(
        uint blockTime,
        uint bitNum
    ) public pure returns (uint) {
        uint maturity = CashGroup.getMaturityFromBitNum(blockTime, bitNum);
        assert(maturity > blockTime);

        return maturity;
    }

    function getRateScalar(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) public pure returns (int) {
        int rateScalar = cashGroup.getRateScalar(timeToMaturity);

        return rateScalar;
    }

    function getLiquidityFee(
        CashGroupParameters memory cashGroup,
        uint timeToMaturity
    ) public pure returns (uint) {
        uint fee = cashGroup.getLiquidityFee(timeToMaturity);

        return fee;
    }

    function buildCashGroup(
        uint currencyId
    ) public view returns (CashGroupParameters memory) {
        return CashGroup.buildCashGroup(currencyId);
    }

}