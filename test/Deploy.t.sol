// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EAS} from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";
import {IEAS, Attestation} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {ISchemaRegistry, SchemaRecord} from "@ethereum-attestation-service/eas-contracts/contracts/ISchemaRegistry.sol";
import {KrsiKycResolver} from "../src/KrsiKycResolver.sol";
import {KrsiReceipt} from "../src/KrsiReceipt.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {IssueKyc} from "../script/IssueKyc.s.sol";
import {RevokeKyc} from "../script/RevokeKyc.s.sol";
import {DeploymentsFile} from "../script/lib/DeploymentsFile.sol";

/// Phase 3 tests 1 to 4: the deploy, IssueKyc and RevokeKyc logic on chain 31337.
contract DeployTest is Test {
    string internal constant SLUG = "agri-vault";
    uint64 internal constant VERIFIED_AT = 1792540800; // GET /api/kyc verifiedAt of the sample, rounded down

    address internal admin;
    uint256 internal adminKey;
    address internal issuer;
    uint256 internal issuerKey;
    address internal auditor = makeAddr("auditor");
    address internal warehouseOwner = makeAddr("warehouseOwner");
    address internal farmer = makeAddr("farmer");

    Deploy internal deployer;

    function setUp() public {
        vm.warp(1792713600); // 2026 10 23
        vm.roll(1234);
        (admin, adminKey) = makeAddrAndKey("admin");
        (issuer, issuerKey) = makeAddrAndKey("issuer");
        deployer = new Deploy();
    }

    function config() internal view returns (Deploy.Config memory) {
        return Deploy.Config({
            adminKey: adminKey,
            issuer: issuer,
            auditor: auditor,
            warehouseOwner: warehouseOwner,
            demoWarehouseSlug: SLUG
        });
    }

    function farmerParams() internal view returns (IssueKyc.Params memory) {
        return IssueKyc.Params({
            userId: 101,
            role: KrsiEncoding.ROLE_FARMER,
            provider: KrsiEncoding.PROVIDER_DEMO,
            wallet: farmer,
            kycVerifiedAt: VERIFIED_AT
        });
    }

    function setEnvForScripts() internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(adminKey))); // with 0x
        vm.setEnv("ISSUER_ADDRESS", vm.toString(issuer));
        vm.setEnv("AUDITOR_ADDRESS", vm.toString(auditor));
        vm.setEnv("WAREHOUSE_OWNER_ADDRESS", vm.toString(warehouseOwner));
        vm.setEnv("DEMO_WAREHOUSE_SLUG", SLUG);
        // As MetaMask exports it: 64 hex characters without 0x
        vm.setEnv("ISSUER_PRIVATE_KEY", vm.replace(vm.toString(bytes32(issuerKey)), "0x", ""));
        vm.setEnv("USER_ID", "101");
        vm.setEnv("ROLE", "1");
        vm.setEnv("PROVIDER", "DEMO");
        vm.setEnv("WALLET", vm.toString(farmer));
        vm.setEnv("KYC_VERIFIED_AT", vm.toString(uint256(VERIFIED_AT)));
    }

    // ---------- 1 and 2: deploy ----------

    function test_Deploy_WiresEverything() public {
        DeploymentsFile.Deployment memory d = deployer.deploy(config());
        KrsiKycResolver resolver = KrsiKycResolver(payable(d.kycResolver));
        KrsiReceipt receipt = KrsiReceipt(d.receipt);

        assertEq(d.chainId, 31337);
        assertGt(d.eas.code.length, 0);
        assertEq(address(EAS(d.eas).getSchemaRegistry()), d.schemaRegistry);
        assertEq(resolver.issuer(), issuer);
        assertEq(resolver.owner(), admin);
        assertEq(d.schemaUID, keccak256(abi.encodePacked(d.schema, d.kycResolver, true)));
        assertEq(resolver.schemaUID(), d.schemaUID);

        SchemaRecord memory record = ISchemaRegistry(d.schemaRegistry).getSchema(d.schemaUID);
        assertEq(record.schema, "bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt");
        assertEq(address(record.resolver), d.kycResolver);
        assertTrue(record.revocable);

        assertTrue(receipt.hasRole(receipt.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(receipt.kyc()), d.kycResolver);
        assertTrue(receipt.hasRole(receipt.AUDITOR_ROLE(), auditor));
        assertFalse(receipt.hasRole(receipt.AUDITOR_ROLE(), admin));
        assertEq(receipt.warehouseOwnerOf(keccak256(bytes(SLUG))), warehouseOwner);
        assertEq(d.admin, admin);
        assertEq(d.deployedAtBlock, 1234);
    }

    function test_Deploy_WritesDeploymentsJson() public {
        setEnvForScripts();
        DeploymentsFile.Deployment memory d = deployer.run();
        string memory json = vm.readFile("deployments/31337.json");

        assertEq(json, deployer.toJson(d)); // the exact SPEC 7.2 key order
        assertEq(vm.parseJsonKeys(json, "$").length, 13);
        assertEq(vm.parseJsonUint(json, ".chainId"), 31337);
        assertEq(vm.parseJsonAddress(json, ".eas"), d.eas);
        assertEq(vm.parseJsonAddress(json, ".schemaRegistry"), d.schemaRegistry);
        assertEq(vm.parseJsonAddress(json, ".kycResolver"), d.kycResolver);
        assertEq(vm.parseJsonAddress(json, ".receipt"), d.receipt);
        assertEq(
            vm.parseJsonString(json, ".schema"), "bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt"
        );
        assertEq(vm.parseJsonBytes32(json, ".schemaUID"), KrsiKycResolver(payable(d.kycResolver)).schemaUID());
        assertEq(vm.parseJsonAddress(json, ".admin"), admin);
        assertEq(vm.parseJsonAddress(json, ".issuer"), KrsiKycResolver(payable(d.kycResolver)).issuer());
        assertEq(vm.parseJsonAddress(json, ".auditor"), auditor);
        assertEq(vm.parseJsonAddress(json, ".warehouseOwner"), warehouseOwner);
        assertEq(vm.parseJsonString(json, ".demoWarehouseSlug"), SLUG);
        assertEq(vm.parseJsonUint(json, ".deployedAtBlock"), 1234);
        assertEq(address(KrsiReceipt(d.receipt).kyc()), vm.parseJsonAddress(json, ".kycResolver"));
    }

    // ---------- 3 and 4: IssueKyc and RevokeKyc ----------

    function test_IssueKycScript_UsesEncodingLibrary() public {
        DeploymentsFile.Deployment memory d = deployer.deploy(config());
        IssueKyc script = new IssueKyc();
        bytes32 uid = script.issue(IEAS(d.eas), d.schemaUID, issuerKey, farmerParams());

        Attestation memory a = IEAS(d.eas).getAttestation(uid);
        bytes memory expected =
            KrsiEncoding.kycData(KrsiEncoding.userRef(101), 1, KrsiEncoding.PROVIDER_DEMO, VERIFIED_AT);
        assertEq(a.data, expected);
        assertEq(a.expirationTime, uint64(block.timestamp) + 365 days);
        assertEq(a.attester, issuer);
        assertEq(a.recipient, farmer);
        assertTrue(a.revocable);
        assertEq(a.schema, d.schemaUID);

        KrsiKycResolver resolver = KrsiKycResolver(payable(d.kycResolver));
        assertTrue(resolver.isVerified(farmer));
        assertEq(resolver.getKyc(farmer).kycVerifiedAt, VERIFIED_AT);
        assertEq(resolver.verifiedWalletOf(KrsiEncoding.userRef(101)), farmer);
    }

    function test_IssueKycScript_RejectsBadInputs() public {
        DeploymentsFile.Deployment memory d = deployer.deploy(config());
        IssueKyc script = new IssueKyc();
        assertEq(script.providerFromName("SETU_DIGILOCKER"), KrsiEncoding.PROVIDER_SETU);
        assertEq(script.providerFromName("DEMO"), KrsiEncoding.PROVIDER_DEMO);
        vm.expectRevert("PROVIDER must be SETU_DIGILOCKER or DEMO");
        script.providerFromName("setu");

        IssueKyc.Params memory p = farmerParams();
        p.kycVerifiedAt = uint64(block.timestamp) + 1;
        vm.expectRevert("KYC_VERIFIED_AT must be a past time");
        script.issue(IEAS(d.eas), d.schemaUID, issuerKey, p);
        p.kycVerifiedAt = 0;
        vm.expectRevert("KYC_VERIFIED_AT must be a past time");
        script.issue(IEAS(d.eas), d.schemaUID, issuerKey, p);
    }

    function test_RevokeKycScript_Unverifies() public {
        DeploymentsFile.Deployment memory d = deployer.deploy(config());
        bytes32 uid = new IssueKyc().issue(IEAS(d.eas), d.schemaUID, issuerKey, farmerParams());
        KrsiKycResolver resolver = KrsiKycResolver(payable(d.kycResolver));
        assertTrue(resolver.isVerified(farmer));

        bytes32 revoked = new RevokeKyc().revoke(IEAS(d.eas), resolver, d.schemaUID, issuerKey, farmer);
        assertEq(revoked, uid);
        assertFalse(resolver.isVerified(farmer));
        assertEq(resolver.uidOf(farmer), bytes32(0));
        assertGt(IEAS(d.eas).getAttestation(uid).revocationTime, 0);

        RevokeKyc again = new RevokeKyc();
        vm.expectRevert("WALLET has no linked attestation");
        again.revoke(IEAS(d.eas), resolver, d.schemaUID, issuerKey, farmer);
    }

    // ---------- extra: the env and file paths the presenter uses ----------

    function test_Scripts_RunFromEnvAndDeploymentsFile() public {
        setEnvForScripts();
        vm.createDir("deployments/test/e2e", true);
        deployer.setDeploymentsDir("deployments/test/e2e");
        DeploymentsFile.Deployment memory d = deployer.run();

        IssueKyc issueScript = new IssueKyc();
        issueScript.setDeploymentsDir("deployments/test/e2e");
        bytes32 uid = issueScript.run();
        KrsiKycResolver resolver = KrsiKycResolver(payable(d.kycResolver));
        assertEq(resolver.uidOf(farmer), uid);
        assertEq(resolver.getKyc(farmer).role, 1);
        assertEq(resolver.getKyc(farmer).provider, KrsiEncoding.PROVIDER_DEMO);

        RevokeKyc revokeScript = new RevokeKyc();
        revokeScript.setDeploymentsDir("deployments/test/e2e");
        assertEq(revokeScript.run(), uid);
        assertFalse(resolver.isVerified(farmer));
    }
}
