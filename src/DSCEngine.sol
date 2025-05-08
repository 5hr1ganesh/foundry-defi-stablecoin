// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DSCEngine
 * @author Shriganesh
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC tokens,
 * as well as depositing & withdrawing collateral.
 * @dev This contract is VERY loosely based on the MakerDAO DSS(DAI) system.
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
 * @dev our DSC system should always be "over-collateralized". At no point, should the value of all collateral be <= the value of all DSC tokens minted.
 */
contract DSCEngine is ReentrancyGuard, Ownable {
    /////////////////
    // Errors //////
    ///////////////
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressLengthMisMatch();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TokenFrozen();
    error DSCEngine__TransferFailed();
    error DSCEngine__LowHealthFactor(uint256 healthfactorValue);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__SystemFrozen();
    error DSCEngine__PriceDropTooLarge();
    error DSCEngine__PriceCheckTooSoon();

    ////////////////
    // Types //////
    //////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////////
    // State Variables /////
    ///////////////////////
    /// @notice Precision factor for price feed calculations
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    /// @notice General precision factor for calculations
    uint256 private constant PRECISION = 1e18;
    /// @notice Threshold for liquidation (50% = 200% collateralization required)
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    /// @notice Precision factor for liquidation calculations
    uint256 private constant LIQUIDATION_PRECISION = 100;
    /// @notice Minimum health factor required for operations
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    /// @notice Bonus percentage for liquidators
    uint256 private constant LIQUIDATION_BONUS = 10;
    /// @notice Minimum duration for which the system must remain frozen
    uint256 private constant MINIMUM_FREEZE_DURATION = 24 hours;
    /// @notice Number of tokens that need to be frozen to freeze the entire system
    uint256 private constant TOKEN_FREEZE_THRESHOLD = 2;

    /// @notice Flag indicating if the entire system is frozen
    bool private s_systemFrozen;
    /// @notice Maximum allowed price drop percentage before freezing
    uint256 private s_maxPriceDropPercentage;
    /// @notice Time interval between price drop checks
    uint256 private s_priceDropCheckInterval;
    /// @notice Timestamp when the system was frozen
    uint256 private s_freezeTimeStamp;
    /// @notice Count of currently frozen tokens
    uint256 private s_frozenTokenCount;

    /// @notice Mapping of token addresses to their price feed addresses
    mapping(address token => address priceFeed) private s_priceFeeds;
    /// @notice Mapping of user addresses to their deposited collateral amounts per token
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    /// @notice Mapping of user addresses to their minted DSC amounts
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    /// @notice Mapping of token addresses to their last known prices
    mapping(address token => uint256) private s_lastKnownPrice;
    /// @notice Mapping of token addresses to their last price check timestamps
    mapping(address token => uint256) private s_lastPriceCheck;
    /// @notice Mapping of token addresses to their frozen status
    mapping(address => bool) private s_tokenFrozen;

    /// @notice Array of all supported collateral token addresses
    address[] private s_collateralTokens;

    /// @notice The DSC token contract instance
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    // Events /////
    //////////////
    /// @notice Emitted when collateral is deposited
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    /// @notice Emitted when collateral is redeemed
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    /// @notice Emitted when the system is frozen
    event SystemFrozen(uint256 frozenTokenCount);
    /// @notice Emitted when a token is frozen
    event TokenFrozen(address indexed token, uint256 lastPrice, uint256 currentPrice, uint256 dropPercentage);
    /// @notice Emitted when the system is unfrozen
    event SystemUnfrozen();

    ////////////////
    // Modifiers //
    //////////////
    /// @notice Ensures the amount is greater than zero
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    /// @notice Ensures the token is supported by the system
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotSupported();
        }
        _;
    }

    /// @notice Ensures the system is not frozen
    modifier whenNotFrozen() {
        if (s_systemFrozen) {
            revert DSCEngine__SystemFrozen();
        }
        _;
    }

    /// @notice Ensures the token is not frozen
    modifier tokenFrozenCheck(address _tokenAddress) {
        if (s_tokenFrozen[_tokenAddress] == true) {
            revert DSCEngine__TokenFrozen();
        }
        _;
    }

    ////////////////
    // Functions ///
    //////////////
    /**
     * @notice Constructor for the DSCEngine contract
     * @param tokenAddresses Array of collateral token addresses
     * @param priceFeedAddresses Array of price feed addresses corresponding to the collateral tokens
     * @param dscAddress Address of the DSC token contract
     */
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

    /**
     * @notice Updates the system parameters for price drop monitoring
     * @param newMaxPriceDrop New maximum allowed price drop percentage
     * @param newCheckInterval New time interval between price checks
     */
    function updateParameters(uint256 newMaxPriceDrop, uint256 newCheckInterval) external onlyOwner {
        require(newMaxPriceDrop <= 50, "Drop percentage too high");
        require(newCheckInterval >= 1 hours, "Interval too low");
        s_maxPriceDropPercentage = newMaxPriceDrop;
        s_priceDropCheckInterval = newCheckInterval;
    }

    /**
     * @notice Checks if a token's price has dropped significantly
     * @param token Address of the token to check
     * @return bool True if the token should be frozen, false otherwise
     */
    function checkPriceDrop(address token) public tokenFrozenCheck(token) returns (bool) {
        if (block.timestamp - s_lastPriceCheck[token] < s_priceDropCheckInterval) {
            revert DSCEngine__PriceCheckTooSoon();
        }

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 currentPrice,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 lastPrice = s_lastKnownPrice[token];
        if (lastPrice == 0) {
            s_lastKnownPrice[token] = uint256(currentPrice);
            s_lastPriceCheck[token] = block.timestamp;
            return false;
        }

        uint256 priceDropPercentage = ((lastPrice - uint256(currentPrice)) * 100) / lastPrice;

        if (priceDropPercentage >= s_maxPriceDropPercentage) {
            s_tokenFrozen[token] = true;
            s_frozenTokenCount++;
            emit TokenFrozen(token, lastPrice, uint256(currentPrice), priceDropPercentage);

            if (s_frozenTokenCount >= TOKEN_FREEZE_THRESHOLD && !s_systemFrozen) {
                s_systemFrozen = true;
                s_freezeTimeStamp = block.timestamp;
                emit SystemFrozen(s_frozenTokenCount);
            }
            return true;
        }

        s_lastKnownPrice[token] = uint256(currentPrice);
        s_lastPriceCheck[token] = block.timestamp;
        return false;
    }

    /**
     * @notice Unfreezes a specific token if its price has recovered
     * @param token Address of the token to unfreeze
     */
    function unFreezeToken(address token) external onlyOwner {
        require(s_tokenFrozen[token], "Token not frozen");
        require(checkPriceRecovery(token), "Price not recovered");

        s_tokenFrozen[token] = false;
        s_frozenTokenCount--;

        if (s_frozenTokenCount == 0 && s_systemFrozen) {
            s_systemFrozen = false;
            emit SystemUnfrozen();
        }
    }

    /**
     * @notice Unfreezes the entire system if all conditions are met
     */
    function unFreezeSystem() external onlyOwner {
        require(s_systemFrozen, "System not Frozen");
        require(block.timestamp >= s_freezeTimeStamp + MINIMUM_FREEZE_DURATION, "Too early to unfreeze");

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            if (s_tokenFrozen[token]) {
                require(checkPriceRecovery(token), "Price not recovered");
            }
        }

        s_systemFrozen = false;
        s_frozenTokenCount = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            s_tokenFrozen[s_collateralTokens[i]] = false;
        }
        emit SystemUnfrozen();
    }

    /**
     * @notice Checks if a token's price has recovered to a safe level
     * @param token Address of the token to check
     * @return bool True if the price has recovered, false otherwise
     */
    function checkPriceRecovery(address token) internal view returns (bool) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 currentPrice,,,) = priceFeed.staleCheckLatestRoundData();

        uint256 lastknownPrice = s_lastKnownPrice[token];
        uint256 recoveryThreshold = (lastknownPrice * 90) / 100;

        return uint256(currentPrice) >= recoveryThreshold;
    }

    /**
     * @notice Deposits collateral and mints DSC in a single transaction
     * @param collateralTokenAddress Address of the collateral token
     * @param collateralAmount Amount of collateral to deposit
     * @param amountDSCToMint Amount of DSC to mint
     */
    function depositCollateralAndMintDSC(
        address collateralTokenAddress,
        uint256 collateralAmount,
        uint256 amountDSCToMint
    ) external whenNotFrozen tokenFrozenCheck(collateralTokenAddress) {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDSC(amountDSCToMint);
    }

    /**
     * @notice Redeems collateral by burning DSC
     * @param collateralTokenAddress Address of the collateral token to redeem
     * @param collateralAmount Amount of collateral to redeem
     * @param dscToBurnAmount Amount of DSC to burn
     */
    function redeemCollateralForDsc(address collateralTokenAddress, uint256 collateralAmount, uint256 dscToBurnAmount)
        external
        moreThanZero(collateralAmount)
        isAllowedToken(collateralTokenAddress)
        tokenFrozenCheck(collateralTokenAddress)
        whenNotFrozen
    {
        _burnDSC(dscToBurnAmount, msg.sender, msg.sender);
        _redeemCollateral(collateralTokenAddress, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    /**
     * @notice Redeems collateral without burning DSC
     * @param collateralTokenAddress Address of the collateral token to redeem
     * @param collateralAmount Amount of collateral to redeem
     */
    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount)
        external
        moreThanZero(collateralAmount)
        nonReentrant
        whenNotFrozen
    {
        _redeemCollateral(collateralTokenAddress, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    /**
     * @notice Burns DSC tokens
     * @param dscAmount Amount of DSC to burn
     */
    function burnDSC(uint256 dscAmount) external moreThanZero(dscAmount) whenNotFrozen {
        _burnDSC(dscAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    /**
     * @notice Liquidates a user's position if their health factor is below threshold
     * @param collateral Address of the collateral token to liquidate
     * @param user Address of the user to liquidate
     * @param debtToCover Amount of DSC debt to cover
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
        whenNotFrozen
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }

        uint256 collateralFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
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

    /**
     * @notice Deposits collateral into the system
     * @param collateralTokenAddress Address of the collateral token
     * @param collateralAmount Amount of collateral to deposit
     */
    function depositCollateral(address collateralTokenAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
        whenNotFrozen
    {
        s_collateralDeposited[msg.sender][collateralTokenAddress] =
            s_collateralDeposited[msg.sender][collateralTokenAddress] + collateralAmount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Mints new DSC tokens
     * @param amountDSCToMint Amount of DSC to mint
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant whenNotFrozen {
        s_DSCMinted[msg.sender] = s_DSCMinted[msg.sender] + amountDSCToMint;
        _revertIfHealthFactorBelowThreshold(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice Internal function to burn DSC tokens
     * @param amountDSCToBurn Amount of DSC to burn
     * @param onBehalfOf Address on whose behalf to burn
     * @param dscFrom Address from which to burn
     */
    function _burnDSC(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] = s_DSCMinted[onBehalfOf] - amountDSCToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDSCToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDSCToBurn);
    }

    /**
     * @notice Internal function to redeem collateral
     * @param collateralTokenAddress Address of the collateral token
     * @param collateralAmount Amount of collateral to redeem
     * @param from Address from which to redeem
     * @param to Address to which to send the redeemed collateral
     */
    function _redeemCollateral(address collateralTokenAddress, uint256 collateralAmount, address from, address to)
        private
        tokenFrozenCheck(collateralTokenAddress)
    {
        s_collateralDeposited[from][collateralTokenAddress] =
            s_collateralDeposited[from][collateralTokenAddress] - collateralAmount;
        emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmount);

        bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Gets account details for a user
     * @param user Address of the user
     * @return totalDSCMinted Total DSC minted by the user
     * @return totalCollateralValueInUsd Total value of user's collateral in USD
     */
    function _getAccountDetails(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Calculates the health factor for a given amount of DSC and collateral
     * @param totalDSCMinted Total DSC minted
     * @param totalCollateralValueInUsd Total value of collateral in USD
     * @return uint256 Health factor value
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

    /**
     * @notice Gets the health factor for a user
     * @param user Address of the user
     * @return uint256 Health factor value
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 totalCollateralValueInUsd) = _getAccountDetails(user);
        return _calculateHealthFactor(totalDSCMinted, totalCollateralValueInUsd);
    }

    /**
     * @notice Reverts if the user's health factor is below threshold
     * @param user Address of the user to check
     */
    function _revertIfHealthFactorBelowThreshold(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__LowHealthFactor(uint256(userHealthFactor));
        }
    }

    /**
     * @notice Gets the USD value of a token amount
     * @param token Address of the token
     * @param amount Amount of the token
     * @return uint256 Value in USD
     */
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * 1e10) * amount) / 1e18;
    }

    // Public View Functions
    /**
     * @notice Gets the token amount equivalent to a USD amount
     * @param token Address of the token
     * @param usdAmountInWei Amount in USD (in wei)
     * @return uint256 Equivalent token amount
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    /**
     * @notice Gets the total collateral value in USD for a user
     * @param user Address of the user
     * @return totalCollateralValueInUsd Total value in USD
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd = totalCollateralValueInUsd + _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @notice Gets the USD value of a token amount
     * @param token Address of the token
     * @param amount Amount of the token
     * @return uint256 Value in USD
     */
    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    /**
     * @notice Gets the collateral balance of a user for a specific token
     * @param user Address of the user
     * @param token Address of the token
     * @return uint256 Balance of the token
     */
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    /**
     * @notice Calculates the health factor for given DSC and collateral amounts
     * @param totalDscMinted Total DSC minted
     * @param collateralValueInUsd Total collateral value in USD
     * @return uint256 Health factor value
     */
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @notice Gets the account details for a user
     * @param user Address of the user
     * @return totalDSCMinted Total DSC minted
     * @return collateralValueInUsd Total collateral value in USD
     */
    function getAccountDetails(address user)
        external
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        (totalDSCMinted, collateralValueInUsd) = _getAccountDetails(user);
    }

    // Getter functions for constants and state variables
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
