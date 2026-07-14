// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IERC721, IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IVeArtProxy} from "./interfaces/IVeArtProxy.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {VeApexTokenStorage} from "./storage/VeApexTokenStorage.sol";

/// @title VeApexToken
/// @notice Upgradeable veNFT forked from current veAERO normal-lock mechanics.
/// @dev Apex intentionally removes managed NFTs and permanent locks. Max lock time is 26 weeks.
contract VeApexToken is IVotingEscrow, IERC721, IERC721Metadata, IERC6372, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    enum DepositType {
        DEPOSIT_FOR_TYPE,
        CREATE_LOCK_TYPE,
        INCREASE_LOCK_AMOUNT,
        INCREASE_UNLOCK_TIME
    }

    struct UserPoint {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
        uint256 permanent;
    }

    struct GlobalPoint {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
        uint256 permanentLockBalance;
    }

    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        DepositType indexed depositType,
        uint256 value,
        uint256 locktime,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 indexed tokenId, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);
    event Merge(
        address indexed sender,
        uint256 indexed from,
        uint256 indexed to,
        uint256 amountFrom,
        uint256 amountTo,
        uint256 amountFinal,
        uint256 locktime,
        uint256 ts
    );

    error AmountTooBig();
    error ERC721ReceiverRejectedTokens();
    error ERC721TransferToNonERC721ReceiverImplementer();
    error LockDurationNotInFuture();
    error LockDurationTooLong();
    error LockExpired();
    error LockNotExpired();
    error NoLockFound();
    error NonExistentToken();
    error NotApprovedOrOwner();
    error NotOwner();
    error NotTeam();
    error SameAddress();
    error SameNFT();
    error EmptyString();
    error ZeroAddress();
    error ZeroAmount();

    uint256 internal constant WEEK = 1 weeks;
    uint256 public constant MAXTIME = 26 weeks;
    int128 internal constant IMAXTIME = 26 * 7 * 86400;
    uint256 internal constant MULTIPLIER = 1 ether;

    string public constant version = "2.0.0";
    uint8 public constant decimals = 18;

    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 internal constant ERC721_METADATA_INTERFACE_ID = 0x5b5e139f;
    bytes4 internal constant ERC6372_INTERFACE_ID = 0xda287a1d;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _token, address _artProxy, address _team, string memory _name, string memory _symbol)
        external
        initializer
    {
        if (_token == address(0) || _team == address(0)) revert ZeroAddress();
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert EmptyString();
        __ReentrancyGuard_init();

        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        s.token = _token;
        s.artProxy = _artProxy;
        s.team = _team;
        s.name = _name;
        s.symbol = _symbol;

        s.pointHistory[0].blk = block.number;
        s.pointHistory[0].ts = block.timestamp;

        s.supportedInterfaces[ERC165_INTERFACE_ID] = true;
        s.supportedInterfaces[ERC721_INTERFACE_ID] = true;
        s.supportedInterfaces[ERC721_METADATA_INTERFACE_ID] = true;
        s.supportedInterfaces[ERC6372_INTERFACE_ID] = true;

        emit Transfer(address(0), address(this), s.tokenId);
        emit Transfer(address(this), address(0), s.tokenId);
    }

    // admin
    function setTeam(address _team) external {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        if (msg.sender != s.team) revert NotTeam();
        if (_team == address(0)) revert ZeroAddress();
        s.team = _team;
    }

    function setArtProxy(address _artProxy) external {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        if (msg.sender != s.team) revert NotTeam();
        s.artProxy = _artProxy;
    }

    // ERC721
    function name() external view returns (string memory) {
        return VeApexTokenStorage.layout().name;
    }

    function symbol() external view returns (string memory) {
        return VeApexTokenStorage.layout().symbol;
    }

    function ownerOf(uint256 _tokenId) public view override(IERC721, IVotingEscrow) returns (address) {
        return _ownerOf(_tokenId);
    }

    function balanceOf(address _owner) external view returns (uint256) {
        return VeApexTokenStorage.layout().ownerToNFTokenCount[_owner];
    }

    function getApproved(uint256 _tokenId) external view returns (address) {
        return VeApexTokenStorage.layout().idToApprovals[_tokenId];
    }

    function isApprovedForAll(address _owner, address _operator) external view returns (bool) {
        return VeApexTokenStorage.layout().ownerToOperators[_owner][_operator];
    }

    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view returns (bool) {
        return _isApprovedOrOwner(_spender, _tokenId);
    }

    function approve(address _approved, uint256 _tokenId) external {
        address owner = _ownerOf(_tokenId);
        if (owner == address(0)) revert ZeroAddress();
        if (_approved == owner) revert SameAddress();
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        if (msg.sender != owner && !s.ownerToOperators[owner][msg.sender]) revert NotApprovedOrOwner();

        s.idToApprovals[_tokenId] = _approved;
        emit Approval(owner, _approved, _tokenId);
    }

    function setApprovalForAll(address _operator, bool _approved) external {
        if (_operator == msg.sender) revert SameAddress();
        VeApexTokenStorage.layout().ownerToOperators[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) external {
        _transferFrom(_from, _to, _tokenId, msg.sender);
    }

    function safeTransferFrom(address _from, address _to, uint256 _tokenId) external override(IERC721, IVotingEscrow) {
        safeTransferFrom(_from, _to, _tokenId, "");
    }

    function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory _data) public {
        _transferFrom(_from, _to, _tokenId, msg.sender);
        if (_isContract(_to)) {
            try IERC721Receiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data) returns (bytes4 response) {
                if (response != IERC721Receiver.onERC721Received.selector) revert ERC721ReceiverRejectedTokens();
            } catch (bytes memory reason) {
                if (reason.length == 0) revert ERC721TransferToNonERC721ReceiverImplementer();
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
        }
    }

    function supportsInterface(bytes4 _interfaceID) external view returns (bool) {
        return VeApexTokenStorage.layout().supportedInterfaces[_interfaceID];
    }

    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256) {
        return VeApexTokenStorage.layout().ownerToNFTokenIdList[_owner][_index];
    }

    function tokenURI(uint256 _tokenId) external view returns (string memory) {
        if (_ownerOf(_tokenId) == address(0)) revert NonExistentToken();
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        LockedBalance memory lock = s.locked[_tokenId];
        if (s.artProxy == address(0)) return "";
        return
            IVeArtProxy(s.artProxy)._tokenURI(_tokenId, balanceOfNFT(_tokenId), lock.end, uint256(uint128(lock.amount)));
    }

    // escrow
    function checkpoint() external nonReentrant {
        _checkpoint(0, LockedBalance(0, 0, false), LockedBalance(0, 0, false));
    }

    function depositFor(uint256 _tokenId, uint256 _value) external nonReentrant {
        _increaseAmountFor(_tokenId, _value, DepositType.DEPOSIT_FOR_TYPE);
    }

    function createLock(uint256 _value, uint256 _lockDuration) external nonReentrant returns (uint256) {
        return _createLock(_value, _lockDuration, msg.sender);
    }

    function createLockFor(uint256 _value, uint256 _lockDuration, address _to) external nonReentrant returns (uint256) {
        return _createLock(_value, _lockDuration, _to);
    }

    function increaseAmount(uint256 _tokenId, uint256 _value) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner();
        _increaseAmountFor(_tokenId, _value, DepositType.INCREASE_LOCK_AMOUNT);
    }

    function increaseUnlockTime(uint256 _tokenId, uint256 _lockDuration) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner();

        LockedBalance memory oldLocked = VeApexTokenStorage.layout().locked[_tokenId];
        uint256 unlockTime = ((block.timestamp + _lockDuration) / WEEK) * WEEK;
        if (oldLocked.end <= block.timestamp) revert LockExpired();
        if (oldLocked.amount <= 0) revert NoLockFound();
        if (unlockTime <= oldLocked.end) revert LockDurationNotInFuture();
        if (unlockTime > block.timestamp + MAXTIME) revert LockDurationTooLong();

        _depositFor(_tokenId, 0, unlockTime, oldLocked, DepositType.INCREASE_UNLOCK_TIME);
    }

    function withdraw(uint256 _tokenId) external nonReentrant {
        if (!_isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner();

        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        LockedBalance memory oldLocked = s.locked[_tokenId];
        if (block.timestamp < oldLocked.end) revert LockNotExpired();
        uint256 value = _toUint256(oldLocked.amount);

        _burn(_tokenId);
        s.locked[_tokenId] = LockedBalance(0, 0, false);
        uint256 supplyBefore = s.supply;
        s.supply = supplyBefore - value;

        _checkpoint(_tokenId, oldLocked, LockedBalance(0, 0, false));
        IERC20(s.token).safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, _tokenId, value, block.timestamp);
        emit Supply(supplyBefore, s.supply);
    }

    function merge(uint256 _from, uint256 _to) external nonReentrant {
        if (_from == _to) revert SameNFT();
        if (!_isApprovedOrOwner(msg.sender, _from) || !_isApprovedOrOwner(msg.sender, _to)) {
            revert NotApprovedOrOwner();
        }

        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        LockedBalance memory oldLockedTo = s.locked[_to];
        if (oldLockedTo.end <= block.timestamp) revert LockExpired();

        LockedBalance memory oldLockedFrom = s.locked[_from];
        uint256 end = oldLockedFrom.end >= oldLockedTo.end ? oldLockedFrom.end : oldLockedTo.end;

        _burn(_from);
        s.locked[_from] = LockedBalance(0, 0, false);
        _checkpoint(_from, oldLockedFrom, LockedBalance(0, 0, false));

        LockedBalance memory newLockedTo = LockedBalance(oldLockedTo.amount + oldLockedFrom.amount, end, false);
        _checkpoint(_to, oldLockedTo, newLockedTo);
        s.locked[_to] = newLockedTo;

        emit Merge(
            msg.sender,
            _from,
            _to,
            _toUint256(oldLockedFrom.amount),
            _toUint256(oldLockedTo.amount),
            _toUint256(newLockedTo.amount),
            newLockedTo.end,
            block.timestamp
        );
    }

    // views
    function token() external view returns (address) {
        return VeApexTokenStorage.layout().token;
    }

    function team() external view returns (address) {
        return VeApexTokenStorage.layout().team;
    }

    function artProxy() external view returns (address) {
        return VeApexTokenStorage.layout().artProxy;
    }

    function tokenId() external view returns (uint256) {
        return VeApexTokenStorage.layout().tokenId;
    }

    function epoch() external view returns (uint256) {
        return VeApexTokenStorage.layout().epoch;
    }

    function supply() external view returns (uint256) {
        return VeApexTokenStorage.layout().supply;
    }

    function userPointEpoch(uint256 _tokenId) external view returns (uint256) {
        return VeApexTokenStorage.layout().userPointEpoch[_tokenId];
    }

    function slopeChanges(uint256 _timestamp) external view returns (int128) {
        return VeApexTokenStorage.layout().slopeChanges[_timestamp];
    }

    function ownerToNFTokenIdList(address _owner, uint256 _index) external view returns (uint256) {
        return VeApexTokenStorage.layout().ownerToNFTokenIdList[_owner][_index];
    }

    function locked(uint256 _tokenId) external view returns (LockedBalance memory) {
        return VeApexTokenStorage.layout().locked[_tokenId];
    }

    function userPointHistory(uint256 _tokenId, uint256 _loc) external view returns (UserPoint memory) {
        VeApexTokenStorage.UserPoint memory point = VeApexTokenStorage.layout().userPointHistory[_tokenId][_loc];
        return UserPoint(point.bias, point.slope, point.ts, point.blk, point.permanent);
    }

    function pointHistory(uint256 _loc) external view returns (GlobalPoint memory) {
        VeApexTokenStorage.GlobalPoint memory point = VeApexTokenStorage.layout().pointHistory[_loc];
        return GlobalPoint(point.bias, point.slope, point.ts, point.blk, point.permanentLockBalance);
    }

    function latestTokenId() external view returns (uint256) {
        return VeApexTokenStorage.layout().tokenId;
    }

    function getLastUserSlope(uint256 _tokenId) external view returns (int128) {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        return s.userPointHistory[_tokenId][s.userPointEpoch[_tokenId]].slope;
    }

    function balanceOfNFT(uint256 _tokenId) public view returns (uint256) {
        if (VeApexTokenStorage.layout().ownershipChange[_tokenId] == block.number) return 0;
        return _balanceOfNFTAt(_tokenId, block.timestamp);
    }

    function balanceOfNFTAt(uint256 _tokenId, uint256 _timestamp) external view returns (uint256) {
        return _balanceOfNFTAt(_tokenId, _timestamp);
    }

    function totalSupply() external view returns (uint256) {
        return _supplyAt(block.timestamp);
    }

    function totalSupplyAtT(uint256 _timestamp) public view returns (uint256) {
        return _supplyAt(_timestamp);
    }

    function totalSupplyAt(uint256 _timestamp) external view returns (uint256) {
        return _supplyAt(_timestamp);
    }

    function clock() external view returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    // internal ERC721
    function _ownerOf(uint256 _tokenId) internal view returns (address) {
        return VeApexTokenStorage.layout().idToOwner[_tokenId];
    }

    function _isApprovedOrOwner(address _spender, uint256 _tokenId) internal view returns (bool) {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        address owner = _ownerOf(_tokenId);
        return owner == _spender || _spender == s.idToApprovals[_tokenId] || s.ownerToOperators[owner][_spender];
    }

    function _transferFrom(address _from, address _to, uint256 _tokenId, address _sender) internal {
        if (_to == address(0)) revert ZeroAddress();
        if (!_isApprovedOrOwner(_sender, _tokenId)) revert NotApprovedOrOwner();
        if (_ownerOf(_tokenId) != _from) revert NotOwner();

        delete VeApexTokenStorage.layout().idToApprovals[_tokenId];
        _removeTokenFrom(_from, _tokenId);
        _addTokenTo(_to, _tokenId);
        VeApexTokenStorage.layout().ownershipChange[_tokenId] = block.number;

        emit Transfer(_from, _to, _tokenId);
    }

    function _addTokenTo(address _to, uint256 _tokenId) internal {
        if (_to == address(0)) revert ZeroAddress();
        assert(_ownerOf(_tokenId) == address(0));

        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        s.idToOwner[_tokenId] = _to;
        uint256 currentCount = s.ownerToNFTokenCount[_to];
        s.ownerToNFTokenIdList[_to][currentCount] = _tokenId;
        s.tokenToOwnerIndex[_tokenId] = currentCount;
        s.ownerToNFTokenCount[_to] = currentCount + 1;
    }

    function _mint(address _to, uint256 _tokenId) internal {
        _addTokenTo(_to, _tokenId);
        emit Transfer(address(0), _to, _tokenId);
    }

    function _removeTokenFrom(address _from, uint256 _tokenId) internal {
        assert(_ownerOf(_tokenId) == _from);

        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        uint256 currentCount = s.ownerToNFTokenCount[_from] - 1;
        uint256 currentIndex = s.tokenToOwnerIndex[_tokenId];
        if (currentCount == currentIndex) {
            s.ownerToNFTokenIdList[_from][currentCount] = 0;
            s.tokenToOwnerIndex[_tokenId] = 0;
        } else {
            uint256 lastTokenId = s.ownerToNFTokenIdList[_from][currentCount];
            s.ownerToNFTokenIdList[_from][currentIndex] = lastTokenId;
            s.tokenToOwnerIndex[lastTokenId] = currentIndex;
            s.ownerToNFTokenIdList[_from][currentCount] = 0;
            s.tokenToOwnerIndex[_tokenId] = 0;
        }

        s.idToOwner[_tokenId] = address(0);
        s.ownerToNFTokenCount[_from] = currentCount;
    }

    function _burn(uint256 _tokenId) internal {
        if (!_isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner();
        address owner = _ownerOf(_tokenId);

        delete VeApexTokenStorage.layout().idToApprovals[_tokenId];
        _removeTokenFrom(owner, _tokenId);
        emit Transfer(owner, address(0), _tokenId);
    }

    // internal escrow
    function _createLock(uint256 _value, uint256 _lockDuration, address _to) internal returns (uint256) {
        uint256 unlockTime = ((block.timestamp + _lockDuration) / WEEK) * WEEK;
        if (_value == 0) revert ZeroAmount();
        if (unlockTime <= block.timestamp) revert LockDurationNotInFuture();
        if (unlockTime > block.timestamp + MAXTIME) revert LockDurationTooLong();

        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        uint256 newTokenId = ++s.tokenId;
        _mint(_to, newTokenId);
        _depositFor(newTokenId, _value, unlockTime, s.locked[newTokenId], DepositType.CREATE_LOCK_TYPE);
        return newTokenId;
    }

    function _increaseAmountFor(uint256 _tokenId, uint256 _value, DepositType _depositType) internal {
        LockedBalance memory oldLocked = VeApexTokenStorage.layout().locked[_tokenId];
        if (_value == 0) revert ZeroAmount();
        if (oldLocked.amount <= 0) revert NoLockFound();
        if (oldLocked.end <= block.timestamp) revert LockExpired();
        _depositFor(_tokenId, _value, 0, oldLocked, _depositType);
    }

    function _depositFor(
        uint256 _tokenId,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance memory _oldLocked,
        DepositType _depositType
    ) internal {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        uint256 supplyBefore = s.supply;
        s.supply = supplyBefore + _value;

        LockedBalance memory newLocked;
        (newLocked.amount, newLocked.end, newLocked.isPermanent) =
        (_oldLocked.amount, _oldLocked.end, _oldLocked.isPermanent);
        newLocked.amount += _toInt128(_value);
        if (_unlockTime != 0) newLocked.end = _unlockTime;
        s.locked[_tokenId] = newLocked;

        _checkpoint(_tokenId, _oldLocked, newLocked);

        if (_value != 0) IERC20(s.token).safeTransferFrom(msg.sender, address(this), _value);

        emit Deposit(msg.sender, _tokenId, _depositType, _value, newLocked.end, block.timestamp);
        emit Supply(supplyBefore, s.supply);
    }

    function _checkpoint(uint256 _tokenId, LockedBalance memory _oldLocked, LockedBalance memory _newLocked) internal {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        VeApexTokenStorage.UserPoint memory uOld;
        VeApexTokenStorage.UserPoint memory uNew;
        int128 oldDslope;
        int128 newDslope;
        uint256 currentEpoch = s.epoch;

        if (_tokenId != 0) {
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                uOld.slope = _oldLocked.amount / IMAXTIME;
                uOld.bias = uOld.slope * _toInt128(_oldLocked.end - block.timestamp);
            }
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                uNew.slope = _newLocked.amount / IMAXTIME;
                uNew.bias = uNew.slope * _toInt128(_newLocked.end - block.timestamp);
            }

            oldDslope = s.slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                newDslope = _newLocked.end == _oldLocked.end ? oldDslope : s.slopeChanges[_newLocked.end];
            }
        }

        VeApexTokenStorage.GlobalPoint memory lastPoint =
            VeApexTokenStorage.GlobalPoint(0, 0, block.timestamp, block.number, 0);
        if (currentEpoch > 0) lastPoint = s.pointHistory[currentEpoch];
        uint256 lastCheckpoint = lastPoint.ts;
        VeApexTokenStorage.GlobalPoint memory initialLastPoint = VeApexTokenStorage.GlobalPoint({
            bias: lastPoint.bias,
            slope: lastPoint.slope,
            ts: lastPoint.ts,
            blk: lastPoint.blk,
            permanentLockBalance: lastPoint.permanentLockBalance
        });
        uint256 blockSlope;
        if (block.timestamp > lastPoint.ts) {
            blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
        }

        uint256 tI = (lastCheckpoint / WEEK) * WEEK;
        for (uint256 i; i < 255; ++i) {
            tI += WEEK;
            int128 dSlope;
            if (tI > block.timestamp) {
                tI = block.timestamp;
            } else {
                dSlope = s.slopeChanges[tI];
            }
            lastPoint.bias -= lastPoint.slope * _toInt128(tI - lastCheckpoint);
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) lastPoint.bias = 0;
            if (lastPoint.slope < 0) lastPoint.slope = 0;
            lastCheckpoint = tI;
            lastPoint.ts = tI;
            lastPoint.blk = initialLastPoint.blk + (blockSlope * (tI - initialLastPoint.ts)) / MULTIPLIER;
            currentEpoch += 1;
            if (tI == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            }
            s.pointHistory[currentEpoch] = lastPoint;
        }

        if (_tokenId != 0) {
            lastPoint.slope += uNew.slope - uOld.slope;
            lastPoint.bias += uNew.bias - uOld.bias;
            if (lastPoint.slope < 0) lastPoint.slope = 0;
            if (lastPoint.bias < 0) lastPoint.bias = 0;
        }

        if (currentEpoch != 1 && s.pointHistory[currentEpoch - 1].ts == block.timestamp) {
            s.pointHistory[currentEpoch - 1] = lastPoint;
        } else {
            s.epoch = currentEpoch;
            s.pointHistory[currentEpoch] = lastPoint;
        }

        if (_tokenId != 0) _writeCheckpointUser(_tokenId, _oldLocked, _newLocked, uOld, uNew, oldDslope, newDslope);
    }

    function _writeCheckpointUser(
        uint256 _tokenId,
        LockedBalance memory _oldLocked,
        LockedBalance memory _newLocked,
        VeApexTokenStorage.UserPoint memory _uOld,
        VeApexTokenStorage.UserPoint memory _uNew,
        int128 _oldDslope,
        int128 _newDslope
    ) internal {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        if (_oldLocked.end > block.timestamp) {
            _oldDslope += _uOld.slope;
            if (_newLocked.end == _oldLocked.end) _oldDslope -= _uNew.slope;
            s.slopeChanges[_oldLocked.end] = _oldDslope;
        }

        if (_newLocked.end > block.timestamp && _newLocked.end > _oldLocked.end) {
            _newDslope -= _uNew.slope;
            s.slopeChanges[_newLocked.end] = _newDslope;
        }

        _uNew.ts = block.timestamp;
        _uNew.blk = block.number;
        uint256 userEpoch = s.userPointEpoch[_tokenId];
        if (userEpoch != 0 && s.userPointHistory[_tokenId][userEpoch].ts == block.timestamp) {
            s.userPointHistory[_tokenId][userEpoch] = _uNew;
        } else {
            s.userPointEpoch[_tokenId] = ++userEpoch;
            s.userPointHistory[_tokenId][userEpoch] = _uNew;
        }
    }

    function _balanceOfNFTAt(uint256 _tokenId, uint256 _timestamp) internal view returns (uint256) {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        uint256 userEpoch = s.userPointEpoch[_tokenId];
        if (userEpoch == 0) return 0;
        userEpoch = _findTimeUserEpoch(_tokenId, _timestamp, userEpoch);

        VeApexTokenStorage.UserPoint memory lastPoint = s.userPointHistory[_tokenId][userEpoch];
        lastPoint.bias -= lastPoint.slope * _toInt128(_timestamp - lastPoint.ts);
        if (lastPoint.bias < 0) return 0;
        return uint256(uint128(lastPoint.bias));
    }

    function _supplyAt(uint256 _timestamp) internal view returns (uint256) {
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        uint256 targetEpoch = _findTimeGlobalEpoch(_timestamp, s.epoch);
        if (targetEpoch == 0) return 0;

        VeApexTokenStorage.GlobalPoint memory lastPoint = s.pointHistory[targetEpoch];
        int128 bias = lastPoint.bias;
        int128 slope = lastPoint.slope;
        uint256 ts = lastPoint.ts;
        uint256 tI = (ts / WEEK) * WEEK;
        for (uint256 i; i < 255; ++i) {
            tI += WEEK;
            int128 dSlope;
            if (tI > _timestamp) {
                tI = _timestamp;
            } else {
                dSlope = s.slopeChanges[tI];
            }
            bias -= slope * _toInt128(tI - ts);
            if (tI == _timestamp) break;
            slope += dSlope;
            ts = tI;
        }
        if (bias < 0) return lastPoint.permanentLockBalance;
        return uint256(uint128(bias)) + lastPoint.permanentLockBalance;
    }

    function _findTimeUserEpoch(uint256 _tokenId, uint256 _timestamp, uint256 _maxEpoch)
        internal
        view
        returns (uint256)
    {
        uint256 min;
        uint256 max = _maxEpoch;
        for (uint256 i; i < 256; ++i) {
            if (min >= max) break;
            uint256 mid = (min + max + 1) / 2;
            if (VeApexTokenStorage.layout().userPointHistory[_tokenId][mid].ts <= _timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    function _findTimeGlobalEpoch(uint256 _timestamp, uint256 _maxEpoch) internal view returns (uint256) {
        if (_maxEpoch == 0) return 0;
        VeApexTokenStorage.Layout storage s = VeApexTokenStorage.layout();
        if (s.pointHistory[_maxEpoch].ts <= _timestamp) return _maxEpoch;
        if (s.pointHistory[1].ts > _timestamp) return 0;

        uint256 min;
        uint256 max = _maxEpoch;
        while (max > min) {
            uint256 mid = max - (max - min) / 2;
            if (s.pointHistory[mid].ts <= _timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    function _isContract(address _account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_account)
        }
        return size > 0;
    }

    function _toInt128(uint256 _value) internal pure returns (int128) {
        require(_value <= uint256(uint128(type(int128).max)));
        return int128(uint128(_value));
    }

    function _toUint256(int128 _value) internal pure returns (uint256) {
        require(_value >= 0);
        return uint256(uint128(_value));
    }
}
