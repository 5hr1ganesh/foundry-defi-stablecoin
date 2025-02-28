// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Shriganesh
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1:1 peg with USD.
 *
 * This Stablecoin has the following features:
 * - Collateral: Exogenous (wETH & wBTC)
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by wETH and wBTC
 *
 * our DSC system should always be "over-collateralized". At no point, should the value of all collateral be <= the value of all DSC tokens minted.
 *
 * @notice This contract is the core if the DSC Systemm. It handles all the logic for minting and redeeming DSC tokens, as well as depositing & withdrawing collateral.
 *
 * @notice This contract is VERY loosely based on the MakerDAO DSS(DAI) system.
 * 
 * @notice upcoming features: Insurance Fund: Establish an insurance fund to cover potential losses and provide additional stability during market downturns.
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////
    // Errors //////
    ///////////////
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressLengthMisMatch();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TransferFailed();
    error DSCEngine__LowHealthFactor(uint256 healthfactorValue);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////
    // Types //////
    //////////////

    using OracleLib for AggregatorV3Interface;

    /////////////////////////
    // State Variables /////
    ///////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Minter Needs to be 200% collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    // Events /////
    //////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    // Modifiers //
    //////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotSupported();
        }
        _;
    }

    ////////////////
    // Function ///
    //////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressLengthMisMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    // External Functions ///
    ////////////////////////

    /*
     * @param collateralTokenAddress The address of the collateral token to be deposited
     * @param collateralAmount The amount of collateral to be deposited
     * @param amountDSCToMint The amount of DSC to mint
     * @notice this function will deposit collateral and mint DSC in a single transaction
     */
    function depositCollateralAndMintDSC(
        address collateralTokenAddress,
        uint256 collateralAmount,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDSC(amountDSCToMint);
    }

    /*
     * @param collateralTokenAddress The collateral address to redeem
     * @param collateralAmount The amount of collateral to redeem
     * @param dsToBurnAmoun The amount of DSC to burn
     * This function will burn dsc and redeem underlying collateral in one transaction
     * */

    // function redeemCollateralForDsc(
    //         address tokenCollateralAddress,
    //         uint256 amountCollateral,
    //         uint256 amountDscToBurn
    //     )
    //         external
    //         moreThanZero(amountCollateral)
    //         isAllowedToken(tokenCollateralAddress)
    //     {
    //         _burnDsc(amountDscToBurn, msg.sender, msg.sender);
    //         _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
    //         revertIfHealthFactorIsBroken(msg.sender);
    //     }

    function redeemCollateralForDsc(address collateralTokenAddress, uint256 collateralAmount, uint256 dscToBurnAmount)
        external
        moreThanZero(collateralAmount)
        isAllowedToken(collateralTokenAddress)
    {
        _burnDSC(dscToBurnAmount, msg.sender, msg.sender);
        _redeemCollateral(collateralTokenAddress, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount)
        external
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(collateralTokenAddress, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    function burnDSC(uint256 dscAmount) external moreThanZero(dscAmount) {
        _burnDSC(dscAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    /*
     * @param collateral The erc20collateral address to liquidate
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC needed to burn in order to imorove the user's health factor
     * @notice You can Partially liquidate a user.
     * @notice You can get a liquidation bonus for taking the user's funds
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize liquidators.
     * For example, if the price of the collateral plummeted  before anyone could be liquidated.
     *
     * Follows CEI
     * */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }
        // We want to burn their DSC "debt" and take their collsteral
        // Bad User: $140 ETH for $100 DSC
        // debtToCover = $100
        // $100 of DSC == ?
        uint256 collateralFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give liquidators a 10% bonus
        // So we are giving the liquidator $110 of wETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (collateralFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = collateralFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    ////////////////////////
    // Public Functions ///
    ////////////////////////

    /*
     * @notice follows CEI pattern
     * @param collateralTokenAddress The address of the collateral token to be deposited
     * @param collateralAmount The amount of collateral to be deposited
     * */

    function depositCollateral(address collateralTokenAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralTokenAddress] =
            s_collateralDeposited[msg.sender][collateralTokenAddress] + collateralAmount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @notice follows CEI pattern
     * @param amountDSCToMint The amount of DSC to mint
     * @notice they must have more collateral than the value of DSC they are minting & the more than the min amount required collateral.
     * */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] = s_DSCMinted[msg.sender] + amountDSCToMint;
        // if user minted too much DSC($150 DSC for $100 ETH) then revert
        _revertIfHealthFactorBelowThreshold(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint); // mint DSC
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    ////////////////////////
    // Private Functions //
    //////////////////////

    /*
     * @dev Low-level internal function to burn DSC, do not call directly
     * and make sure the function calling it checks for health factor
     *  */
    function _burnDSC(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] = s_DSCMinted[onBehalfOf] - amountDSCToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    function _redeemCollateral(address collateralTokenAddress, uint256 collateralAmount, address from, address to)
        private
    {
        // if (s_collateralDeposited[from][collateralTokenAddress] >= collateralAmount) {
        //     revert DSCEngine__TransferFailed();
        // }

        s_collateralDeposited[from][collateralTokenAddress] =
            s_collateralDeposited[from][collateralTokenAddress] - collateralAmount;
        emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmount);

        // _calculateHealthFactor();
        bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    ///////////////////////////////////////////////
    // Private & Internal View & Pure Functions //
    /////////////////////////////////////////////

    function _getAccountDetails(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can be liquidated
     */
    function _calculateHealthFactor(uint256 totalDSCMinted, uint256 totalCollateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _healthFactor(address user) private view returns (uint256) {
        // 1. get Total DSC minted
        // 2. get Total Collateral VALUE deposited
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd) = _getAccountDetails(user);
        return _calculateHealthFactor(totalDSCMinted, totalCollateralValueInUsd);
    }

    function _revertIfHealthFactorBelowThreshold(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__LowHealthFactor(uint256(userHealthFactor));
        }
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * 1e10) * amount) / 1e18;
    }

    ///////////////////////////////////////////////
    // Public & External View & Pure Functions ///
    /////////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through each collateral token, get the amount they have deposited, and map it to
        // the price feed to get the value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd = totalCollateralValueInUsd + _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountDetails(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        (totalDSCMinted, collateralValueInUsd) = _getAccountDetails(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getHealthFactorThreshold() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
