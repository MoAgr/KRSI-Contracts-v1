// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {
    IEAS,
    RevocationRequest,
    RevocationRequestData
} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {KrsiKycResolver} from "../src/KrsiKycResolver.sol";
import {DeploymentsFile} from "./lib/DeploymentsFile.sol";

/// SPEC 7.4: revokes the attestation linked to WALLET. Env: ISSUER_PRIVATE_KEY, WALLET.
contract RevokeKyc is DeploymentsFile {
    function run() external returns (bytes32 uid) {
        Deployment memory d = readDeployment(block.chainid);
        address wallet = vm.envAddress("WALLET");
        uid = revoke(
            IEAS(d.eas),
            KrsiKycResolver(payable(d.kycResolver)),
            d.schemaUID,
            envPrivateKey("ISSUER_PRIVATE_KEY"),
            wallet
        );
        console2.log("Revoked the attestation of wallet", wallet);
        console2.logBytes32(uid);
    }

    function revoke(IEAS eas, KrsiKycResolver resolver, bytes32 schemaUID, uint256 issuerKey, address wallet)
        public
        returns (bytes32 uid)
    {
        uid = resolver.uidOf(wallet);
        require(uid != bytes32(0), "WALLET has no linked attestation");
        vm.startBroadcast(issuerKey);
        eas.revoke(RevocationRequest({schema: schemaUID, data: RevocationRequestData({uid: uid, value: 0})}));
        vm.stopBroadcast();
    }
}
