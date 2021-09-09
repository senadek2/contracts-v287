// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../AccountContextHandler.sol";
import "../markets/CashGroup.sol";
import "../valuation/AssetHandler.sol";
import "../../math/Bitmap.sol";
import "../../math/SafeInt256.sol";
import "../../global/Constants.sol";
import "../../global/Types.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library BitmapAssetsHandler {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using Bitmap for bytes32;
    using CashGroup for CashGroupParameters;
    using AccountContextHandler for AccountContext;

    function _getAssetsBitmapSlot(address account, uint256 currencyId)
        private
        pure
        returns (bytes32)
    {
        // @audit-ok
        return
            keccak256(
                abi.encode(
                    account,
                    keccak256(abi.encode(currencyId, Constants.ASSETS_BITMAP_STORAGE_OFFSET))
                )
            );
    }

    function getAssetsBitmap(address account, uint256 currencyId) internal view returns (bytes32 data) {
        // @audit-ok
        bytes32 slot = _getAssetsBitmapSlot(account, currencyId);
        assembly {
            data := sload(slot)
        }
    }

    function setAssetsBitmap(
        address account,
        uint256 currencyId,
        bytes32 assetsBitmap
    ) internal {
        // @audit-ok
        bytes32 slot = _getAssetsBitmapSlot(account, currencyId);
        require(assetsBitmap.totalBitsSet() <= Constants.MAX_BITMAP_ASSETS, "Over max assets");

        assembly {
            sstore(slot, assetsBitmap)
        }
    }

    function getifCashSlot(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) internal pure returns (bytes32) {
        // @audit-ok
        return
            keccak256(
                abi.encode(
                    maturity,
                    keccak256(
                        abi.encode(
                            currencyId,
                            keccak256(abi.encode(account, Constants.IFCASH_STORAGE_OFFSET))
                        )
                    )
                )
            );
    }

    function getifCashNotional(
        address account,
        uint256 currencyId,
        uint256 maturity
    ) internal view returns (int256 notional) {
        // @audit-ok
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        assembly {
            notional := sload(fCashSlot)
        }
    }

    /// @notice Adds multiple assets to a bitmap portfolio
    function addMultipleifCashAssets(
        address account,
        AccountContext memory accountContext,
        PortfolioAsset[] memory assets
    ) internal {
        // @audit-ok
        require(accountContext.isBitmapEnabled()); // dev: bitmap currency not set
        // @audit-ok
        uint256 currencyId = accountContext.bitmapCurrencyId;

        for (uint256 i; i < assets.length; i++) {
            PortfolioAsset memory asset = assets[i];
            if (asset.notional == 0) continue;

            require(asset.currencyId == currencyId); // dev: invalid asset in set ifcash assets
            require(asset.assetType == Constants.FCASH_ASSET_TYPE); // dev: invalid asset in set ifcash assets
            int256 finalNotional;

            finalNotional = addifCashAsset(
                account,
                currencyId,
                asset.maturity,
                accountContext.nextSettleTime,
                asset.notional
            );

            if (finalNotional < 0)
                accountContext.hasDebt = accountContext.hasDebt | Constants.HAS_ASSET_DEBT;
        }
    }

    /// @notice Add an ifCash asset in the bitmap and mapping. Updates the bitmap in memory
    /// but not in storage.
    /// @return the updated assets bitmap and the final notional amount
    function addifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 nextSettleTime,
        int256 notional
    ) internal returns (int256) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
        (uint256 bitNum, bool isExact) = DateTime.getBitNumFromMaturity(nextSettleTime, maturity);
        require(isExact); // dev: invalid maturity in set ifcash asset

        if (assetsBitmap.isBitSet(bitNum)) {
            // Bit is set so we read and update the notional amount
            // @audit-ok
            int256 finalNotional;
            assembly {
                finalNotional := sload(fCashSlot)
            }
            finalNotional = finalNotional.add(notional);

            // @audit-ok
            require(type(int128).min <= finalNotional && finalNotional <= type(int128).max); // dev: bitmap notional overflow
            assembly {
                sstore(fCashSlot, finalNotional)
            }

            // If the new notional is zero then turn off the bit
            if (finalNotional == 0) {
                assetsBitmap = assetsBitmap.setBit(bitNum, false);
            }

            setAssetsBitmap(account, currencyId, assetsBitmap);
            return finalNotional;
        }

        if (notional != 0) {
            // Bit is not set so we turn it on and update the mapping directly, no read required.
            // @audit-ok
            require(type(int128).min <= notional && notional <= type(int128).max); // dev: bitmap notional overflow
            assembly {
                sstore(fCashSlot, notional)
            }

            assetsBitmap = assetsBitmap.setBit(bitNum, true);
            setAssetsBitmap(account, currencyId, assetsBitmap);
        }

        return notional;
    }

    /// @notice Returns the present value of an asset
    function _getPresentValue(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        bool riskAdjusted
    ) private view returns (int256) {
        // @audit-ok
        int256 notional = getifCashNotional(account, currencyId, maturity);

        // In this case the asset has matured and the total value is just the notional amount
        if (maturity <= blockTime) {
            return notional;
        } else {
            uint256 oracleRate = cashGroup.calculateOracleRate(maturity, blockTime);
            if (riskAdjusted) {
                return AssetHandler.getRiskAdjustedPresentfCashValue(
                    cashGroup,
                    notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
            } else {
                return AssetHandler.getPresentfCashValue(
                    notional,
                    maturity,
                    blockTime,
                    oracleRate
                );
            }
        }
    }

    /// @notice Get the net present value of all the ifCash assets
    function getifCashNetPresentValue(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        uint256 blockTime,
        CashGroupParameters memory cashGroup,
        bool riskAdjusted
    ) internal view returns (int256 totalValueUnderlying, bool hasDebt) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 bitNum = assetsBitmap.getNextBitNum();

        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            int256 pv = _getPresentValue(
                account,
                currencyId,
                maturity,
                blockTime,
                cashGroup,
                riskAdjusted
            );
            // @audit-ok
            totalValueUnderlying = totalValueUnderlying.add(pv);

            // @audit-ok
            if (pv < 0) hasDebt = true;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }
    }

    /// @notice Returns the ifCash assets as an array
    function getifCashArray(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime
    ) internal view returns (PortfolioAsset[] memory) {
        // @audit-ok
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        uint256 bitNum = assetsBitmap.getNextBitNum();
        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            int256 notional = getifCashNotional(account, currencyId, maturity);

            PortfolioAsset memory asset = assets[index];
            asset.currencyId = currencyId;
            asset.maturity = maturity;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = notional;
            index += 1;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }

        return assets;
    }

    /// @notice Used to reduce an nToken ifCash assets portfolio proportionately when redeeming
    /// nTokens to its underlying assets.
    function reduceifCashAssetsProportional(
        address account,
        uint256 currencyId,
        uint256 nextSettleTime,
        int256 tokensToRedeem,
        int256 totalSupply
    ) internal returns (PortfolioAsset[] memory) {
        bytes32 assetsBitmap = getAssetsBitmap(account, currencyId);
        uint256 index = assetsBitmap.totalBitsSet();
        PortfolioAsset[] memory assets = new PortfolioAsset[](index);
        index = 0;

        uint256 bitNum = assetsBitmap.getNextBitNum();
        while (bitNum != 0) {
            uint256 maturity = DateTime.getMaturityFromBitNum(nextSettleTime, bitNum);
            bytes32 fCashSlot = getifCashSlot(account, currencyId, maturity);
            int256 notional;
            assembly {
                notional := sload(fCashSlot)
            }

            // @audit-ok
            int256 notionalToTransfer = notional.mul(tokensToRedeem).div(totalSupply);
            notional = notional.sub(notionalToTransfer);
            assembly {
                sstore(fCashSlot, notional)
            }

            PortfolioAsset memory asset = assets[index];
            asset.currencyId = currencyId;
            asset.maturity = maturity;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = notionalToTransfer;
            index += 1;

            // Turn off the bit and look for the next one
            assetsBitmap = assetsBitmap.setBit(bitNum, false);
            bitNum = assetsBitmap.getNextBitNum();
        }

        // If the entire token supply is redeemed then the assets bitmap will have been reduced to zero.
        // Because solidity truncates division there will always be dust left unless the entire supply is
        // redeemed.
        if (tokensToRedeem == totalSupply) {
            // @audit this actually cannot ever happen given the current nTokenRedeem rules
            setAssetsBitmap(account, currencyId, 0x00);
        }

        return assets;
    }
}
