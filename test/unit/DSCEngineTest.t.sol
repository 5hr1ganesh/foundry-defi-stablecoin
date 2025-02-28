// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3aggregator.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscE;
    HelperConfig config;
    address ethUSDPriceFeed;
    address btcUSDPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant ZERO = 0;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event Approval(address, address, uint256);
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event Transfer(address, address, uint256);

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscE, config) = deployer.run();
        (ethUSDPriceFeed, btcUSDPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////
    // Constructor Tests //
    //////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesnotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUSDPriceFeed);
        priceFeedAddresses.push(btcUSDPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressLengthMisMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests //
    ////////////////

    function testgetUsdValue(uint256 ethAmount) public view {
        // Generate a random value for ethAmount using fuzzing
        ethAmount = bound(ethAmount, 1, 10e18); // Optional: set bounds to limit the range

        // Calculate the expected USD value based on the ethAmount
        uint256 usdPrice = 2000e10; // Example price
        uint256 expectedUsdVal = (ethAmount * usdPrice) / 1e10;
        uint256 actualUsdVal = dscE.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdVal, actualUsdVal);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscE.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////
    // Deposit Collateral Tests //
    /////////////////////////////

    function testRevertIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDSC = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDSC)];
        priceFeedAddresses = [ethUSDPriceFeed];
        vm.prank(owner);
        DSCEngine mockDSCe = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDSC.transferOwnership(address(mockDSCe));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDSC)).approve(address(mockDSCe), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDSCe.depositCollateral(address(mockDSC), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfCollateralLessThanZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscE.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAND", "RanD", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotSupported.selector);
        dscE.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMintingDSC() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscE.getAccountDetails(USER);
        uint256 expectedDepositedCollateralAmount = dscE.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedCollateralAmount);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscE.getAccountDetails(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscE.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    /////////////////////
    // Mint DSC Tests //
    ///////////////////

    function testMintDSCSuccess() public depositedCollateral {
        uint256 amountDSCToMint = 100 * 10 ** 18;
        vm.prank(USER);
        dscE.mintDSC(amountDSCToMint);
        (uint256 totalDscMinted,) = dscE.getAccountDetails(USER);
        uint256 balance = totalDscMinted;
        assertEq(balance, amountDSCToMint);
    }

    // function testMintDSCRevertsOnZeroAmount() public {
    //     vm.prank(USER);
    //     vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
    //     dscE.mintDSC(0);
    // }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscE.mintDSC(0);
        vm.stopPrank();
    }

    function testMintDSCRevertsOnHealthFactorBelowThreshold() public {
        (, int256 price,,,) = MockV3Aggregator(ethUSDPriceFeed).latestRoundData();
        uint256 amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dscE.getAdditionalFeedPrecision())) / dscE.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dscE.calculateHealthFactor(amountToMint, dscE.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__LowHealthFactor.selector, expectedHealthFactor));
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    // function testMintDSCRevertsOnHealthFactorBelowThreshold() public {
    //     uint256 amountDSCToMint = 100 * 1e18;
    //     // Simulate a condition where health factor is below threshold
    //     vm.prank(USER);
    //     vm.expectRevert(DSCEngine.DSCEngine__LowHealthFactor.selector);
    //     dscE.mintDSC(amountDSCToMint);
    // }

    function testRevertsIfmintFails() public {
        //  Arrange - Setup
        MockFailedMintDSC mockDSC = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUSDPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDSCe = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(mockDSCe));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDSCe), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDSCe.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    ///////////////////////////////////////////
    //depositedCollateral and Mint DSC tests//
    /////////////////////////////////////////

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    ////////////////////
    // burnDsc Tests //
    //////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscE.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscE.burnDSC(1);
    }

    function testCanBurnDSC() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscE), AMOUNT_TO_MINT);
        dscE.burnDSC(AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /////////////////////////////
    // redeemCollateral Tests //
    ///////////////////////////

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDSC = new MockFailedTransfer();
        tokenAddresses = [address(mockDSC)];
        priceFeedAddresses = [ethUSDPriceFeed];
        vm.prank(owner);
        DSCEngine mockDSCe = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDSC.transferOwnership(address(mockDSCe));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDSC)).approve(address(mockDSCe), AMOUNT_COLLATERAL);
        // Act / Assert
        mockDSCe.depositCollateral(address(mockDSC), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDSCe.redeemCollateral(address(mockDSC), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscE.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        uint256 userBalBeforeRedeem = dscE.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalBeforeRedeem, AMOUNT_COLLATERAL);
        dscE.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalAfterRedeem = dscE.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalAfterRedeem, 0);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dscE));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dscE.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    /////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscE), AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dscE.redeemCollateralForDsc(weth, 0, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        dsc.approve(address(dscE), AMOUNT_TO_MINT);
        dscE.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /////////////////////////
    // healthFactor Tests //
    ///////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 actualHealthFactor = dscE.getHealthFactor(USER);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHeakthFactor = dscE.getHealthFactor(USER);
        assert(userHeakthFactor == 0.9 ether);
    }

    ////////////////////////
    // Liquidation Tests //
    //////////////////////

    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDSC = new MockMoreDebtDSC(ethUSDPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUSDPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDSCe = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDSC));
        mockDSC.transferOwnership(address(mockDSCe));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDSCe), AMOUNT_COLLATERAL);
        mockDSCe.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDSCe), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDSCe.depositCollateralAndMintDSC(weth, collateralToCover, AMOUNT_TO_MINT);
        mockDSC.approve(address(mockDSCe), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDSCe.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscE), collateralToCover);
        dscE.depositCollateralAndMintDSC(weth, collateralToCover, AMOUNT_TO_MINT);
        dsc.approve(address(dscE), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOkay.selector);
        dscE.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        int256 ethUSDUpdatedPrice = 18e8;

        MockV3Aggregator(ethUSDPriceFeed).updateAnswer(ethUSDUpdatedPrice);
        uint256 userHealthFactor = dscE.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscE), collateralToCover);
        dscE.depositCollateralAndMintDSC(weth, collateralToCover, AMOUNT_TO_MINT);
        dsc.approve(address(dscE), AMOUNT_TO_MINT);
        dscE.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        uint256 amountLiquidated = dscE.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (
                dscE.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) * dscE.getLiquidationBonus()
                    / dscE.getLiquidationPrecision()
            );
        uint256 usdAmountLiquidated = dscE.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dscE.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscE.getAccountDetails(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscE.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (
                dscE.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) * dscE.getLiquidationBonus()
                    / dscE.getLiquidationPrecision()
            );
        uint256 hardCodedExpectedWeth = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpectedWeth);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorsMintedDSC,) = dscE.getAccountDetails(liquidator);
        assertEq(liquidatorsMintedDSC, AMOUNT_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 usersMintedDSC,) = dscE.getAccountDetails(USER);
        assertEq(usersMintedDSC, 0);
    }

    /////////////////////////////////
    // View & Pure Function Tests //
    ///////////////////////////////

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dscE.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUSDPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dscE.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dscE.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dscE.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromDetails() public depositedCollateral {
        (, uint256 collateralValue) = dscE.getAccountDetails(USER);
        uint256 expectedCollateralValue = dscE.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dscE.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dscE.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dscE.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dscE.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dscE.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
