// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

/// Reads and writes deployments/<chainId>.json in the exact shape of SPEC 7.2.
abstract contract DeploymentsFile is Script {
    struct Deployment {
        uint256 chainId;
        address eas;
        address schemaRegistry;
        address kycResolver;
        address receipt;
        string schema;
        bytes32 schemaUID;
        address admin;
        address issuer;
        address auditor;
        address warehouseOwner;
        string demoWarehouseSlug;
        uint256 deployedAtBlock;
    }

    /// Folder for the deployments files. SPEC 7.1 uses "deployments"; tests point it elsewhere so they never race.
    string public deploymentsDir = "deployments";

    function setDeploymentsDir(string calldata dir) external {
        deploymentsDir = dir;
    }

    /// A private key from the environment, with or without the 0x prefix (MetaMask exports 64 hex characters
    /// without it). Any other form is parsed as Foundry normally does.
    function envPrivateKey(string memory name) public view returns (uint256) {
        string memory raw = vm.envString(name);
        return vm.parseUint(bytes(raw).length == 64 ? string.concat("0x", raw) : raw);
    }

    function deploymentsPath(uint256 chainId) public view returns (string memory) {
        return string.concat(deploymentsDir, "/", vm.toString(chainId), ".json");
    }

    function readDeployment(uint256 chainId) public view returns (Deployment memory d) {
        string memory json = vm.readFile(deploymentsPath(chainId));
        d.chainId = vm.parseJsonUint(json, ".chainId");
        d.eas = vm.parseJsonAddress(json, ".eas");
        d.schemaRegistry = vm.parseJsonAddress(json, ".schemaRegistry");
        d.kycResolver = vm.parseJsonAddress(json, ".kycResolver");
        d.receipt = vm.parseJsonAddress(json, ".receipt");
        d.schema = vm.parseJsonString(json, ".schema");
        d.schemaUID = vm.parseJsonBytes32(json, ".schemaUID");
        d.admin = vm.parseJsonAddress(json, ".admin");
        d.issuer = vm.parseJsonAddress(json, ".issuer");
        d.auditor = vm.parseJsonAddress(json, ".auditor");
        d.warehouseOwner = vm.parseJsonAddress(json, ".warehouseOwner");
        d.demoWarehouseSlug = vm.parseJsonString(json, ".demoWarehouseSlug");
        d.deployedAtBlock = vm.parseJsonUint(json, ".deployedAtBlock");
        require(d.chainId == chainId, "deployments file is for another chain");
    }

    /// SPEC 7.2 key order, numbers unquoted, addresses checksummed, schemaUID as 0x hex.
    function toJson(Deployment memory d) public pure returns (string memory) {
        string memory head = string.concat(
            '{"chainId":',
            vm.toString(d.chainId),
            ',"eas":"',
            vm.toString(d.eas),
            '","schemaRegistry":"',
            vm.toString(d.schemaRegistry),
            '","kycResolver":"',
            vm.toString(d.kycResolver),
            '","receipt":"',
            vm.toString(d.receipt),
            '","schema":"',
            d.schema,
            '","schemaUID":"',
            vm.toString(d.schemaUID)
        );
        string memory tail = string.concat(
            '","admin":"',
            vm.toString(d.admin),
            '","issuer":"',
            vm.toString(d.issuer),
            '","auditor":"',
            vm.toString(d.auditor),
            '","warehouseOwner":"',
            vm.toString(d.warehouseOwner),
            '","demoWarehouseSlug":"',
            d.demoWarehouseSlug,
            '","deployedAtBlock":',
            vm.toString(d.deployedAtBlock),
            "}"
        );
        return string.concat(head, tail);
    }
}
