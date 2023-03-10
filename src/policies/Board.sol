// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import {ROLESv1} from "src/modules/ROLES/ROLES.v1.sol";
import {BOARDv1} from "src/modules/BOARD/Board.v1.sol";
import "src/policies/interfaces/ISafe.sol";
import "src/policies/Governor_Charlie.sol";
import "src/Kernel.sol";

/// @notice Controls roles in the roles admin
contract Board is Policy {
    // =========  EVENTS ========= //

    event NewAdminPushed(address indexed newAdmin_);
    event NewAdminPulled(address indexed newAdmin_);

    // =========  ERRORS ========= //

    error OnlyAdmin();
    error OnlyNewAdmin();

    // =========  STATE ========= //

    /// @notice Special role that is responsible for assigning policy-defined roles to addresses.
    address public admin;

    /// @notice Proposed new admin. Address must call `pullRolesAdmin` to become the new roles admin.
    address public newAdmin;

    ROLESv1 public ROLES;

    //============================================================================================//
    //                                      POLICY SETUP                                          //
    //============================================================================================//

    constructor(Kernel _kernel, address governance_) Policy(_kernel) {
        admin = governance_;
    }

    function configureDependencies()
        external
        override
        returns (Keycode[] memory dependencies)
    {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("ROLES");

        ROLES = ROLESv1(getModuleAddress(dependencies[0]));
    }

    function requestPermissions()
        external
        view
        override
        returns (Permissions[] memory requests)
    {
        Keycode ROLES_KEYCODE = toKeycode("ROLES");

        requests = new Permissions[](2);
        requests[0] = Permissions(ROLES_KEYCODE, ROLES.saveRole.selector);
        requests[1] = Permissions(ROLES_KEYCODE, ROLES.removeRole.selector);
    }

    //============================================================================================//
    //                                       CORE FUNCTIONS                                       //
    //============================================================================================//
    function createBoard() external {
        // create board
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    function grantRole(bytes32 role_, address wallet_) external onlyAdmin {
        ROLES.saveRole(role_, wallet_);
    }

    function revokeRole(bytes32 role_, address wallet_) external onlyAdmin {
        ROLES.removeRole(role_, wallet_);
    }

    //============================================================================================//
    //                                      ADMIN FUNCTIONS                                       //
    //============================================================================================//

    function pushNewAdmin(address newAdmin_) external onlyAdmin {
        newAdmin = newAdmin_;
        emit NewAdminPushed(newAdmin_);
    }

    function pullNewAdmin() external {
        if (msg.sender != newAdmin) revert OnlyNewAdmin();
        admin = newAdmin;
        newAdmin = address(0);
        emit NewAdminPulled(admin);
    }
}
