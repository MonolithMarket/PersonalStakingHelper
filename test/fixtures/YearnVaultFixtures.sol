// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IYearnVaultRegistry} from "../../src/interfaces/IYearnVaultRegistry.sol";

contract YearnVaultRegistryFixture is IYearnVaultRegistry {
    mapping(address => address) private assets;
    mapping(address => uint64) private types;

    function setVault(address vault, address asset, uint64 vaultType) external {
        assets[vault] = asset;
        types[vault] = vaultType;
    }

    function vaultInfo(address vault) external view returns (address, uint96, uint64, uint128, uint64, string memory) {
        return (assets[vault], 0, types[vault], 0, 0, "");
    }
}

contract CompoundVaultFixture is ERC4626 {
    uint256 public depositLimit = type(uint256).max;

    constructor(IERC20 asset_) ERC20("Yearn Vault", "yvGOV") ERC4626(asset_) {}

    function setDepositLimit(uint256 limit) external {
        depositLimit = limit;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositLimit;
    }
}
