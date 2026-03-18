// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Mondeto} from "../src/Mondeto.sol";

contract DeployScript is Script {
    function run() external {
        address usdt = vm.envAddress("USDT_ADDRESS");
        uint256 initialPrice = vm.envUint("INITIAL_PRICE");
        uint256 minPrice = vm.envUint("MIN_PRICE");

        vm.startBroadcast();

        // Deploy implementation
        Mondeto implementation = new Mondeto();
        console.log("Implementation deployed at:", address(implementation));

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            Mondeto.initialize,
            (usdt, initialPrice, minPrice)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));

        // Set land mask — load from environment as comma-separated uint256 values
        // In practice, call setLandMask separately with data from generate_land_mask.py
        // Mondeto(address(proxy)).setLandMask(landMaskData);

        vm.stopBroadcast();
    }
}
