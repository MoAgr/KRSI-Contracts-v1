// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {
    IEAS,
    AttestationRequest,
    AttestationRequestData
} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {KrsiEncoding} from "../src/lib/KrsiEncoding.sol";
import {DeploymentsFile} from "./lib/DeploymentsFile.sol";

/// SPEC 7.3: the presenter's fallback when the dashboard has no issuer screen.
/// Env: ISSUER_PRIVATE_KEY, USER_ID, ROLE (1, 2 or 3), PROVIDER (SETU_DIGILOCKER or DEMO), WALLET,
/// KYC_VERIFIED_AT (unix seconds of GET /api/kyc verifiedAt, rounded down; DEVIATIONS D11).
contract IssueKyc is DeploymentsFile {
    uint64 public constant VALIDITY = 365 days;

    struct Params {
        uint256 userId;
        uint8 role;
        bytes32 provider;
        address wallet;
        uint64 kycVerifiedAt;
    }

    function run() external returns (bytes32 uid) {
        Deployment memory d = readDeployment(block.chainid);
        Params memory p = paramsFromEnv();
        uid = issue(IEAS(d.eas), d.schemaUID, envPrivateKey("ISSUER_PRIVATE_KEY"), p);
        console2.log("Attested user", p.userId, "to wallet", p.wallet);
        console2.log("uid");
        console2.logBytes32(uid);
    }

    function paramsFromEnv() public view returns (Params memory p) {
        p.userId = vm.envUint("USER_ID");
        uint256 role = vm.envUint("ROLE");
        require(role >= 1 && role <= 3, "ROLE must be 1, 2 or 3");
        p.role = uint8(role);
        p.provider = providerFromName(vm.envString("PROVIDER"));
        p.wallet = vm.envAddress("WALLET");
        p.kycVerifiedAt = uint64(vm.envUint("KYC_VERIFIED_AT"));
    }

    function providerFromName(string memory name) public pure returns (bytes32) {
        if (keccak256(bytes(name)) == keccak256("SETU_DIGILOCKER")) return KrsiEncoding.PROVIDER_SETU;
        if (keccak256(bytes(name)) == keccak256("DEMO")) return KrsiEncoding.PROVIDER_DEMO;
        revert("PROVIDER must be SETU_DIGILOCKER or DEMO");
    }

    function issue(IEAS eas, bytes32 schemaUID, uint256 issuerKey, Params memory p) public returns (bytes32 uid) {
        require(p.wallet != address(0), "WALLET is zero");
        require(p.kycVerifiedAt != 0 && p.kycVerifiedAt <= block.timestamp, "KYC_VERIFIED_AT must be a past time");
        bytes memory data = KrsiEncoding.kycData(KrsiEncoding.userRef(p.userId), p.role, p.provider, p.kycVerifiedAt);
        vm.startBroadcast(issuerKey);
        uid = eas.attest(
            AttestationRequest({
                schema: schemaUID,
                data: AttestationRequestData({
                    recipient: p.wallet,
                    expirationTime: uint64(block.timestamp) + VALIDITY,
                    revocable: true,
                    refUID: bytes32(0),
                    data: data,
                    value: 0
                })
            })
        );
        vm.stopBroadcast();
    }
}
