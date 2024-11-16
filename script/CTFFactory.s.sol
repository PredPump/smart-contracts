// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FPMMFactory} from "../src/CTFFactory.sol";
contract CTFFactoryScript is Script {
    FPMMFactory public ctfFactory;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ctfFactory = new FPMMFactory();

        vm.stopBroadcast();
    }
}
