// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// // What are our invariants ?
// // 1. The total supply of DSC should be less than the total value of the collateral
// // 2. Getter view functions should never revert <- evergreen invariant

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
// import {DSCEngine} from "src/DSCEngine.sol";
// import {DeployDSC} from "script/DeployDSC.s.sol";
// import {HelperConfig} from "script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract InvariantTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DecentralizedStableCoin dsc;
//     DSCEngine dscE;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dscE, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dscE));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         //  get the value of all the collateral in the protocol & compare it to all the debt (dsc).
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscE));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscE));

//         uint256 wethValue = dscE.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscE.getUsdValue(wbtc, totalWbtcDeposited);

//         console.log(wethValue, wbtcValue, totalSupply, "Values being compared");

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
