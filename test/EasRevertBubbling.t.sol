// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EAS} from "@ethereum-attestation-service/eas-contracts/contracts/EAS.sol";
import {SchemaRegistry} from "@ethereum-attestation-service/eas-contracts/contracts/SchemaRegistry.sol";
import {
    IEAS,
    Attestation,
    AttestationRequest,
    AttestationRequestData
} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {ISchemaResolver} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/ISchemaResolver.sol";
import {SchemaResolver} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/SchemaResolver.sol";

/// Reverts every attestation with a custom error that carries data.
contract RevertingResolver is SchemaResolver {
    error Boom(uint256 code, address attester);

    constructor(IEAS eas) SchemaResolver(eas) {}

    function onAttest(Attestation calldata attestation, uint256) internal pure override returns (bool) {
        revert Boom(42, attestation.attester);
    }

    function onRevoke(Attestation calldata, uint256) internal pure override returns (bool) {
        return true;
    }
}

/// Phase 1 check 2d: a custom error raised in onAttest leaves EAS.attest with the same error data.
/// The resolver's revert tests (NotIssuer, WrongSchema and the rest) rely on this.
contract EasRevertBubblingTest is Test {
    function test_CustomErrorInOnAttest_BubblesOutOfEasAttest() public {
        SchemaRegistry registry = new SchemaRegistry();
        EAS eas = new EAS(registry);
        RevertingResolver resolver = new RevertingResolver(eas);
        bytes32 schema = registry.register("uint256 x", ISchemaResolver(address(resolver)), true);
        address attester = makeAddr("attester");

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(RevertingResolver.Boom.selector, uint256(42), attester));
        eas.attest(
            AttestationRequest({
                schema: schema,
                data: AttestationRequestData({
                    recipient: address(0xBEEF),
                    expirationTime: 0,
                    revocable: true,
                    refUID: bytes32(0),
                    data: abi.encode(uint256(1)),
                    value: 0
                })
            })
        );
    }
}
