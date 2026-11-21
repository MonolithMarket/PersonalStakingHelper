// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYearnVaultRegistry {
    function vaultInfo(address vault)
        external
        view
        returns (
            address asset,
            uint96 releaseVersion,
            uint64 vaultType,
            uint128 deploymentTimestamp,
            uint64 index,
            string memory tag
        );
}
