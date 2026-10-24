// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {EAS} from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";
import {SchemaRegistry} from "@ethereum-attestation-service/eas-contracts/contracts/SchemaRegistry.sol";
import {IEAS} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {ISchemaRegistry} from "@ethereum-attestation-service/eas-contracts/contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/ISchemaResolver.sol";
import {KrsiKycResolver} from "../src/KrsiKycResolver.sol";
import {KrsiReceipt} from "../src/KrsiReceipt.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";
import {DeploymentsFile} from "./lib/DeploymentsFile.sol";

/// SPEC 7.1. Env: PRIVATE_KEY (admin), ISSUER_ADDRESS, AUDITOR_ADDRESS, WAREHOUSE_OWNER_ADDRESS, DEMO_WAREHOUSE_SLUG.
/// forge script script/Deploy.s.sol --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
contract Deploy is DeploymentsFile {
    string public constant SCHEMA = "bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt";
    uint256 public constant ARBITRUM_SEPOLIA = 421614;
    uint256 public constant LOCAL = 31337;
    address public constant ARBITRUM_SEPOLIA_EAS = 0x2521021fc8BF070473E1e1801D3c7B4aB701E1dE;
    address public constant ARBITRUM_SEPOLIA_SCHEMA_REGISTRY = 0x45CB6Fa0870a8Af06796Ac15915619a0f22cd475;

    struct Config {
        uint256 adminKey;
        address issuer;
        address auditor;
        address warehouseOwner;
        string demoWarehouseSlug;
    }

    function run() external returns (Deployment memory d) {
        d = deploy(configFromEnv());
        // A dry run must not leave a deployments file for contracts that do not exist.
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("Dry run: not writing", deploymentsPath(d.chainId));
            console2.log(toJson(d));
            return d;
        }
        vm.writeFile(deploymentsPath(d.chainId), toJson(d));
    }

    function configFromEnv() public view returns (Config memory) {
        return Config({
            adminKey: envPrivateKey("PRIVATE_KEY"),
            issuer: vm.envAddress("ISSUER_ADDRESS"),
            auditor: vm.envAddress("AUDITOR_ADDRESS"),
            warehouseOwner: vm.envAddress("WAREHOUSE_OWNER_ADDRESS"),
            demoWarehouseSlug: vm.envString("DEMO_WAREHOUSE_SLUG")
        });
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        require(c.issuer != address(0) && c.auditor != address(0) && c.warehouseOwner != address(0), "zero address");
        require(KrsiEncoding.isValidShortString(c.demoWarehouseSlug), "bad DEMO_WAREHOUSE_SLUG");
        d.chainId = block.chainid;
        d.admin = vm.addr(c.adminKey);
        d.issuer = c.issuer;
        d.auditor = c.auditor;
        d.warehouseOwner = c.warehouseOwner;
        d.demoWarehouseSlug = c.demoWarehouseSlug;
        d.schema = SCHEMA;
        // The script runs against this block; the deployment lands in it or a later one, so log queries can start here.
        if (d.chainId == ARBITRUM_SEPOLIA) {
            require(ARBITRUM_SEPOLIA_EAS.code.length > 0 && ARBITRUM_SEPOLIA_SCHEMA_REGISTRY.code.length > 0, "no EAS");
            // On Arbitrum, block.number is the L1 block number; log queries need the L2 one from the RPC.
            d.deployedAtBlock = latestL2Block();
        } else {
            require(d.chainId == LOCAL, "unsupported chain");
            d.deployedAtBlock = block.number;
        }

        vm.startBroadcast(c.adminKey);
        if (d.chainId == ARBITRUM_SEPOLIA) {
            d.eas = ARBITRUM_SEPOLIA_EAS;
            d.schemaRegistry = ARBITRUM_SEPOLIA_SCHEMA_REGISTRY;
        } else {
            SchemaRegistry registry = new SchemaRegistry();
            d.schemaRegistry = address(registry);
            d.eas = address(new EAS(registry));
        }
        KrsiKycResolver resolver = new KrsiKycResolver(IEAS(d.eas), c.issuer, d.admin);
        d.kycResolver = address(resolver);
        d.schemaUID = ISchemaRegistry(d.schemaRegistry).register(SCHEMA, ISchemaResolver(address(resolver)), true);
        resolver.setSchema(d.schemaUID);
        KrsiReceipt receipt = new KrsiReceipt(d.admin, resolver);
        d.receipt = address(receipt);
        receipt.grantRole(keccak256("AUDITOR_ROLE"), c.auditor);
        receipt.setWarehouseOwner(c.demoWarehouseSlug, c.warehouseOwner);
        vm.stopBroadcast();
    }

    function latestL2Block() public returns (uint256 n) {
        bytes memory raw = vm.rpc("eth_blockNumber", "[]");
        for (uint256 i = 0; i < raw.length; ++i) {
            n = (n << 8) | uint8(raw[i]);
        }
    }
}
