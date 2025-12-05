//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BitGuardVestingVault
 * @notice A revocable linear vesting contract for ERC-20 tokens.
 * @dev Implements linear vesting with precision handling and owner-controlled revocation.
 */
contract BitGuardVestingVault is Ownable {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        // Beneficiary of tokens after they are released
        address beneficiary;
        // Address of the ERC20 token
        address token;
        // Start time of the vesting period
        uint256 startTime;
        // Duration of the vesting period in seconds
        uint256 duration;
        // Duration of the cliff period in seconds
        uint256 cliff;
        // Total amount of tokens to be released at the end of the vesting
        uint256 totalAmount;
        // Amount of tokens released
        uint256 releasedAmount;
        // Whether or not the vesting is revocable
        bool isRevocable;
        // Whether or not the vesting has been revoked
        bool revoked;
    }

    // List of vesting schedules for each beneficiary
    // Note: A beneficiary can have multiple schedules
    mapping(address => VestingSchedule[]) public vestingSchedules;

    // Array to keep track of all beneficiaries to iterate if needed (optional, but good for indexing)
    // For this requirement, we just need the mapping.

    event VestingScheduleCreated(
        address indexed beneficiary,
        address indexed token,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        uint256 totalAmount,
        bool isRevocable
    );

    event TokensClaimed(
        address indexed beneficiary,
        address indexed token,
        uint256 amount
    );

    event VestingScheduleRevoked(
        address indexed beneficiary,
        address indexed token,
        uint256 refundAmount
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Creates a new vesting schedule for a beneficiary.
     * @param _beneficiary The address of the beneficiary.
     * @param _token The address of the ERC20 token.
     * @param _startTime The start time of the vesting period.
     * @param _duration The duration of the vesting period.
     * @param _cliff The duration of the cliff period.
     * @param _totalAmount The total amount of tokens to be vested.
     * @param _isRevocable Whether the vesting is revocable.
     */
    function createVestingSchedule(
        address _beneficiary,
        address _token,
        uint256 _startTime,
        uint256 _duration,
        uint256 _cliff,
        uint256 _totalAmount,
        bool _isRevocable
    ) external onlyOwner {
        require(
            _beneficiary != address(0),
            "Beneficiary cannot be zero address"
        );
        require(_token != address(0), "Token cannot be zero address");
        require(_duration > 0, "Duration must be > 0");
        require(_totalAmount > 0, "Total amount must be > 0");
        require(_cliff <= _duration, "Cliff must be <= duration");

        // Transfer tokens to this contract
        IERC20(_token).safeTransferFrom(
            msg.sender,
            address(this),
            _totalAmount
        );

        vestingSchedules[_beneficiary].push(
            VestingSchedule({
                beneficiary: _beneficiary,
                token: _token,
                startTime: _startTime,
                duration: _duration,
                cliff: _cliff,
                totalAmount: _totalAmount,
                releasedAmount: 0,
                isRevocable: _isRevocable,
                revoked: false
            })
        );

        emit VestingScheduleCreated(
            _beneficiary,
            _token,
            _startTime,
            _duration,
            _cliff,
            _totalAmount,
            _isRevocable
        );
    }

    /**
     * @notice Claims vested tokens for the caller.
     * @dev Iterates through all schedules for the caller and releases vested tokens.
     */
    function claim() external {
        address beneficiary = msg.sender;
        uint256 scheduleCount = vestingSchedules[beneficiary].length;
        require(scheduleCount > 0, "No vesting schedules found");

        for (uint256 i = 0; i < scheduleCount; i++) {
            VestingSchedule storage schedule = vestingSchedules[beneficiary][i];

            // Skip if revoked and fully settled (though revoked logic handles refunds immediately,
            // there might be claimable amount calculated at revocation time if we supported partial claims before revocation.
            // In this design, revocation refunds unvested. Vested amount remains claimable?
            // The prompt says: "Revoke: refund unvested to Owner. Set revoked=true."
            // It implies vested tokens should still be claimable or already claimed.
            // Let's assume claim() handles what's currently vested.

            uint256 vestedAmount = _computeReleasableAmount(schedule);
            if (vestedAmount > 0) {
                schedule.releasedAmount += vestedAmount;
                IERC20(schedule.token).safeTransfer(beneficiary, vestedAmount);
                emit TokensClaimed(beneficiary, schedule.token, vestedAmount);
            }
        }
    }

    /**
     * @notice Revokes a vesting schedule.
     * @param _beneficiary The beneficiary address.
     * @param _scheduleIndex The index of the schedule in the beneficiary's array.
     */
    function revokeSchedule(
        address _beneficiary,
        uint256 _scheduleIndex
    ) external onlyOwner {
        require(
            _scheduleIndex < vestingSchedules[_beneficiary].length,
            "Invalid schedule index"
        );
        VestingSchedule storage schedule = vestingSchedules[_beneficiary][
            _scheduleIndex
        ];

        require(schedule.isRevocable, "Schedule is not revocable");
        require(!schedule.revoked, "Schedule already revoked");

        // Calculate vested amount up to now
        uint256 vestedAmount = _computeVestedAmount(schedule);

        // Unvested = Total - Vested
        // Refund = Unvested - (Total - Vested - Released)?
        // Wait, Refund = Total - Vested.
        // The user keeps 'Vested'.
        // But 'Vested' includes 'Released'.
        // So the amount remaining in contract for this schedule is (Total - Released).
        // We want to leave (Vested - Released) for the user to claim.
        // So we refund (Total - Released) - (Vested - Released) = Total - Vested.

        uint256 refundAmount = schedule.totalAmount - vestedAmount;

        schedule.revoked = true;
        // Update total amount to vested amount so logic holds for future claims (user can only claim up to vested)
        schedule.totalAmount = vestedAmount;

        if (refundAmount > 0) {
            IERC20(schedule.token).safeTransfer(owner(), refundAmount);
        }

        emit VestingScheduleRevoked(_beneficiary, schedule.token, refundAmount);
    }

    /**
     * @notice Computes the releasable amount for a schedule.
     * @param schedule The vesting schedule.
     * @return The amount of tokens that can be claimed.
     */
    function _computeReleasableAmount(
        VestingSchedule memory schedule
    ) internal view returns (uint256) {
        return _computeVestedAmount(schedule) - schedule.releasedAmount;
    }

    /**
     * @notice Computes the total vested amount for a schedule based on current time.
     * @param schedule The vesting schedule.
     * @return The total vested amount.
     */
    function _computeVestedAmount(
        VestingSchedule memory schedule
    ) internal view returns (uint256) {
        if (block.timestamp < schedule.startTime + schedule.cliff) {
            return 0;
        } else if (
            block.timestamp >= schedule.startTime + schedule.duration ||
            schedule.revoked
        ) {
            // If revoked, totalAmount was updated to vestedAmount at revocation time.
            // If expired, full amount is vested.
            return schedule.totalAmount;
        } else {
            // Linear vesting: total * (time_passed / duration)
            uint256 timePassed = block.timestamp - schedule.startTime;
            // Precision handling: Multiply first, then divide
            return (schedule.totalAmount * timePassed) / schedule.duration;
        }
    }

    /**
     * @notice Returns the number of vesting schedules for a beneficiary.
     * @param _beneficiary The beneficiary address.
     * @return The number of schedules.
     */
    function getVestingSchedulesCount(
        address _beneficiary
    ) external view returns (uint256) {
        return vestingSchedules[_beneficiary].length;
    }

    /**
     * @notice Returns a specific vesting schedule.
     * @param _beneficiary The beneficiary address.
     * @param _index The index of the schedule.
     */
    function getVestingSchedule(
        address _beneficiary,
        uint256 _index
    ) external view returns (VestingSchedule memory) {
        return vestingSchedules[_beneficiary][_index];
    }
}
