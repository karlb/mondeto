// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {Mondeto} from "../src/Mondeto.sol";

contract UpgradeScript is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        Mondeto current = Mondeto(proxy);

        vm.startBroadcast();

        // Deploy new implementation with same constructor args
        Mondeto newImpl = new Mondeto(current.WIDTH(), current.HEIGHT());
        console.log("New implementation deployed at:", address(newImpl));

        // Upgrade proxy to new implementation
        Mondeto(proxy).upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded:", proxy);

        vm.stopBroadcast();
    }
}
