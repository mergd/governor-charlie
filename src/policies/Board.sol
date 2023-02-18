import {GovernorCharlieDelegate} from "./Governor_Charlie.sol";

import "src/Kernel.sol";

contract GovernorCharlie is GovernorCharlieDelegate {
    constructor(address kernel_) GovernorCharlieDelegate(kernel_) {}
}
