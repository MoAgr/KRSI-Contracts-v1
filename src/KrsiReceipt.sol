// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC7943NonFungible} from "./interfaces/IERC7943NonFungible.sol";
import {IKrsiKyc} from "./interfaces/IKrsiKyc.sol";
import {KrsiEncoding} from "./lib/KrsiEncoding.sol";

/// @notice The KRSI electronic negotiable warehouse receipt (SPEC section 6): one ERC 721 token per `enwrs` row,
/// held only by wallets with a live KYC attestation, with the ERC 7943 non fungible compliance interface.
contract KrsiReceipt is ERC721, AccessControl, Pausable, IERC7943NonFungible {
    enum State {
        NONE,
        ACTIVE,
        LISTED,
        RELEASE_REQUESTED,
        RELEASED
    }

    struct ReceiptInput {
        uint256 tokenId; // enwrs.id
        string receiptNo; // enwrs.receipt_no
        string warehouseSlug; // enwrs.warehouse_id
        string commodity;
        string grade;
        uint64 quantityKg;
        uint64 storedOn;
        uint64 validTill;
        uint16 moistureBps;
        uint16 foreignMatterBps;
        uint64 inspectedOn;
        bytes32 inspectionHash;
        bytes32 ledgerHash;
    }

    struct Receipt {
        string receiptNo;
        bytes32 warehouseKey;
        string warehouseSlug;
        string commodity;
        string grade;
        uint64 quantityKg;
        uint64 storedOn;
        uint64 validTill;
        uint16 moistureBps;
        uint16 foreignMatterBps;
        address inspector;
        uint64 inspectedOn;
        bytes32 inspectionHash;
        bytes32 ledgerHash;
        uint256 parentId;
        State state;
    }

    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    IKrsiKyc public immutable kyc;
    mapping(uint256 => Receipt) internal _receipts; // kept after burn, state RELEASED
    mapping(uint256 => bool) internal _frozen;
    mapping(bytes32 => address) public warehouseOwnerOf; // warehouseKey => confirming wallet

    /// @dev Set only around the confirmRelease burn and the forcedTransfer move (SPEC 6.5).
    bool private transient _gateBypassed;

    event ReceiptIssued(
        uint256 indexed tokenId,
        address indexed holder,
        bytes32 indexed ownerRef,
        string receiptNo,
        uint64 quantityKg,
        bytes32 ledgerHash
    );
    event ReceiptLocked(uint256 indexed tokenId);
    event ReceiptUnlocked(uint256 indexed tokenId);
    event ReceiptTransferred(
        uint256 indexed tokenId, address indexed from, address indexed to, uint64 quantityKg, uint256 tradeId
    );
    event ReceiptSplit(
        uint256 indexed parentId,
        uint256 indexed childId,
        address indexed buyer,
        address seller,
        uint64 quantityKg,
        uint64 parentRemainingKg,
        uint256 tradeId
    );
    event ReleaseRequested(uint256 indexed tokenId, address indexed holder);
    event ReleaseCancelled(uint256 indexed tokenId);
    event ReceiptReleased(
        uint256 indexed tokenId, address indexed holder, address indexed warehouseOwner, uint64 quantityKg
    );
    event WarehouseOwnerSet(bytes32 indexed warehouseKey, string slug, address indexed owner);

    error ZeroAddress();
    error InvalidTokenId();
    error TokenExists(uint256 tokenId);
    error InvalidString();
    error InvalidQuantity();
    error InvalidDates();
    error InvalidQuality();
    error HolderNotVerified(bytes32 ownerRef);
    error BuyerNotVerified(bytes32 buyerRef);
    error NotTokenOwner(uint256 tokenId, address caller);
    error WrongState(uint256 tokenId, State state);
    error ReceiptExpired(uint256 tokenId);
    error SelfTrade();
    error NotWarehouseOwner(uint256 tokenId, address caller);

    constructor(address admin, IKrsiKyc kyc_) ERC721("KRSI eNWR", "ENWR") {
        if (admin == address(0) || address(kyc_) == address(0)) revert ZeroAddress();
        kyc = kyc_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------- 6.4.1 issue ----------

    function issue(ReceiptInput calldata r, bytes32 ownerRef) external onlyRole(AUDITOR_ROLE) whenNotPaused {
        if (r.tokenId == 0) revert InvalidTokenId();
        if (_receipts[r.tokenId].state != State.NONE) revert TokenExists(r.tokenId);
        if (
            !KrsiEncoding.isValidShortString(r.receiptNo) || !KrsiEncoding.isValidShortString(r.warehouseSlug)
                || !KrsiEncoding.isValidShortString(r.commodity) || !KrsiEncoding.isValidShortString(r.grade)
        ) revert InvalidString();
        if (r.quantityKg == 0) revert InvalidQuantity();
        if (r.storedOn > r.validTill || _isExpired(r.validTill)) revert InvalidDates();
        if (r.moistureBps > 10000 || r.foreignMatterBps > 10000) revert InvalidQuality();
        address holder = kyc.verifiedWalletOf(ownerRef);
        if (holder == address(0)) revert HolderNotVerified(ownerRef);

        Receipt storage s = _receipts[r.tokenId];
        s.receiptNo = r.receiptNo;
        s.warehouseKey = KrsiEncoding.warehouseKey(r.warehouseSlug);
        s.warehouseSlug = r.warehouseSlug;
        s.commodity = r.commodity;
        s.grade = r.grade;
        s.quantityKg = r.quantityKg;
        s.storedOn = r.storedOn;
        s.validTill = r.validTill;
        s.moistureBps = r.moistureBps;
        s.foreignMatterBps = r.foreignMatterBps;
        s.inspector = msg.sender;
        s.inspectedOn = r.inspectedOn;
        s.inspectionHash = r.inspectionHash;
        s.ledgerHash = r.ledgerHash;
        s.state = State.ACTIVE;

        _mint(holder, r.tokenId);
        emit ReceiptIssued(r.tokenId, holder, ownerRef, r.receiptNo, r.quantityKg, r.ledgerHash);
    }

    // ---------- 6.4.2 and 6.4.3 lock and unlock ----------

    function lock(uint256 tokenId) external whenNotPaused {
        address owner = _requireOwnerOrAdmin(tokenId);
        Receipt storage s = _receipts[tokenId];
        _requireState(tokenId, s, State.ACTIVE);
        if (_isExpired(s.validTill)) revert ReceiptExpired(tokenId);
        s.state = State.LISTED;
        _setFrozen(owner, tokenId, true);
        emit ReceiptLocked(tokenId);
    }

    function unlock(uint256 tokenId) external whenNotPaused {
        address owner = _requireOwnerOrAdmin(tokenId);
        Receipt storage s = _receipts[tokenId];
        _requireState(tokenId, s, State.LISTED);
        s.state = State.ACTIVE;
        _setFrozen(owner, tokenId, false);
        emit ReceiptUnlocked(tokenId);
    }

    // ---------- 6.4.4 settle ----------

    function settle(
        uint256 tokenId,
        bytes32 buyerRef,
        uint64 qtyKg,
        uint256 childId,
        string calldata childReceiptNo,
        bytes32 childLedgerHash,
        uint256 tradeId
    ) external whenNotPaused {
        address seller = _ownerOf(tokenId);
        if (seller != msg.sender) revert NotTokenOwner(tokenId, msg.sender);
        Receipt storage parent = _receipts[tokenId];
        _requireState(tokenId, parent, State.LISTED);
        if (_isExpired(parent.validTill)) revert ReceiptExpired(tokenId);
        address buyer = kyc.verifiedWalletOf(buyerRef);
        if (buyer == address(0)) revert BuyerNotVerified(buyerRef);
        if (buyer == seller) revert SelfTrade();
        if (!kyc.isVerified(seller)) revert ERC7943CannotSend(seller);
        if (qtyKg == 0 || qtyKg > parent.quantityKg) revert InvalidQuantity();

        if (qtyKg == parent.quantityKg) {
            // Whole quantity: the receipt itself moves through the gate; the child arguments are ignored.
            parent.state = State.ACTIVE;
            _setFrozen(seller, tokenId, false);
            _transfer(seller, buyer, tokenId);
            emit ReceiptTransferred(tokenId, seller, buyer, qtyKg, tradeId);
        } else {
            _split(tokenId, parent, seller, buyer, qtyKg, childId, childReceiptNo, childLedgerHash, tradeId);
        }
    }

    /// @dev Part quantity: the parent shrinks and stays LISTED and frozen; a child is minted to the buyer.
    function _split(
        uint256 tokenId,
        Receipt storage parent,
        address seller,
        address buyer,
        uint64 qtyKg,
        uint256 childId,
        string calldata childReceiptNo,
        bytes32 childLedgerHash,
        uint256 tradeId
    ) private {
        if (childId == 0) revert InvalidTokenId();
        if (_receipts[childId].state != State.NONE) revert TokenExists(childId);
        if (!KrsiEncoding.isValidShortString(childReceiptNo)) revert InvalidString();

        parent.quantityKg -= qtyKg;
        Receipt storage child = _receipts[childId];
        child.receiptNo = childReceiptNo;
        child.warehouseKey = parent.warehouseKey;
        child.warehouseSlug = parent.warehouseSlug;
        child.commodity = parent.commodity;
        child.grade = parent.grade;
        child.quantityKg = qtyKg;
        child.storedOn = parent.storedOn;
        child.validTill = parent.validTill;
        child.moistureBps = parent.moistureBps;
        child.foreignMatterBps = parent.foreignMatterBps;
        child.inspector = parent.inspector;
        child.inspectedOn = parent.inspectedOn;
        child.inspectionHash = parent.inspectionHash;
        child.ledgerHash = childLedgerHash;
        child.parentId = tokenId;
        child.state = State.ACTIVE;

        _mint(buyer, childId);
        emit ReceiptSplit(tokenId, childId, buyer, seller, qtyKg, parent.quantityKg, tradeId);
    }

    // ---------- 6.4.5 to 6.4.7 release ----------

    function requestRelease(uint256 tokenId) external whenNotPaused {
        address owner = _ownerOf(tokenId);
        if (owner != msg.sender) revert NotTokenOwner(tokenId, msg.sender);
        Receipt storage s = _receipts[tokenId];
        _requireState(tokenId, s, State.ACTIVE); // expired receipts may be released
        s.state = State.RELEASE_REQUESTED;
        _setFrozen(owner, tokenId, true);
        emit ReleaseRequested(tokenId, owner);
    }

    function cancelRelease(uint256 tokenId) external whenNotPaused {
        address owner = _requireOwnerOrAdmin(tokenId);
        Receipt storage s = _receipts[tokenId];
        _requireState(tokenId, s, State.RELEASE_REQUESTED);
        s.state = State.ACTIVE;
        _setFrozen(owner, tokenId, false);
        emit ReleaseCancelled(tokenId);
    }

    function confirmRelease(uint256 tokenId) external whenNotPaused {
        Receipt storage s = _receipts[tokenId];
        address warehouseOwner = warehouseOwnerOf[s.warehouseKey];
        if (warehouseOwner == address(0) || warehouseOwner != msg.sender) {
            revert NotWarehouseOwner(tokenId, msg.sender);
        }
        _requireState(tokenId, s, State.RELEASE_REQUESTED);
        address holder = _ownerOf(tokenId);
        s.state = State.RELEASED;
        _setFrozen(holder, tokenId, false);
        _gateBypassed = true;
        _burn(tokenId);
        _gateBypassed = false;
        emit ReceiptReleased(tokenId, holder, msg.sender, s.quantityKg);
    }

    // ---------- 6.4.8 and 6.4.9 admin ----------

    function setWarehouseOwner(string calldata slug, address owner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!KrsiEncoding.isValidShortString(slug)) revert InvalidString();
        bytes32 key = KrsiEncoding.warehouseKey(slug);
        warehouseOwnerOf[key] = owner;
        emit WarehouseOwnerSet(key, slug, owner);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------- 6.4.10 ERC 7943 enforcement (works while paused) ----------

    function setFrozenTokens(address account, uint256 tokenId, bool frozenStatus)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool result)
    {
        address owner = _ownerOf(tokenId);
        if (owner == address(0) || owner != account) revert NotTokenOwner(tokenId, account); // DEVIATIONS D9
        _setFrozen(account, tokenId, frozenStatus);
        return true;
    }

    function forcedTransfer(address from, address to, uint256 tokenId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bool result)
    {
        address owner = _ownerOf(tokenId);
        if (owner == address(0) || owner != from) revert NotTokenOwner(tokenId, from); // DEVIATIONS D9
        if (!canReceive(to)) revert ERC7943CannotReceive(to);
        if (_frozen[tokenId]) _setFrozen(from, tokenId, false);
        Receipt storage s = _receipts[tokenId];
        if (s.state == State.LISTED || s.state == State.RELEASE_REQUESTED) s.state = State.ACTIVE;
        _gateBypassed = true;
        _transfer(from, to, tokenId);
        _gateBypassed = false;
        emit ForcedTransfer(from, to, tokenId);
        return true;
    }

    // ---------- 6.4.11 views ----------

    function getReceipt(uint256 tokenId) external view returns (Receipt memory) {
        return _receipts[tokenId];
    }

    function stateOf(uint256 tokenId) external view returns (State) {
        return _receipts[tokenId].state;
    }

    function isExpired(uint256 tokenId) external view returns (bool) {
        return _isExpired(_receipts[tokenId].validTill);
    }

    /// @notice SPEC 6.7, exact shape. Works after release; reverts for ids never issued (DEVIATIONS D10).
    function tokenJSON(uint256 tokenId) public view returns (string memory) {
        Receipt storage s = _receipts[tokenId];
        if (s.state == State.NONE) revert ERC721NonexistentToken(tokenId);
        return string.concat(
            '{"name":"eNWR ',
            s.receiptNo,
            '","description":"KRSI electronic negotiable warehouse receipt","attributes":[',
            _textAttributes(s),
            _numberAttributes(s),
            '{"trait_type":"State","value":"',
            _stateName(s.state),
            '"},{"trait_type":"Ledger Hash","value":"',
            Strings.toHexString(uint256(s.ledgerHash), 32),
            '"}]}'
        );
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat("data:application/json;base64,", Base64.encode(bytes(tokenJSON(tokenId))));
    }

    // ---------- 6.6 ERC 7943 views (never revert) ----------

    function canSend(address account) public view returns (bool allowed) {
        return account != address(0) && kyc.isVerified(account);
    }

    function canReceive(address account) public view returns (bool allowed) {
        return account != address(0) && kyc.isVerified(account);
    }

    function canTransfer(address from, address to, uint256 tokenId) public view returns (bool allowed) {
        Receipt storage s = _receipts[tokenId];
        if (paused() || _frozen[tokenId] || s.state != State.ACTIVE || _isExpired(s.validTill)) return false;
        return canSend(from) && canReceive(to);
    }

    function getFrozenTokens(address, uint256 tokenId) external view returns (bool frozenStatus) {
        return _frozen[tokenId];
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl, IERC165) returns (bool) {
        return interfaceId == type(IERC7943NonFungible).interfaceId || super.supportsInterface(interfaceId);
    }

    // ---------- 6.5 transfer gate ----------

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (!_gateBypassed) {
            address from = _ownerOf(tokenId);
            if (from == address(0)) {
                if (!canReceive(to)) revert ERC7943CannotReceive(to);
            } else if (to == address(0)) {
                revert ERC7943CannotTransfer(from, address(0), tokenId); // no public burn
            } else {
                if (paused()) revert ERC7943CannotTransfer(from, to, tokenId);
                if (_frozen[tokenId]) revert ERC7943InsufficientUnfrozenBalance(from, tokenId);
                if (!canSend(from)) revert ERC7943CannotSend(from);
                if (!canReceive(to)) revert ERC7943CannotReceive(to);
                Receipt storage s = _receipts[tokenId];
                if (s.state != State.ACTIVE || _isExpired(s.validTill)) {
                    revert ERC7943CannotTransfer(from, to, tokenId);
                }
            }
        }
        return super._update(to, tokenId, auth);
    }

    // ---------- internals ----------

    /// @dev SPEC 4.7: valid through the whole valid till date in UTC.
    function _isExpired(uint64 validTill) private view returns (bool) {
        return block.timestamp >= uint256(validTill) + 1 days;
    }

    function _requireOwnerOrAdmin(uint256 tokenId) private view returns (address owner) {
        owner = _ownerOf(tokenId);
        if (msg.sender != owner && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotTokenOwner(tokenId, msg.sender);
    }

    function _requireState(uint256 tokenId, Receipt storage s, State expected) private view {
        if (s.state != expected) revert WrongState(tokenId, s.state);
    }

    function _setFrozen(address account, uint256 tokenId, bool frozenStatus) private {
        _frozen[tokenId] = frozenStatus;
        emit Frozen(account, tokenId, frozenStatus);
    }

    function _textAttributes(Receipt storage s) private view returns (string memory) {
        return string.concat(
            '{"trait_type":"Receipt No","value":"',
            s.receiptNo,
            '"},{"trait_type":"Warehouse","value":"',
            s.warehouseSlug,
            '"},{"trait_type":"Commodity","value":"',
            s.commodity,
            '"},{"trait_type":"Grade","value":"',
            s.grade,
            '"},'
        );
    }

    function _numberAttributes(Receipt storage s) private view returns (string memory) {
        return string.concat(
            _numberAttribute("Quantity (kg)", "number", s.quantityKg),
            _numberAttribute("Stored On", "date", s.storedOn),
            _numberAttribute("Valid Till", "date", s.validTill),
            _numberAttribute("Moisture (bps)", "number", s.moistureBps),
            _numberAttribute("Foreign Matter (bps)", "number", s.foreignMatterBps),
            _numberAttribute("Parent", "number", s.parentId)
        );
    }

    function _numberAttribute(string memory trait, string memory displayType, uint256 value)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"', trait, '","display_type":"', displayType, '","value":', Strings.toString(value), "},"
        );
    }

    function _stateName(State state) private pure returns (string memory) {
        if (state == State.ACTIVE) return "ACTIVE";
        if (state == State.LISTED) return "LISTED";
        if (state == State.RELEASE_REQUESTED) return "RELEASE_REQUESTED";
        if (state == State.RELEASED) return "RELEASED";
        return "NONE";
    }
}
