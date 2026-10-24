// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {
    IEAS,
    AttestationRequest,
    AttestationRequestData,
    RevocationRequest,
    RevocationRequestData
} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {ISchemaRegistry, SchemaRecord} from "@ethereum-attestation-service/eas-contracts/contracts/ISchemaRegistry.sol";
import {ISemver} from "@ethereum-attestation-service/eas-contracts/contracts/ISemver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC7943NonFungible} from "../src/interfaces/IERC7943NonFungible.sol";
import {KrsiKycResolver} from "../src/KrsiKycResolver.sol";
import {KrsiReceipt} from "../src/KrsiReceipt.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeploymentsFile} from "../script/lib/DeploymentsFile.sol";

/// Phase 3 tests 5 and 6, against a fork of Arbitrum Sepolia and the real deployment in deployments/421614.json.
/// Skipped with a message when ARB_SEPOLIA_RPC_URL or the deployments file is missing.
/// The demo flow uses fresh test wallets, user ids and token ids, so it never collides with the live demo data.
contract ForkDemoTest is Test {
    string internal constant SCHEMA = "bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt";
    uint256 internal constant PARENT = 900_000_006;
    uint256 internal constant CHILD = 900_000_007;

    string internal skipReason; // why tests 5 and 6 cannot run
    string internal rpcMissing; // why the rehearsal cannot run
    DeploymentsFile.Deployment internal d;
    IEAS internal eas;
    KrsiKycResolver internal resolver;
    KrsiReceipt internal receipt;

    function setUp() public {
        string memory rpc = vm.envOr("ARB_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpcMissing = "ARB_SEPOLIA_RPC_URL is not set";
            skipReason = rpcMissing;
            return;
        }
        vm.createSelectFork(rpc);
        if (!vm.exists("deployments/421614.json")) {
            skipReason = "deployments/421614.json is missing (run script/Deploy.s.sol on Arbitrum Sepolia first)";
            return;
        }
        useDeployment(new Deploy().readDeployment(421614));
    }

    function useDeployment(DeploymentsFile.Deployment memory deployment) internal {
        d = deployment;
        eas = IEAS(d.eas);
        resolver = KrsiKycResolver(payable(d.kycResolver));
        receipt = KrsiReceipt(d.receipt);
    }

    modifier onFork() {
        if (bytes(skipReason).length > 0) {
            console2.log("SKIPPED fork test:", skipReason);
            vm.skip(true);
        }
        _;
    }

    function test_Fork_Wiring() public onFork {
        wiringChecks();
    }

    function wiringChecks() internal {
        assertEq(block.chainid, 421614);
        assertEq(d.eas, 0x2521021fc8BF070473E1e1801D3c7B4aB701E1dE);
        assertEq(d.schemaRegistry, 0x45CB6Fa0870a8Af06796Ac15915619a0f22cd475);
        assertGt(d.eas.code.length, 0);
        assertGt(d.schemaRegistry.code.length, 0);
        assertGt(d.kycResolver.code.length, 0);
        assertGt(d.receipt.code.length, 0);
        assertEq(ISemver(d.eas).version(), "1.3.0");
        assertEq(address(eas.getSchemaRegistry()), d.schemaRegistry);

        SchemaRecord memory record = ISchemaRegistry(d.schemaRegistry).getSchema(d.schemaUID);
        assertEq(record.uid, d.schemaUID);
        assertEq(record.schema, SCHEMA);
        assertEq(address(record.resolver), d.kycResolver);
        assertTrue(record.revocable);
        assertEq(d.schemaUID, keccak256(abi.encodePacked(SCHEMA, d.kycResolver, true)));

        assertEq(resolver.schemaUID(), d.schemaUID);
        assertEq(resolver.issuer(), d.issuer);
        assertEq(resolver.owner(), d.admin);
        assertEq(address(receipt.kyc()), d.kycResolver);
        assertTrue(receipt.hasRole(receipt.DEFAULT_ADMIN_ROLE(), d.admin));
        assertTrue(receipt.hasRole(receipt.AUDITOR_ROLE(), d.auditor));
        assertEq(receipt.warehouseOwnerOf(keccak256(bytes(d.demoWarehouseSlug))), d.warehouseOwner);
        uint256 l2Block = new Deploy().latestL2Block();
        assertGt(d.deployedAtBlock, block.number, "deployedAtBlock must be the L2 block number, not block.number");
        assertLe(d.deployedAtBlock, l2Block);
    }

    function test_Fork_DemoFlow() public onFork {
        demoFlow();
    }

    /// Before the live deployment: Deploy.deploy on a fork with throwaway keys (nothing is broadcast), checked
    /// like test 5, then the same demo flow against the real EAS 1.3.0.
    function test_ForkRehearsal_DeployAndDemoFlow() public {
        if (bytes(rpcMissing).length > 0) {
            console2.log("SKIPPED fork rehearsal:", rpcMissing);
            vm.skip(true);
        }
        (, uint256 adminKey) = makeAddrAndKey("rehearsal admin");
        Deploy deployer = new Deploy();
        useDeployment(
            deployer.deploy(
                Deploy.Config({
                    adminKey: adminKey,
                    issuer: makeAddr("rehearsal issuer"),
                    auditor: makeAddr("rehearsal auditor"),
                    warehouseOwner: makeAddr("rehearsal warehouse owner"),
                    demoWarehouseSlug: "agri-vault"
                })
            )
        );
        console2.log("fork block.number (L1)", block.number, "deployedAtBlock (L2)", d.deployedAtBlock);
        wiringChecks();
        demoFlow();
    }

    function demoFlow() internal {
        address farmer = makeAddr("fork farmer");
        address merchant = makeAddr("fork merchant");
        address extra = makeAddr("fork extra");
        bytes32 farmerRef = KrsiEncoding.userRef(900_101);
        bytes32 merchantRef = KrsiEncoding.userRef(900_102);

        // KYC through the real EAS 1.3.0, signed by the real issuer
        attest(farmer, 900_101, KrsiEncoding.ROLE_FARMER);
        attest(merchant, 900_102, KrsiEncoding.ROLE_MERCHANT);
        bytes32 extraUid = attest(extra, 900_103, KrsiEncoding.ROLE_MERCHANT);
        assertTrue(resolver.isVerified(farmer) && resolver.isVerified(merchant) && resolver.isVerified(extra));
        assertEq(resolver.verifiedWalletOf(farmerRef), farmer);

        // The auditor issues the sample (golden values, dates moved to the fork's today so it is valid)
        uint64 today = uint64(block.timestamp - (block.timestamp % 1 days));
        KrsiReceipt.ReceiptInput memory input = KrsiReceipt.ReceiptInput({
            tokenId: PARENT,
            receiptNo: "ENWR-000006",
            warehouseSlug: d.demoWarehouseSlug,
            commodity: "Coffee",
            grade: "Raw",
            quantityKg: 20000,
            storedOn: today,
            validTill: today + 180 days,
            moistureBps: 1000,
            foreignMatterBps: 100,
            inspectedOn: uint64(block.timestamp),
            inspectionHash: KrsiEncoding.inspectionHash("Fine", uint64(block.timestamp)),
            ledgerHash: 0x89561c5c9b311b531577de5a72ef7afc25a06176216bcdef2b0a6b62ed7928d0
        });
        vm.expectEmit(true, true, true, true, d.receipt);
        emit KrsiReceipt.ReceiptIssued(PARENT, farmer, farmerRef, "ENWR-000006", 20000, input.ledgerHash);
        vm.prank(d.auditor);
        receipt.issue(input, farmerRef);
        assertEq(receipt.ownerOf(PARENT), farmer);

        // Listing locks it; a direct transfer is refused
        vm.prank(farmer);
        receipt.lock(PARENT);
        assertEq(uint8(receipt.stateOf(PARENT)), uint8(KrsiReceipt.State.LISTED));
        vm.prank(farmer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943NonFungible.ERC7943InsufficientUnfrozenBalance.selector, farmer, PARENT)
        );
        receipt.transferFrom(farmer, merchant, PARENT);

        // Accepting a 12 MT bid splits off a child for the merchant
        bytes32 childLedger = 0x713b9a45c68a38ea68c2f51b2c5ae718b25d74158d3329186bb554f364a8fda5;
        vm.expectEmit(true, true, true, true, d.receipt);
        emit KrsiReceipt.ReceiptSplit(PARENT, CHILD, merchant, farmer, 12000, 8000, 2);
        vm.prank(farmer);
        receipt.settle(PARENT, merchantRef, 12000, CHILD, "ENWR-000007", childLedger, 2);
        assertEq(receipt.getReceipt(PARENT).quantityKg, 8000);
        assertEq(uint8(receipt.stateOf(PARENT)), uint8(KrsiReceipt.State.LISTED));
        assertEq(receipt.ownerOf(CHILD), merchant);
        assertEq(receipt.getReceipt(CHILD).quantityKg, 12000);
        assertEq(receipt.getReceipt(CHILD).ledgerHash, childLedger);

        // Revoking a user's KYC stops transfers to them
        vm.expectEmit(true, true, true, true, d.kycResolver);
        emit KrsiKycResolver.KycRevoked(KrsiEncoding.userRef(900_103), extra, extraUid);
        vm.prank(d.issuer);
        eas.revoke(RevocationRequest({schema: d.schemaUID, data: RevocationRequestData({uid: extraUid, value: 0})}));
        assertFalse(resolver.isVerified(extra));
        assertFalse(receipt.canTransfer(merchant, extra, CHILD));
        vm.prank(merchant);
        vm.expectRevert(abi.encodeWithSelector(IERC7943NonFungible.ERC7943CannotReceive.selector, extra));
        receipt.transferFrom(merchant, extra, CHILD);

        // The merchant asks for the goods and the real warehouse owner releases them
        vm.prank(merchant);
        receipt.requestRelease(CHILD);
        vm.expectEmit(true, true, true, true, d.receipt);
        emit KrsiReceipt.ReceiptReleased(CHILD, merchant, d.warehouseOwner, 12000);
        vm.prank(d.warehouseOwner);
        receipt.confirmRelease(CHILD);
        assertEq(uint8(receipt.stateOf(CHILD)), uint8(KrsiReceipt.State.RELEASED));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, CHILD));
        receipt.ownerOf(CHILD);
        assertEq(receipt.getReceipt(PARENT).quantityKg + receipt.getReceipt(CHILD).quantityKg, 20000);
    }

    function attest(address wallet, uint256 userId, uint8 role) internal returns (bytes32) {
        bytes memory payload = KrsiEncoding.kycData(
            KrsiEncoding.userRef(userId), role, KrsiEncoding.PROVIDER_DEMO, uint64(block.timestamp)
        );
        vm.prank(d.issuer);
        return eas.attest(
            AttestationRequest({
                schema: d.schemaUID,
                data: AttestationRequestData({
                    recipient: wallet,
                    expirationTime: uint64(block.timestamp + 365 days),
                    revocable: true,
                    refUID: bytes32(0),
                    data: payload,
                    value: 0
                })
            })
        );
    }
}
