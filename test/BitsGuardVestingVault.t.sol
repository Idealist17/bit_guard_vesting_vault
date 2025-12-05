// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../contracts/BitsGuardVestingVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BitGuardVestingVaultTest is Test {
    BitGuardVestingVault public vault;
    MockToken public token;
    address public owner;
    address public beneficiary;
    address public other;

    function setUp() public {
        owner = address(this);
        beneficiary = address(0x1);
        other = address(0x2);

        token = new MockToken();
        vault = new BitGuardVestingVault(owner);

        token.approve(address(vault), type(uint256).max);
    }

    function testCreateVestingSchedule() public {
        uint256 amount = 1000;
        uint256 duration = 100;
        
        vault.createVestingSchedule(beneficiary, address(token), block.timestamp, duration, 0, amount, true);
        
        BitGuardVestingVault.VestingSchedule memory schedule = vault.getVestingSchedule(beneficiary, 0);
        assertEq(schedule.totalAmount, amount);
        assertEq(schedule.token, address(token));
        assertEq(schedule.beneficiary, beneficiary);
    }

    function testOnlyOwnerCreate() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vault.createVestingSchedule(beneficiary, address(token), block.timestamp, 100, 0, 1000, true);
    }

    function testClaimLinear() public {
        uint256 amount = 1000;
        uint256 duration = 100;
        uint256 startTime = block.timestamp;
        
        vault.createVestingSchedule(beneficiary, address(token), startTime, duration, 0, amount, true);
        
        // Move to 50% time
        vm.warp(startTime + 50);
        
        vm.prank(beneficiary);
        vault.claim();
        
        assertEq(token.balanceOf(beneficiary), 500);
        assertEq(vault.getVestingSchedule(beneficiary, 0).releasedAmount, 500);
    }

    function testClaimCliff() public {
        uint256 amount = 1000;
        uint256 duration = 100;
        uint256 cliff = 20;
        uint256 startTime = block.timestamp;
        
        vault.createVestingSchedule(beneficiary, address(token), startTime, duration, cliff, amount, true);
        
        // Before cliff
        vm.warp(startTime + 10);
        vm.prank(beneficiary);
        vault.claim();
        assertEq(token.balanceOf(beneficiary), 0);
        
        // After cliff
        vm.warp(startTime + 20);
        vm.prank(beneficiary);
        vault.claim();
        // At 20/100 time = 20% = 200 tokens
        assertEq(token.balanceOf(beneficiary), 200);
    }

    function testRevoke() public {
        uint256 amount = 1000;
        uint256 duration = 100;
        uint256 startTime = block.timestamp;
        
        vault.createVestingSchedule(beneficiary, address(token), startTime, duration, 0, amount, true);
        
        vm.warp(startTime + 50); // 50% vested
        
        uint256 preBalance = token.balanceOf(owner);
        vault.revokeSchedule(beneficiary, 0);
        
        // Refund should be 500 (unvested)
        assertEq(token.balanceOf(owner) - preBalance, 500);
        
        BitGuardVestingVault.VestingSchedule memory schedule = vault.getVestingSchedule(beneficiary, 0);
        assertTrue(schedule.revoked);
        assertEq(schedule.totalAmount, 500); // Updated to vested amount
        
        // Beneficiary can still claim vested
        vm.prank(beneficiary);
        vault.claim();
        assertEq(token.balanceOf(beneficiary), 500);
    }
    
    function testCannotClaimMoreThanTotal() public {
        uint256 amount = 1000;
        uint256 duration = 100;
        uint256 startTime = block.timestamp;
        
        vault.createVestingSchedule(beneficiary, address(token), startTime, duration, 0, amount, true);
        
        vm.warp(startTime + 200); // Way past end
        
        vm.prank(beneficiary);
        vault.claim();
        
        assertEq(token.balanceOf(beneficiary), 1000);
        
        // Try claiming again
        vm.prank(beneficiary);
        vault.claim();
        assertEq(token.balanceOf(beneficiary), 1000);
    }
}

contract Handler is Test {
    BitGuardVestingVault public vault;
    MockToken public token;
    address[] public beneficiaries;

    constructor(BitGuardVestingVault _vault, MockToken _token) {
        vault = _vault;
        token = _token;
    }

    function createSchedule(uint256 amount, uint256 duration, uint256 cliff, uint256 beneficiarySeed) public {
        amount = bound(amount, 1, 1000 ether);
        duration = bound(duration, 1, 1000 days);
        cliff = bound(cliff, 0, duration);
        
        address beneficiary = address(uint160(bound(beneficiarySeed, 1, 100)));
        
        bool exists = false;
        for(uint i=0; i<beneficiaries.length; i++) {
            if(beneficiaries[i] == beneficiary) {
                exists = true;
                break;
            }
        }
        if(!exists) beneficiaries.push(beneficiary);

        token.mint(address(this), amount);
        token.approve(address(vault), amount);
        
        vault.createVestingSchedule(beneficiary, address(token), block.timestamp, duration, cliff, amount, true);
    }

    function claim(uint256 beneficiaryIndex) public {
        if(beneficiaries.length == 0) return;
        address beneficiary = beneficiaries[beneficiaryIndex % beneficiaries.length];
        
        vm.prank(beneficiary);
        vault.claim();
    }

    function revoke(uint256 beneficiaryIndex, uint256 scheduleIndex) public {
        if(beneficiaries.length == 0) return;
        address beneficiary = beneficiaries[beneficiaryIndex % beneficiaries.length];
        
        uint256 count = vault.getVestingSchedulesCount(beneficiary);
        if(count == 0) return;
        
        scheduleIndex = scheduleIndex % count;
        
        vm.prank(vault.owner());
        try vault.revokeSchedule(beneficiary, scheduleIndex) {} catch {}
    }

    function warp(uint256 seconds_) public {
        seconds_ = bound(seconds_, 1, 365 days);
        vm.warp(block.timestamp + seconds_);
    }
    
    function getBeneficiaries() external view returns (address[] memory) {
        return beneficiaries;
    }
}

contract InvariantBitGuardTest is Test {
    BitGuardVestingVault vault;
    MockToken token;
    Handler handler;

    function setUp() public {
        token = new MockToken();
        vault = new BitGuardVestingVault(address(this));
        handler = new Handler(vault, token);
        
        vault.transferOwnership(address(handler)); // Give Handler ownership
        
        targetContract(address(handler));
    }

    function invariant_solvency() public {
        uint256 totalRequired = 0;
        
        address[] memory benes = handler.getBeneficiaries();
        for(uint i=0; i<benes.length; i++) {
            address bene = benes[i];
            uint256 count = vault.getVestingSchedulesCount(bene);
            for(uint j=0; j<count; j++) {
                BitGuardVestingVault.VestingSchedule memory s = vault.getVestingSchedule(bene, j);
                if (s.token == address(token)) {
                    // Solvency: Vault must hold enough to cover (Total - Released)
                    // Note: If revoked, Total is updated to Vested.
                    // So (Total - Released) is always the remaining liability.
                    totalRequired += (s.totalAmount - s.releasedAmount);
                }
            }
        }
        
        assertEq(token.balanceOf(address(vault)), totalRequired, "Solvency broken");
    }
}
