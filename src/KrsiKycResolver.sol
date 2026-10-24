// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IEAS, Attestation} from "@ethereum-attestation-service/eas-contracts/contracts/IEAS.sol";
import {SchemaResolver} from "@ethereum-attestation-service/eas-contracts/contracts/resolver/SchemaResolver.sol";
import {IKrsiKyc} from "./interfaces/IKrsiKyc.sol";

/// @notice EAS resolver for the KRSI KYC schema (SPEC section 5). Links one live attestation per wallet and one
/// wallet per user reference, and answers "is this wallet verified" for KrsiReceipt.
contract KrsiKycResolver is SchemaResolver, Ownable, IKrsiKyc {
    struct KycView {
        bytes32 uid;
        bytes32 userRef;
        uint8 role;
        bytes32 provider;
        uint64 kycVerifiedAt;
        uint64 expirationTime;
        bool verified;
    }

    uint64 public constant MAX_VALIDITY = 366 days;
    address public issuer;
    bytes32 public schemaUID; // set once, after schema registration
    mapping(address => bytes32) public uidOf; // wallet => live attestation uid
    mapping(address => bytes32) public userRefOf; // wallet => user reference
    mapping(bytes32 => address) public walletOf; // user reference => wallet

    event KycLinked(bytes32 indexed userRef, address indexed wallet, bytes32 indexed uid, uint8 role);
    event KycRevoked(bytes32 indexed userRef, address indexed wallet, bytes32 indexed uid);
    event IssuerChanged(address indexed previous, address indexed current);
    event SchemaSet(bytes32 indexed schemaUID);

    error ZeroAddress();
    error SchemaNotSet();
    error SchemaAlreadySet();
    error WrongSchema(bytes32 schema);
    error NotIssuer(address attester);
    error ZeroRecipient();
    error NotRevocable();
    error MissingExpiry();
    error ExpiryTooLong();
    error InvalidUserRef();
    error InvalidRole(uint8 role);
    error UserAlreadyLinked(bytes32 userRef, address wallet);
    error WalletAlreadyLinked(address wallet, bytes32 userRef);

    /// @dev Both addresses are checked inside Ownable's argument, so a zero issuer or owner reverts ZeroAddress()
    /// before Ownable could revert with its own error.
    constructor(IEAS eas, address issuer_, address owner_) SchemaResolver(eas) Ownable(_nonZero(issuer_, owner_)) {
        issuer = issuer_;
    }

    // ---------- views (SPEC 5.5) ----------

    function isVerified(address wallet) public view returns (bool) {
        (bool live,) = _liveAttestation(wallet);
        return live;
    }

    function verifiedWalletOf(bytes32 userRef) external view returns (address) {
        address wallet = walletOf[userRef];
        return isVerified(wallet) ? wallet : address(0);
    }

    function roleOf(address wallet) external view returns (uint8) {
        (bool live, Attestation memory a) = _liveAttestation(wallet);
        if (!live) return 0;
        (, uint8 role,,) = _decode(a.data);
        return role;
    }

    function getKyc(address wallet) external view returns (KycView memory v) {
        bytes32 uid = uidOf[wallet];
        if (uid == bytes32(0)) return v;
        (bool found, Attestation memory a) = _attestation(uid);
        if (!found) return v;
        (v.userRef, v.role, v.provider, v.kycVerifiedAt) = _decode(a.data);
        v.uid = uid;
        v.expirationTime = a.expirationTime;
        v.verified = _isLive(a);
    }

    // ---------- admin (SPEC 5.6) ----------

    function setIssuer(address issuer_) external onlyOwner {
        if (issuer_ == address(0)) revert ZeroAddress();
        emit IssuerChanged(issuer, issuer_);
        issuer = issuer_;
    }

    function setSchema(bytes32 uid) external onlyOwner {
        if (schemaUID != bytes32(0)) revert SchemaAlreadySet();
        if (uid == bytes32(0)) revert SchemaNotSet(); // DEVIATIONS D8
        schemaUID = uid;
        emit SchemaSet(uid);
    }

    // ---------- EAS hooks ----------

    /// @dev SPEC 5.3; the checks run in exactly this order.
    function onAttest(Attestation calldata attestation, uint256) internal override returns (bool) {
        bytes32 schema = schemaUID;
        if (schema == bytes32(0)) revert SchemaNotSet();
        if (attestation.schema != schema) revert WrongSchema(attestation.schema);
        if (attestation.attester != issuer) revert NotIssuer(attestation.attester);
        address recipient = attestation.recipient;
        if (recipient == address(0)) revert ZeroRecipient();
        if (!attestation.revocable) revert NotRevocable();
        if (attestation.expirationTime == 0) revert MissingExpiry();
        if (attestation.expirationTime > attestation.time + MAX_VALIDITY) revert ExpiryTooLong();
        (bytes32 userRef, uint8 role,,) = _decode(attestation.data);
        if (userRef == bytes32(0)) revert InvalidUserRef();
        if (role < 1 || role > 3) revert InvalidRole(role);

        address linked = walletOf[userRef];
        if (linked != address(0) && linked != recipient && isVerified(linked)) {
            revert UserAlreadyLinked(userRef, linked);
        }
        bytes32 previousRef = userRefOf[recipient];
        if (isVerified(recipient) && previousRef != userRef) revert WalletAlreadyLinked(recipient, previousRef);

        // Clear stale links: the user's old wallet, and the recipient's old user whose link still points here.
        if (linked != address(0) && linked != recipient) {
            delete uidOf[linked];
            delete userRefOf[linked];
        }
        if (previousRef != bytes32(0) && previousRef != userRef && walletOf[previousRef] == recipient) {
            delete walletOf[previousRef];
        }
        uidOf[recipient] = attestation.uid;
        userRefOf[recipient] = userRef;
        walletOf[userRef] = recipient;

        emit KycLinked(userRef, recipient, attestation.uid, role);
        return true;
    }

    /// @dev SPEC 5.4: only the wallet's current attestation unlinks it; revoking a superseded one changes nothing.
    function onRevoke(Attestation calldata attestation, uint256) internal override returns (bool) {
        address recipient = attestation.recipient;
        if (uidOf[recipient] == attestation.uid) {
            bytes32 userRef = userRefOf[recipient];
            delete uidOf[recipient];
            delete userRefOf[recipient];
            if (walletOf[userRef] == recipient) delete walletOf[userRef];
            emit KycRevoked(userRef, recipient, attestation.uid);
        }
        return true;
    }

    // ---------- internals ----------

    /// @dev The wallet's linked attestation and whether it is live. Never reverts.
    function _liveAttestation(address wallet) private view returns (bool live, Attestation memory a) {
        bytes32 uid = uidOf[wallet];
        if (uid == bytes32(0)) return (false, a);
        bool found;
        (found, a) = _attestation(uid);
        live = found && _isLive(a);
    }

    function _attestation(bytes32 uid) private view returns (bool found, Attestation memory a) {
        try _eas.getAttestation(uid) returns (Attestation memory result) {
            return (result.uid == uid, result);
        } catch {
            return (false, a);
        }
    }

    function _isLive(Attestation memory a) private view returns (bool) {
        return a.revocationTime == 0 && a.expirationTime > block.timestamp;
    }

    function _decode(bytes memory data)
        private
        pure
        returns (bytes32 userRef, uint8 role, bytes32 provider, uint64 kycVerifiedAt)
    {
        return abi.decode(data, (bytes32, uint8, bytes32, uint64));
    }

    function _nonZero(address issuer_, address owner_) private pure returns (address) {
        if (issuer_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        return owner_;
    }
}
