// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/BitsGuardVestingVault.sol";

contract DeployBitGuardVestingVault is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        new BitGuardVestingVault(deployer);
    }
}
