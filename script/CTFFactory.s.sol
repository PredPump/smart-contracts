// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FPMMFactory} from "../src/CTFFactory.sol";
import {ERC20Mock} from "../src/ERC20Mock.sol";

contract CTFFactoryScript is Script {
    FPMMFactory public ctfFactory;
    ERC20Mock public collateralToken;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ctfFactory = new FPMMFactory();
        collateralToken = new ERC20Mock("MockUSDC", "USDC");

        console.log("CTFFactory deployed at", address(ctfFactory));
        console.log("Collateral token deployed at", address(collateralToken));

        vm.stopBroadcast();
    }
}
