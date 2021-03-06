/**
 * Copyright 2017-2020, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.8;
pragma experimental ABIEncoderV2;

import "./SplittableToken.sol";


interface IBZx {
    function closeLoanPartiallyFromCollateral(
        bytes32 loanOrderHash,
        uint256 closeAmount)
        external
        returns (uint256 actualCloseAmount);

    function withdrawCollateral(
        bytes32 loanOrderHash,
        uint256 withdrawAmount)
        external
        returns (uint256 amountWithdrawn);

    function depositCollateral(
        bytes32 loanOrderHash,
        address depositTokenAddress,
        uint256 depositAmount)
        external
        returns (bool);

    function getMarginLevels(
        bytes32 loanOrderHash,
        address trader)
        external
        view
        returns (
            uint256 initialMarginAmount,
            uint256 maintenanceMarginAmount,
            uint256 currentMarginAmount);

    function getTotalEscrowWithRate(
        bytes32 loanOrderHash,
        address trader,
        uint256 toCollateralRate,
        uint256 toCollateralPrecision)
        external
        view
        returns (
            uint256 netCollateralAmount,
            uint256 interestDepositRemaining,
            uint256 loanToCollateralAmount,
            uint256, // toCollateralRate
            uint256); // toCollateralPrecision

    function oracleAddresses(
        address oracleAddress)
        external
        view
        returns (address);
}

interface IBZxOracle {
    function tradeUserAsset(
        address sourceTokenAddress,
        address destTokenAddress,
        address receiverAddress,
        address returnToSenderAddress,
        uint256 sourceTokenAmount,
        uint256 maxDestTokenAmount,
        uint256 minConversionRate)
        external
        returns (uint256 destTokenAmountReceived, uint256 sourceTokenAmountUsed);

    function setSaneRate(
        address sourceTokenAddress,
        address destTokenAddress)
        external
        returns (uint256 saneRate);

    function clearSaneRate(
        address sourceTokenAddress,
        address destTokenAddress)
        external;
}

interface IWethHelper {
    function claimEther(
        address receiver,
        uint256 amount)
        external
        returns (uint256 claimAmount);
}

contract PositionTokenLogic is SplittableToken {
    using SafeMath for uint256;

    address internal target_;

    modifier fixedSaneRate
    {
        address currentOracle_ = IBZx(bZxContract).oracleAddresses(bZxOracle);

        IBZxOracle(currentOracle_).setSaneRate(
            loanTokenAddress,
            tradeTokenAddress
        );

        _;

        IBZxOracle(currentOracle_).clearSaneRate(
            loanTokenAddress,
            tradeTokenAddress
        );
    }


    function()
        external
        payable
    {}


    /* Public functions */

    function burnToEther(
        address receiver,
        uint256 burnAmount,
        uint256 minPriceAllowed)
        external
        nonReentrant
        fixedSaneRate
        returns (uint256)
    {
        require(msg.sender == tx.origin, "no contract calls");
        uint256 loanAmountOwed = _burnToken(burnAmount, minPriceAllowed);
        if (loanAmountOwed != 0) {
            if (wethContract != loanTokenAddress) {
                (uint256 destTokenAmountReceived,) = _tradeUserAsset(
                    loanTokenAddress,   // sourceTokenAddress
                    address(0),         // destTokenAddress
                    receiver,           // receiver
                    loanAmountOwed,     // sourceTokenAmount
                    true                // throwOnError
                );

                loanAmountOwed = destTokenAmountReceived;
            } else {
                IWethHelper wethHelper = IWethHelper(0x3b5bDCCDFA2a0a1911984F203C19628EeB6036e0);

                bool success = ERC20(wethContract).transfer(
                    address(wethHelper),
                    loanAmountOwed
                );
                if (success) {
                    success = loanAmountOwed == wethHelper.claimEther(receiver, loanAmountOwed);
                }
                require(success, "transfer of ETH failed");
            }
        }

        return loanAmountOwed;
    }

    function burnToToken(
        address receiver,
        address burnTokenAddress,
        uint256 burnAmount,
        uint256 minPriceAllowed)
        external
        nonReentrant
        fixedSaneRate
        returns (uint256)
    {
        require(msg.sender == tx.origin, "no contract calls");
        uint256 loanAmountOwed = _burnToken(burnAmount, minPriceAllowed);
        if (loanAmountOwed != 0) {
            if (burnTokenAddress != loanTokenAddress) {
                (uint256 destTokenAmountReceived,) = _tradeUserAsset(
                    loanTokenAddress,   // sourceTokenAddress
                    burnTokenAddress,   // destTokenAddress
                    receiver,           // receiver
                    loanAmountOwed,     // sourceTokenAmount
                    true                // throwOnError
                );

                loanAmountOwed = destTokenAmountReceived;
            } else {
                require(ERC20(loanTokenAddress).transfer(
                    receiver,
                    loanAmountOwed
                ), "transfer of loanToken failed");
            }
        }

        return loanAmountOwed;
    }

    function wrapEther()
        external
        nonReentrant
    {
        if (address(this).balance != 0) {
            WETHInterface(wethContract).deposit.value(address(this).balance)();
        }
    }

    // Sends non-LoanToken assets to the Oracle fund
    // These are assets that would otherwise be "stuck" due to a user accidently sending them to the contract
    function donateAsset(
        address tokenAddress)
        external
        onlyOwner
        nonReentrant
        returns (bool)
    {
        if (tokenAddress == loanTokenAddress)
            return false;

        uint256 balance = ERC20(tokenAddress).balanceOf(address(this));
        if (balance == 0)
            return false;

        require(ERC20(tokenAddress).transfer(
            IBZx(bZxContract).oracleAddresses(bZxOracle),
            balance
        ), "transfer of token balance failed");

        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value)
        public
        onlyOwner
        returns (bool)
    {
        super.transferFrom(
            _from,
            _to,
            _value
        );

        // handle checkpoint update
        uint256 currentPrice = denormalize(tokenPrice());
        if (balanceOf(_from) != 0) {
            checkpointPrices_[_from] = currentPrice;
        } else {
            checkpointPrices_[_from] = 0;
        }
        if (balanceOf(_to) != 0) {
            checkpointPrices_[_to] = currentPrice;
        } else {
            checkpointPrices_[_to] = 0;
        }

        return true;
    }

    function transfer(
        address _to,
        uint256 _value)
        public
        onlyOwner
        returns (bool)
    {
        super.transfer(
            _to,
            _value
        );

        // handle checkpoint update
        uint256 currentPrice = denormalize(tokenPrice());
        if (balanceOf(msg.sender) != 0) {
            checkpointPrices_[msg.sender] = currentPrice;
        } else {
            checkpointPrices_[msg.sender] = 0;
        }
        if (balanceOf(_to) != 0) {
            checkpointPrices_[_to] = currentPrice;
        } else {
            checkpointPrices_[_to] = 0;
        }

        return true;
    }

    function depositCollateralToLoan(
        uint256 depositAmount)
        external
        nonReentrant
    {
        require(msg.sender == tx.origin, "no contract calls");
        require(ERC20(loanTokenAddress).transferFrom(
            msg.sender,
            address(this),
            depositAmount
        ), "transfer of token failed");

        uint256 tempAllowance = ERC20(loanTokenAddress).allowance(address(this), bZxVault);
        if (tempAllowance < depositAmount) {
            if (tempAllowance != 0) {
                // reset approval to 0
                require(ERC20(loanTokenAddress).approve(bZxVault, 0), "token approval reset failed");
            }

            require(ERC20(loanTokenAddress).approve(bZxVault, MAX_UINT), "token approval failed");
        }

        require(IBZx(bZxContract).depositCollateral(
            loanOrderHash,
            loanTokenAddress,
            depositAmount
        ), "deposit failed");
    }

    /* Public View functions */

    function tokenPrice()
        public
        view
        returns (uint256 price)
    {
        uint256 netCollateralAmount;
        uint256 interestDepositRemaining;
        if (totalSupply() != 0) {
            (netCollateralAmount, interestDepositRemaining,,,) = IBZx(bZxContract).getTotalEscrowWithRate(
                loanOrderHash,
                address(this),
                0,
                0
            );
        }

        return _tokenPrice(netCollateralAmount, interestDepositRemaining);
    }

    function liquidationPrice()
        public
        view
        returns (uint256 price)
    {
        (,uint256 maintenanceMarginAmount,uint256 currentMarginAmount) = IBZx(bZxContract).getMarginLevels(
            loanOrderHash,
            address(this));

        if (maintenanceMarginAmount == 0)
            return 0;
        else if (currentMarginAmount <= maintenanceMarginAmount)
            return tokenPrice();

        return tokenPrice()
            .mul(maintenanceMarginAmount)
            .div(currentMarginAmount);
    }

    function checkpointPrice(
        address _user)
        public
        view
        returns (uint256 price)
    {
        return normalize(checkpointPrices_[_user]);
    }

    function currentLeverage()
        public
        view
        returns (uint256 leverage)
    {
        (,,uint256 currentMarginAmount) = IBZx(bZxContract).getMarginLevels(
            loanOrderHash,
            address(this));

        if (currentMarginAmount == 0)
            return 0;

        return SafeMath.div(10**38, currentMarginAmount);
    }

    // returns the user's balance of underlying token
    function assetBalanceOf(
        address _owner)
        public
        view
        returns (uint256)
    {
        return balanceOf(_owner)
            .mul(tokenPrice())
            .div(10**18);
    }


    /* Internal functions */

    function _burnToken(
        uint256 burnAmount,
        uint256 minPriceAllowed)
        internal
        returns (uint256)
    {
        require(burnAmount != 0, "burnAmount == 0");

        if (burnAmount > balanceOf(msg.sender)) {
            burnAmount = balanceOf(msg.sender);
        }

        (uint256 netCollateralAmount,
         uint256 interestDepositRemaining,
         ,
         uint256 toCollateralRate,
         uint256 toCollateralPrecision) = IBZx(bZxContract).getTotalEscrowWithRate(
            loanOrderHash,
            address(this),
            0,
            0
        );
        uint256 currentPrice = _tokenPrice(netCollateralAmount, interestDepositRemaining);

        if (minPriceAllowed != 0) {
            require(
                currentPrice >= minPriceAllowed,
                "price too low"
            );
        }

        uint256 loanAmountOwed = burnAmount
            .mul(currentPrice)
            .div(10**18);

        uint256 loanAmountAvailableInContract = ERC20(loanTokenAddress).balanceOf(address(this));

        uint256 preCloseEscrow = loanAmountAvailableInContract
            .add(netCollateralAmount)
            .add(interestDepositRemaining);

        bool didCallWithdraw;
        if (loanAmountAvailableInContract < loanAmountOwed) {
            // will revert if the position needs to be liquidated
            IBZx(bZxContract).closeLoanPartiallyFromCollateral(
                loanOrderHash,
                burnAmount < totalSupply() ?
                    loanAmountOwed.sub(loanAmountAvailableInContract) :
                    MAX_UINT
            );

            loanAmountAvailableInContract = ERC20(loanTokenAddress).balanceOf(address(this));
            didCallWithdraw = true;
        }

        if (loanAmountAvailableInContract < loanAmountOwed && burnAmount < totalSupply()) {
            uint256 collateralWithdrawn = IBZx(bZxContract).withdrawCollateral(
                loanOrderHash,
                loanAmountOwed.sub(loanAmountAvailableInContract)
            );
            if (collateralWithdrawn != 0) {
                loanAmountAvailableInContract = loanAmountAvailableInContract.add(collateralWithdrawn);
                didCallWithdraw = true;
            }
        }

        if (didCallWithdraw) {
            if (burnAmount < totalSupply()) {
                (netCollateralAmount, interestDepositRemaining,,,) = IBZx(bZxContract).getTotalEscrowWithRate(
                    loanOrderHash,
                    address(this),
                    toCollateralRate,
                    toCollateralPrecision
                );
                uint256 postCloseEscrow = loanAmountAvailableInContract
                    .add(netCollateralAmount)
                    .add(interestDepositRemaining);

                if (postCloseEscrow < preCloseEscrow) {
                    /*uint256 slippageLoss = loanAmountOwed
                        .mul(preCloseEscrow - postCloseEscrow)
                        .div(netCollateralAmount);*/
                    uint256 slippageLoss = preCloseEscrow - postCloseEscrow;

                    require(loanAmountOwed > slippageLoss, "slippage too great");
                    loanAmountOwed = loanAmountOwed - slippageLoss;
                }
            }

            if (loanAmountOwed > loanAmountAvailableInContract) {
                /*
                // allow at most 5% loss here
                require(
                    loanAmountOwed
                    .sub(loanAmountAvailableInContract)
                    .mul(10**20)
                    .div(loanAmountOwed) <= (5 * 10**18),
                    "contract value too low"
                );
                */
                loanAmountOwed = loanAmountAvailableInContract;
            }
        }

        // unless burning the full balance, loanAmountOwed must be >= 0.001 loanToken units
        //require(burnAmount == balanceOf(msg.sender) || loanAmountOwed >= (10**15 * 10**uint256(decimals) / 10**18), "burnAmount too low");

        _burn(msg.sender, burnAmount, loanAmountOwed, currentPrice);

        if (totalSupply() == 0 || tokenPrice() == 0) {
            splitFactor = 10**18;
            currentPrice = initialPrice;
        }

        if (balanceOf(msg.sender) != 0) {
            checkpointPrices_[msg.sender] = denormalize(currentPrice);
        } else {
            checkpointPrices_[msg.sender] = 0;
        }

        return loanAmountOwed;
    }

    function _tradeUserAsset(
        address sourceTokenAddress,
        address destTokenAddress,
        address receiver,
        uint256 sourceTokenAmount,
        bool throwOnError)
        internal
        returns (uint256 destTokenAmountReceived, uint256 sourceTokenAmountUsed)
    {
        address oracleAddress = IBZx(bZxContract).oracleAddresses(bZxOracle);

        uint256 tempAllowance = ERC20(sourceTokenAddress).allowance(address(this), oracleAddress);
        if (tempAllowance < sourceTokenAmount) {
            if (tempAllowance != 0) {
                // reset approval to 0
                require(ERC20(sourceTokenAddress).approve(oracleAddress, 0), "token approval reset failed");
            }

            require(ERC20(sourceTokenAddress).approve(oracleAddress, MAX_UINT), "token approval failed");
        }

        (bool success, bytes memory data) = oracleAddress.call(
            abi.encodeWithSignature(
                "tradeUserAsset(address,address,address,address,uint256,uint256,uint256)",
                sourceTokenAddress,
                destTokenAddress,
                receiver, // receiverAddress
                receiver, // returnToSenderAddress
                sourceTokenAmount,
                MAX_UINT, // maxDestTokenAmount
                0 // minConversionRate
            )
        );
        require(!throwOnError || success, "trade error");
        assembly {
            if eq(success, 1) {
                destTokenAmountReceived := mload(add(data, 32))
                sourceTokenAmountUsed := mload(add(data, 64))
            }
        }
    }


    /* Internal View functions */

    function _tokenPrice(
        uint256 netCollateralAmount,
        uint256 interestDepositRemaining)
        internal
        view
        returns (uint256)
    {
        return totalSupply_ != 0 ?
            normalize(
                ERC20(loanTokenAddress).balanceOf(address(this))
                .add(netCollateralAmount)
                .add(interestDepositRemaining)
                .mul(10**18)
                .div(totalSupply_)
            ) : initialPrice;
    }


    /* Owner-Only functions */

    function handleSplit()
        public
        onlyOwner
    {
        if (totalSupply() != 0) {
            splitFactor = splitFactor
                .mul(initialPrice)
                .div(
                    tokenPrice()
                );
        } else {
            splitFactor = 10**18;
        }
    }

    function updateSettings(
        address settingsTarget,
        bytes memory callData)
        public
    {
        if (msg.sender != owner) {
            address _lowerAdmin;
            address _lowerAdminContract;

            //keccak256("pToken_LowerAdminAddress")
            //keccak256("pToken_LowerAdminContract")
            assembly {
                _lowerAdmin := sload(0x4d9d6037d7e53fa4549f7e532571af3aa103c886a59baf156ebf80c2b3b99b6e)
                _lowerAdminContract := sload(0x544cf74df6879599b75c5fbe7afeb236fc89a80fffaa97fdb08f1e24886a2491)
            }
            require(msg.sender == _lowerAdmin && settingsTarget == _lowerAdminContract);
        }

        address currentTarget = target_;
        target_ = settingsTarget;

        (bool result,) = address(this).call(callData);

        uint256 size;
        uint256 ptr;
        assembly {
            size := returndatasize
            ptr := mload(0x40)
            returndatacopy(ptr, 0, size)
            if eq(result, 0) { revert(ptr, size) }
        }

        target_ = currentTarget;

        assembly {
            return(ptr, size)
        }
    }
}
