// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {ApexSaleStorage} from "./storage/ApexSaleStorage.sol";

/// @title ApexSale
/// @notice Upgradeable USDG-funded GIGA sale with a liquid claim or a bonus max-duration veGIGA lock.
contract ApexSale is Initializable, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    enum ClaimOption {
        LIQUID,
        LOCKED
    }

    enum ClaimLane {
        SALE,
        POINTS,
        AIRDROP
    }

    enum SaleState {
        PENDING,
        ACTIVE,
        ENDED,
        CLAIMING
    }

    struct InitParams {
        address owner;
        address usdg;
        address giga;
        address veGiga;
        address treasury;
        uint64 startTime;
        uint64 endTime;
        uint256 maxTotalContribution;
        uint256 maxContributionPerAccount;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant LOCKED_CLAIM_BPS = 15_000;
    uint256 public constant USDG_UNIT = 1e6;
    uint256 public constant GIGA_PER_USDG = 50 ether;
    uint256 public constant POINTS_ALLOCATION_CAP = 15_000_000 ether;
    uint256 public constant AIRDROP_ALLOCATION_CAP = 3_000_000 ether;
    uint64 public constant SALE_CLAIM_DURATION = 180 days;
    uint64 public constant POINTS_CLAIM_DURATION = 30 days;
    uint64 public constant AIRDROP_CLAIM_DURATION = 7 days;

    event SaleInitialized(
        address indexed usdg,
        address indexed giga,
        address indexed veGiga,
        address treasury,
        uint64 startTime,
        uint64 endTime,
        uint256 gigaPerUsdg,
        uint256 maxTotalContribution,
        uint256 maxContributionPerAccount
    );
    event Contributed(
        address indexed contributor,
        uint256 usdgAmount,
        uint256 baseGigaAllocation,
        uint256 cumulativeUsdg,
        uint256 cumulativeBaseGigaAllocation,
        uint256 totalUsdg,
        uint256 totalBaseGigaAllocation
    );
    event Claimed(
        address indexed account,
        ClaimOption indexed option,
        uint256 baseGigaAllocation,
        uint256 gigaAmount,
        uint256 veTokenId
    );
    event LaneClaimed(
        address indexed account,
        ClaimLane indexed lane,
        ClaimOption indexed option,
        uint256 maximumEntitlement,
        uint256 gigaAmount,
        uint256 veTokenId
    );
    event ClaimLanesConfigured(
        uint64 claimStartTime,
        uint64 saleClaimEndTime,
        uint64 pointsClaimEndTime,
        uint64 airdropClaimEndTime,
        uint256 pointsTotalEntitlement,
        uint256 airdropTotalEntitlement
    );
    event ClaimAllocationFilled(ClaimLane indexed lane, address indexed account, uint256 maximumEntitlement);
    event SupplementalAirdropConfigured(uint256 recipientCount, uint256 addedEntitlement, uint256 newTotalEntitlement);
    event ClaimsUnpaused(uint256 gigaBalance, uint256 requiredGigaFunding);
    event ClaimsPaused();
    event SaleStartUpdated(uint64 previousStartTime, uint64 newStartTime);
    event SaleEndUpdated(uint64 previousEndTime, uint64 newEndTime);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ContributionCapsUpdated(uint256 maxTotalContribution, uint256 maxContributionPerAccount);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    error AlreadyClaimed();
    error AllocationAlreadySet(ClaimLane lane, address account);
    error ClaimsAlreadyPaused();
    error ClaimsAlreadyUnpaused();
    error ClaimLanesAlreadyConfigured();
    error ClaimLanesNotConfigured();
    error ClaimsNotEnabled();
    error ClaimWindowClosed(ClaimLane lane);
    error ClaimWindowNotOpen(ClaimLane lane);
    error ContributionCapExceeded();
    error ContributionNotReceived();
    error InsufficientGigaFunding(uint256 available, uint256 required);
    error InvalidAddress();
    error InvalidAmount();
    error InvalidArrayLength();
    error InvalidDecimals();
    error InvalidSaleWindow();
    error InvalidTokenConfiguration();
    error LaneAllocationCapExceeded(ClaimLane lane, uint256 attempted, uint256 cap);
    error LaneAllocationEmpty(ClaimLane lane);
    error LaneAllocationIncomplete(ClaimLane lane, uint256 actual, uint256 required);
    error NoAllocation();
    error OwnershipRenunciationDisabled();
    error SupplementalAirdropAlreadyConfigured();
    error SaleAlreadyEnded();
    error SaleNotActive();
    error SaleNotEnded();
    error UserContributionCapExceeded();

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata _params) external initializer {
        if (
            _params.owner == address(0) || _params.usdg == address(0) || _params.giga == address(0)
                || _params.veGiga == address(0) || _params.treasury == address(0)
        ) revert InvalidAddress();
        if (_params.usdg.code.length == 0 || _params.giga.code.length == 0 || _params.veGiga.code.length == 0) {
            revert InvalidAddress();
        }
        if (_params.startTime >= _params.endTime || _params.endTime <= block.timestamp) revert InvalidSaleWindow();
        if (_params.maxTotalContribution == 0) revert InvalidAmount();
        if (_params.maxContributionPerAccount != 0 && _params.maxContributionPerAccount > _params.maxTotalContribution) revert InvalidAmount();
        _validateLiabilityConfig(_params.maxTotalContribution);
        if (IERC20Metadata(_params.usdg).decimals() != 6 || IERC20Metadata(_params.giga).decimals() != 18) {
            revert InvalidDecimals();
        }
        if (IVotingEscrow(_params.veGiga).token() != _params.giga || IVotingEscrow(_params.veGiga).MAXTIME() == 0) {
            revert InvalidTokenConfiguration();
        }

        __Ownable_init(_params.owner);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        s.usdg = IERC20(_params.usdg);
        s.giga = IERC20(_params.giga);
        s.veGiga = IVotingEscrow(_params.veGiga);
        s.treasury = _params.treasury;
        s.startTime = _params.startTime;
        s.endTime = _params.endTime;
        s.claimsPaused = true;
        s.maxTotalContribution = _params.maxTotalContribution;
        s.maxContributionPerAccount = _params.maxContributionPerAccount;

        emit SaleInitialized(
            _params.usdg,
            _params.giga,
            _params.veGiga,
            _params.treasury,
            _params.startTime,
            _params.endTime,
            GIGA_PER_USDG,
            _params.maxTotalContribution,
            _params.maxContributionPerAccount
        );
    }

    /// @notice Stores points entitlements in enumerable on-chain mappings before claim finalization.
    function fillPointsMapping(address[] calldata _accounts, uint256[] calldata _maximumEntitlements)
        external
        onlyOwner
    {
        _fillClaimMapping(ClaimLane.POINTS, _accounts, _maximumEntitlements);
    }

    /// @notice Stores airdrop entitlements in enumerable on-chain mappings before claim finalization.
    function fillAirdropMapping(address[] calldata _accounts, uint256[] calldata _maximumEntitlements)
        external
        onlyOwner
    {
        _fillClaimMapping(ClaimLane.AIRDROP, _accounts, _maximumEntitlements);
    }

    /// @notice Configures one final supplemental airdrop batch after claim activation.
    /// @dev Supplemental state is separate so prior recipients can claim only the added amount. The configuration
    ///      must execute while the airdrop lane is open and leave all remaining maximum liabilities fully funded.
    function configureSupplementalAirdrop(address[] calldata _accounts, uint256[] calldata _maximumEntitlements)
        external
        onlyOwner
    {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (s.supplementalAirdropConfigured) revert SupplementalAirdropAlreadyConfigured();
        if (s.claimStartTime == 0) revert ClaimLanesNotConfigured();
        if (block.timestamp < s.claimStartTime) revert ClaimWindowNotOpen(ClaimLane.AIRDROP);
        if (block.timestamp >= s.airdropClaimEndTime) revert ClaimWindowClosed(ClaimLane.AIRDROP);
        if (_accounts.length == 0 || _accounts.length != _maximumEntitlements.length) {
            revert InvalidArrayLength();
        }

        s.supplementalAirdropConfigured = true;
        uint256 previousTotal = s.airdropTotalEntitlement;
        uint256 newTotal = previousTotal;
        for (uint256 i; i < _accounts.length; ++i) {
            address account = _accounts[i];
            uint256 maximumEntitlement = _maximumEntitlements[i];
            if (account == address(0)) revert InvalidAddress();
            if (maximumEntitlement == 0) revert InvalidAmount();
            if (s.supplementalAirdropAllocations[account] != 0) {
                revert AllocationAlreadySet(ClaimLane.AIRDROP, account);
            }

            s.supplementalAirdropAllocations[account] = maximumEntitlement;
            s.supplementalAirdropRecipients.push(account);
            newTotal += maximumEntitlement;
            if (newTotal > AIRDROP_ALLOCATION_CAP) {
                revert LaneAllocationCapExceeded(ClaimLane.AIRDROP, newTotal, AIRDROP_ALLOCATION_CAP);
            }
            emit ClaimAllocationFilled(ClaimLane.AIRDROP, account, maximumEntitlement);
        }
        s.airdropTotalEntitlement = newTotal;

        uint256 required = outstandingClaimLiability();
        uint256 available = s.giga.balanceOf(address(this));
        if (available < required) revert InsufficientGigaFunding(available, required);
        emit SupplementalAirdropConfigured(_accounts.length, newTotal - previousTotal, newTotal);
    }

    /// @notice Permanently finalizes the common TGE start after both mappings total their exact budgets.
    /// @dev Mapped entitlements are maximum locked amounts. Liquid points and airdrop claims
    ///      receive two-thirds of that amount, preserving a true 50% lock premium.
    function configureClaimLanes(uint64 _claimStartTime) external onlyOwner {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (s.claimStartTime != 0) revert ClaimLanesAlreadyConfigured();
        if (block.timestamp < s.endTime) revert SaleNotEnded();
        if (_claimStartTime < block.timestamp) revert InvalidSaleWindow();
        if (
            _claimStartTime > type(uint64).max - SALE_CLAIM_DURATION
                || _claimStartTime > type(uint64).max - POINTS_CLAIM_DURATION
                || _claimStartTime > type(uint64).max - AIRDROP_CLAIM_DURATION
        ) revert InvalidSaleWindow();
        if (s.pointsTotalEntitlement != POINTS_ALLOCATION_CAP) {
            revert LaneAllocationIncomplete(ClaimLane.POINTS, s.pointsTotalEntitlement, POINTS_ALLOCATION_CAP);
        }
        if (s.airdropTotalEntitlement == 0) revert LaneAllocationEmpty(ClaimLane.AIRDROP);

        s.claimStartTime = _claimStartTime;
        s.saleClaimEndTime = _claimStartTime + SALE_CLAIM_DURATION;
        s.pointsClaimEndTime = _claimStartTime + POINTS_CLAIM_DURATION;
        s.airdropClaimEndTime = _claimStartTime + AIRDROP_CLAIM_DURATION;

        emit ClaimLanesConfigured(
            s.claimStartTime,
            s.saleClaimEndTime,
            s.pointsClaimEndTime,
            s.airdropClaimEndTime,
            s.pointsTotalEntitlement,
            s.airdropTotalEntitlement
        );
    }

    /// @notice Contributes USDG and permanently records the resulting base GIGA allocation.
    /// @dev USDG moves directly from the contributor to treasury; this contract never custodies sale proceeds.
    function contribute(uint256 _amount) external nonReentrant whenNotPaused returns (uint256 allocationAdded) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (block.timestamp < s.startTime || block.timestamp >= s.endTime) revert SaleNotActive();
        if (_amount == 0) revert InvalidAmount();

        uint256 newTotalContributed = s.totalContributed + _amount;
        if (newTotalContributed > s.maxTotalContribution) revert ContributionCapExceeded();

        uint256 previousUserContribution = s.contributions[msg.sender];
        uint256 newUserContribution = previousUserContribution + _amount;
        if (s.maxContributionPerAccount != 0 && newUserContribution > s.maxContributionPerAccount) {
            revert UserContributionCapExceeded();
        }

        uint256 previousUserAllocation = s.baseAllocations[msg.sender];
        uint256 newUserAllocation = Math.mulDiv(newUserContribution, GIGA_PER_USDG, USDG_UNIT);
        allocationAdded = newUserAllocation - previousUserAllocation;
        if (allocationAdded == 0) revert InvalidAmount();

        if (previousUserContribution == 0) s.participants.push(msg.sender);
        s.contributions[msg.sender] = newUserContribution;
        s.baseAllocations[msg.sender] = newUserAllocation;
        s.totalContributed = newTotalContributed;
        s.totalBaseAllocation += allocationAdded;

        uint256 treasuryBalanceBefore = s.usdg.balanceOf(s.treasury);
        s.usdg.safeTransferFrom(msg.sender, s.treasury, _amount);
        if (s.usdg.balanceOf(s.treasury) != treasuryBalanceBefore + _amount) revert ContributionNotReceived();

        emit Contributed(
            msg.sender,
            _amount,
            allocationAdded,
            newUserContribution,
            newUserAllocation,
            newTotalContributed,
            s.totalBaseAllocation
        );
    }

    /// @notice Claims the recorded sale allocation as liquid GIGA or as a 50%-bonus max-duration veGIGA lock.
    function claim(ClaimOption _option) external nonReentrant returns (uint256 amount, uint256 veTokenId) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        _validateClaimWindow(s, ClaimLane.SALE);
        if (s.claimed[msg.sender]) revert AlreadyClaimed();

        uint256 baseAllocation = s.baseAllocations[msg.sender];
        if (baseAllocation == 0) revert NoAllocation();

        s.claimed[msg.sender] = true;
        s.totalClaimedBaseAllocation += baseAllocation;

        amount = _saleClaimAmount(baseAllocation, _option);
        veTokenId = _deliverClaim(s, msg.sender, amount, _option);

        s.totalGigaDistributed += amount;
        emit Claimed(msg.sender, _option, baseAllocation, amount, veTokenId);
    }

    /// @notice Claims the caller's stored points entitlement.
    function claimPoints(ClaimOption _option) external nonReentrant returns (uint256 amount, uint256 veTokenId) {
        return _claimMapped(ClaimLane.POINTS, _option);
    }

    /// @notice Claims the caller's stored airdrop entitlement.
    function claimAirdrop(ClaimOption _option) external nonReentrant returns (uint256 amount, uint256 veTokenId) {
        return _claimMapped(ClaimLane.AIRDROP, _option);
    }

    /// @notice Opens or resumes claims after the contribution cutoff.
    /// @dev Remaining worst-case claim liability must be funded every time claims are unpaused.
    function unpauseClaims() external onlyOwner {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (!s.claimsPaused) revert ClaimsAlreadyUnpaused();
        if (block.timestamp < s.endTime) revert SaleNotEnded();
        if (s.claimStartTime == 0) revert ClaimLanesNotConfigured();
        if (block.timestamp < s.claimStartTime) revert ClaimWindowNotOpen(ClaimLane.SALE);
        if (block.timestamp >= s.saleClaimEndTime) revert ClaimWindowClosed(ClaimLane.SALE);

        uint256 required = outstandingClaimLiability();
        uint256 available = s.giga.balanceOf(address(this));
        if (available < required) revert InsufficientGigaFunding(available, required);
        s.claimsActivated = true;
        s.claimsPaused = false;

        emit ClaimsUnpaused(available, required);
    }

    /// @notice Temporarily stops GIGA and veGIGA claims without changing any allocation records.
    function pauseClaims() external onlyOwner {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (s.claimsPaused) revert ClaimsAlreadyPaused();
        s.claimsPaused = true;
        emit ClaimsPaused();
    }

    function setSaleStart(uint64 _newStartTime) external onlyOwner {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (block.timestamp >= s.startTime || s.totalContributed != 0) revert SaleNotActive();
        if (_newStartTime <= block.timestamp || _newStartTime >= s.endTime) revert InvalidSaleWindow();
        uint64 previousStartTime = s.startTime;
        s.startTime = _newStartTime;
        emit SaleStartUpdated(previousStartTime, _newStartTime);
    }

    /// @notice Changes the end timestamp while the current sale window is still open.
    function setSaleEnd(uint64 _newEndTime) external onlyOwner {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (block.timestamp >= s.endTime || s.claimsActivated) revert SaleAlreadyEnded();
        if (_newEndTime <= block.timestamp || _newEndTime <= s.startTime) revert InvalidSaleWindow();
        uint64 previousEndTime = s.endTime;
        s.endTime = _newEndTime;
        emit SaleEndUpdated(previousEndTime, _newEndTime);
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert InvalidAddress();
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        address previousTreasury = s.treasury;
        s.treasury = _newTreasury;
        emit TreasuryUpdated(previousTreasury, _newTreasury);
    }

    function setContributionCaps(uint256 _maxTotalContribution, uint256 _maxContributionPerAccount) external onlyOwner {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (block.timestamp >= s.endTime || s.claimsActivated) revert SaleAlreadyEnded();
        if (
            _maxTotalContribution < s.totalContributed || _maxTotalContribution == 0
                || (_maxContributionPerAccount != 0 && _maxContributionPerAccount > _maxTotalContribution)
        ) revert InvalidAmount();
        _validateLiabilityConfig(_maxTotalContribution);
        s.maxTotalContribution = _maxTotalContribution;
        s.maxContributionPerAccount = _maxContributionPerAccount;
        emit ContributionCapsUpdated(_maxTotalContribution, _maxContributionPerAccount);
    }

    /// @notice Emergency-pauses USDG contributions without affecting claims.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes USDG contributions, still subject to the configured contribution window.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev The owner controls claim activation and emergency response; allowing renunciation could permanently brick claims.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    /// @notice Recovers accidental token transfers without allowing remaining GIGA claims to become underfunded.
    function recoverToken(address _token, address _to, uint256 _amount) external onlyOwner nonReentrant {
        if (_token == address(0) || _to == address(0)) revert InvalidAddress();
        if (_amount == 0) revert InvalidAmount();

        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        IERC20 tokenToRecover = IERC20(_token);
        if (_token == address(s.giga) && s.claimStartTime != 0) {
            uint256 balance = tokenToRecover.balanceOf(address(this));
            uint256 required = outstandingClaimLiability();
            if (balance < _amount || balance - _amount < required) {
                revert InsufficientGigaFunding(balance - (balance < _amount ? balance : _amount), required);
            }
        }
        tokenToRecover.safeTransfer(_to, _amount);
        emit TokenRecovered(_token, _to, _amount);
    }

    function state() external view returns (SaleState) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (!s.claimsPaused && s.claimStartTime != 0 && block.timestamp < s.saleClaimEndTime) {
            return SaleState.CLAIMING;
        }
        if (block.timestamp < s.startTime) return SaleState.PENDING;
        if (block.timestamp < s.endTime) return SaleState.ACTIVE;
        return SaleState.ENDED;
    }

    function previewBaseAllocation(uint256 _usdgAmount) public pure returns (uint256) {
        return Math.mulDiv(_usdgAmount, GIGA_PER_USDG, USDG_UNIT);
    }

    function previewMappedClaim(uint256 _maximumEntitlement, ClaimOption _option) public pure returns (uint256) {
        return
            _option == ClaimOption.LOCKED
                ? _maximumEntitlement
                : Math.mulDiv(_maximumEntitlement, BPS, LOCKED_CLAIM_BPS);
    }

    function claimable(address _account, ClaimOption _option) external view returns (uint256) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (s.claimed[_account]) return 0;
        if (s.claimStartTime != 0 && block.timestamp >= s.saleClaimEndTime) return 0;
        uint256 baseAllocation = s.baseAllocations[_account];
        return _saleClaimAmount(baseAllocation, _option);
    }

    /// @notice Maximum presale liability if every presaler chooses the locked option.
    function maximumGigaLiability() public view returns (uint256) {
        return Math.mulDiv(ApexSaleStorage.layout().totalBaseAllocation, LOCKED_CLAIM_BPS, BPS);
    }

    /// @notice Remaining presale liability, excluding it once the sale claim window expires.
    function outstandingMaximumGiga() public view returns (uint256) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (s.claimStartTime != 0 && block.timestamp >= s.saleClaimEndTime) return 0;
        return Math.mulDiv(s.totalBaseAllocation - s.totalClaimedBaseAllocation, LOCKED_CLAIM_BPS, BPS);
    }

    /// @notice Maximum liability across sale, points, and airdrop lanes.
    function maximumClaimLiability() public view returns (uint256) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        return maximumGigaLiability() + s.pointsTotalEntitlement + s.airdropTotalEntitlement;
    }

    /// @notice Remaining maximum liability across every claim lane whose deadline has not passed.
    function outstandingClaimLiability() public view returns (uint256 required) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        required = outstandingMaximumGiga();
        if (s.claimStartTime == 0 || block.timestamp < s.pointsClaimEndTime) {
            required += s.pointsTotalEntitlement - s.totalPointsEntitlementClaimed;
        }
        if (s.claimStartTime == 0 || block.timestamp < s.airdropClaimEndTime) {
            required += s.airdropTotalEntitlement - s.totalAirdropEntitlementClaimed;
        }
    }

    function gigaFundingDeficit() external view returns (uint256) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        uint256 required = s.claimStartTime == 0 ? maximumClaimLiability() : outstandingClaimLiability();
        uint256 available = s.giga.balanceOf(address(this));
        return required > available ? required - available : 0;
    }

    function usdg() external view returns (address) {
        return address(ApexSaleStorage.layout().usdg);
    }

    function giga() external view returns (address) {
        return address(ApexSaleStorage.layout().giga);
    }

    function veGiga() external view returns (address) {
        return address(ApexSaleStorage.layout().veGiga);
    }

    function treasury() external view returns (address) {
        return ApexSaleStorage.layout().treasury;
    }

    function startTime() external view returns (uint64) {
        return ApexSaleStorage.layout().startTime;
    }

    function endTime() external view returns (uint64) {
        return ApexSaleStorage.layout().endTime;
    }

    function claimsEnabled() external view returns (bool) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        return !s.claimsPaused && s.claimStartTime != 0 && block.timestamp >= s.claimStartTime
            && block.timestamp < s.saleClaimEndTime;
    }

    function claimLaneOpen(ClaimLane _lane) external view returns (bool) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (s.claimsPaused || s.claimStartTime == 0 || block.timestamp < s.claimStartTime) return false;
        uint64 claimEndTime = _lane == ClaimLane.SALE
            ? s.saleClaimEndTime
            : _lane == ClaimLane.POINTS ? s.pointsClaimEndTime : s.airdropClaimEndTime;
        return block.timestamp < claimEndTime;
    }

    function claimsActivated() external view returns (bool) {
        return ApexSaleStorage.layout().claimsActivated;
    }

    function claimStartTime() external view returns (uint64) {
        return ApexSaleStorage.layout().claimStartTime;
    }

    function saleClaimEndTime() external view returns (uint64) {
        return ApexSaleStorage.layout().saleClaimEndTime;
    }

    function pointsClaimEndTime() external view returns (uint64) {
        return ApexSaleStorage.layout().pointsClaimEndTime;
    }

    function airdropClaimEndTime() external view returns (uint64) {
        return ApexSaleStorage.layout().airdropClaimEndTime;
    }

    function pointsTotalEntitlement() external view returns (uint256) {
        return ApexSaleStorage.layout().pointsTotalEntitlement;
    }

    function airdropTotalEntitlement() external view returns (uint256) {
        return ApexSaleStorage.layout().airdropTotalEntitlement;
    }

    function totalPointsEntitlementClaimed() external view returns (uint256) {
        return ApexSaleStorage.layout().totalPointsEntitlementClaimed;
    }

    function totalAirdropEntitlementClaimed() external view returns (uint256) {
        return ApexSaleStorage.layout().totalAirdropEntitlementClaimed;
    }

    function gigaPerUsdg() external pure returns (uint256) {
        return GIGA_PER_USDG;
    }

    function maxTotalContribution() external view returns (uint256) {
        return ApexSaleStorage.layout().maxTotalContribution;
    }

    function maxContributionPerAccount() external view returns (uint256) {
        return ApexSaleStorage.layout().maxContributionPerAccount;
    }

    function totalContributed() external view returns (uint256) {
        return ApexSaleStorage.layout().totalContributed;
    }

    function totalBaseAllocation() external view returns (uint256) {
        return ApexSaleStorage.layout().totalBaseAllocation;
    }

    function totalClaimedBaseAllocation() external view returns (uint256) {
        return ApexSaleStorage.layout().totalClaimedBaseAllocation;
    }

    function totalGigaDistributed() external view returns (uint256) {
        return ApexSaleStorage.layout().totalGigaDistributed;
    }

    function contributionOf(address _account) external view returns (uint256) {
        return ApexSaleStorage.layout().contributions[_account];
    }

    function baseAllocationOf(address _account) external view returns (uint256) {
        return ApexSaleStorage.layout().baseAllocations[_account];
    }

    function hasClaimed(address _account) external view returns (bool) {
        return ApexSaleStorage.layout().claimed[_account];
    }

    function hasClaimedPoints(address _account) external view returns (bool) {
        return ApexSaleStorage.layout().pointsClaimed[_account];
    }

    function hasClaimedAirdrop(address _account) external view returns (bool) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        bool hasPrimary = s.airdropAllocations[_account] != 0;
        bool hasSupplemental = s.supplementalAirdropAllocations[_account] != 0;
        return (hasPrimary || hasSupplemental) && (!hasPrimary || s.airdropClaimed[_account])
            && (!hasSupplemental || s.supplementalAirdropClaimed[_account]);
    }

    function supplementalAirdropConfigured() external view returns (bool) {
        return ApexSaleStorage.layout().supplementalAirdropConfigured;
    }

    function pointsAllocationOf(address _account) external view returns (uint256) {
        return ApexSaleStorage.layout().pointsAllocations[_account];
    }

    function airdropAllocationOf(address _account) external view returns (uint256) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        return s.airdropAllocations[_account] + s.supplementalAirdropAllocations[_account];
    }

    function primaryAirdropAllocationOf(address _account) external view returns (uint256) {
        return ApexSaleStorage.layout().airdropAllocations[_account];
    }

    function supplementalAirdropAllocationOf(address _account) external view returns (uint256) {
        return ApexSaleStorage.layout().supplementalAirdropAllocations[_account];
    }

    function hasClaimedSupplementalAirdrop(address _account) external view returns (bool) {
        return ApexSaleStorage.layout().supplementalAirdropClaimed[_account];
    }

    function hasClaimedPrimaryAirdrop(address _account) external view returns (bool) {
        return ApexSaleStorage.layout().airdropClaimed[_account];
    }

    function pointsRecipientCount() external view returns (uint256) {
        return ApexSaleStorage.layout().pointsRecipients.length;
    }

    function pointsRecipientAt(uint256 _index) external view returns (address) {
        return ApexSaleStorage.layout().pointsRecipients[_index];
    }

    function airdropRecipientCount() external view returns (uint256) {
        return ApexSaleStorage.layout().airdropRecipients.length;
    }

    function airdropRecipientAt(uint256 _index) external view returns (address) {
        return ApexSaleStorage.layout().airdropRecipients[_index];
    }

    function supplementalAirdropRecipientCount() external view returns (uint256) {
        return ApexSaleStorage.layout().supplementalAirdropRecipients.length;
    }

    function supplementalAirdropRecipientAt(uint256 _index) external view returns (address) {
        return ApexSaleStorage.layout().supplementalAirdropRecipients[_index];
    }

    function participantCount() external view returns (uint256) {
        return ApexSaleStorage.layout().participants.length;
    }

    function participantAt(uint256 _index) external view returns (address) {
        return ApexSaleStorage.layout().participants[_index];
    }

    function _fillClaimMapping(ClaimLane _lane, address[] calldata _accounts, uint256[] calldata _maximumEntitlements)
        internal
    {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        if (s.claimStartTime != 0) revert ClaimLanesAlreadyConfigured();
        if (block.timestamp < s.endTime) revert SaleNotEnded();
        if (_accounts.length == 0 || _accounts.length != _maximumEntitlements.length) {
            revert InvalidArrayLength();
        }

        uint256 newTotal = _lane == ClaimLane.POINTS ? s.pointsTotalEntitlement : s.airdropTotalEntitlement;
        uint256 cap = _lane == ClaimLane.POINTS ? POINTS_ALLOCATION_CAP : AIRDROP_ALLOCATION_CAP;
        for (uint256 i; i < _accounts.length; ++i) {
            address account = _accounts[i];
            uint256 maximumEntitlement = _maximumEntitlements[i];
            if (account == address(0)) revert InvalidAddress();
            if (maximumEntitlement == 0) revert InvalidAmount();

            if (_lane == ClaimLane.POINTS) {
                if (s.pointsAllocations[account] != 0) revert AllocationAlreadySet(_lane, account);
                s.pointsAllocations[account] = maximumEntitlement;
                s.pointsRecipients.push(account);
            } else {
                if (s.airdropAllocations[account] != 0) revert AllocationAlreadySet(_lane, account);
                s.airdropAllocations[account] = maximumEntitlement;
                s.airdropRecipients.push(account);
            }

            newTotal += maximumEntitlement;
            if (newTotal > cap) revert LaneAllocationCapExceeded(_lane, newTotal, cap);
            emit ClaimAllocationFilled(_lane, account, maximumEntitlement);
        }

        if (_lane == ClaimLane.POINTS) {
            s.pointsTotalEntitlement = newTotal;
        } else {
            s.airdropTotalEntitlement = newTotal;
        }
    }

    function _claimMapped(ClaimLane _lane, ClaimOption _option) internal returns (uint256 amount, uint256 veTokenId) {
        ApexSaleStorage.Layout storage s = ApexSaleStorage.layout();
        _validateClaimWindow(s, _lane);

        uint256 maximumEntitlement;
        if (_lane == ClaimLane.POINTS) {
            if (s.pointsClaimed[msg.sender]) revert AlreadyClaimed();
            maximumEntitlement = s.pointsAllocations[msg.sender];
        } else {
            uint256 primaryEntitlement = s.airdropClaimed[msg.sender] ? 0 : s.airdropAllocations[msg.sender];
            uint256 supplementalEntitlement =
                s.supplementalAirdropClaimed[msg.sender] ? 0 : s.supplementalAirdropAllocations[msg.sender];
            maximumEntitlement = primaryEntitlement + supplementalEntitlement;
            if (maximumEntitlement == 0) {
                if (s.airdropAllocations[msg.sender] != 0 || s.supplementalAirdropAllocations[msg.sender] != 0) {
                    revert AlreadyClaimed();
                }
                revert NoAllocation();
            }
            if (primaryEntitlement != 0) s.airdropClaimed[msg.sender] = true;
            if (supplementalEntitlement != 0) s.supplementalAirdropClaimed[msg.sender] = true;
        }
        if (maximumEntitlement == 0) revert NoAllocation();

        if (_lane == ClaimLane.POINTS) {
            uint256 newClaimed = s.totalPointsEntitlementClaimed + maximumEntitlement;
            if (newClaimed > s.pointsTotalEntitlement) {
                revert LaneAllocationCapExceeded(ClaimLane.POINTS, newClaimed, s.pointsTotalEntitlement);
            }
            s.pointsClaimed[msg.sender] = true;
            s.totalPointsEntitlementClaimed = newClaimed;
        } else {
            uint256 newClaimed = s.totalAirdropEntitlementClaimed + maximumEntitlement;
            if (newClaimed > s.airdropTotalEntitlement) {
                revert LaneAllocationCapExceeded(ClaimLane.AIRDROP, newClaimed, s.airdropTotalEntitlement);
            }
            s.totalAirdropEntitlementClaimed = newClaimed;
        }

        amount = previewMappedClaim(maximumEntitlement, _option);
        if (amount == 0) revert InvalidAmount();
        veTokenId = _deliverClaim(s, msg.sender, amount, _option);
        s.totalGigaDistributed += amount;

        emit LaneClaimed(msg.sender, _lane, _option, maximumEntitlement, amount, veTokenId);
    }

    function _validateClaimWindow(ApexSaleStorage.Layout storage s, ClaimLane _lane) internal view {
        if (s.claimsPaused) revert ClaimsNotEnabled();
        if (s.claimStartTime == 0) revert ClaimLanesNotConfigured();
        if (block.timestamp < s.claimStartTime) revert ClaimWindowNotOpen(_lane);

        uint64 claimEndTime = _lane == ClaimLane.SALE
            ? s.saleClaimEndTime
            : _lane == ClaimLane.POINTS ? s.pointsClaimEndTime : s.airdropClaimEndTime;
        if (block.timestamp >= claimEndTime) revert ClaimWindowClosed(_lane);
    }

    function _saleClaimAmount(uint256 _baseAllocation, ClaimOption _option) internal pure returns (uint256) {
        return _option == ClaimOption.LIQUID ? _baseAllocation : Math.mulDiv(_baseAllocation, LOCKED_CLAIM_BPS, BPS);
    }

    function _deliverClaim(ApexSaleStorage.Layout storage s, address _account, uint256 _amount, ClaimOption _option)
        internal
        returns (uint256 veTokenId)
    {
        if (_option == ClaimOption.LIQUID) {
            s.giga.safeTransfer(_account, _amount);
        } else {
            s.giga.forceApprove(address(s.veGiga), _amount);
            veTokenId = s.veGiga.createLockFor(_amount, s.veGiga.MAXTIME(), _account);
            s.giga.forceApprove(address(s.veGiga), 0);
        }
    }

    function _validateLiabilityConfig(uint256 _maxContribution) internal pure {
        uint256 maximumBaseAllocation = Math.mulDiv(_maxContribution, GIGA_PER_USDG, USDG_UNIT);
        Math.mulDiv(maximumBaseAllocation, LOCKED_CLAIM_BPS, BPS);
    }
}
