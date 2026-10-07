// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice ISO 11649 creditor references: "RF" + two check digits + body, check digits per
/// ISO 7064 MOD 97-10 (move "RF00" behind the body, letters A..Z -> 10..35, 98 - n mod 97).
library RfReference {
    error InvalidBody();

    /// The batch reference: RF + check digits + "CS" + decimal batch number (batch < 10^19).
    function forBatch(uint64 batch) internal pure returns (string memory) {
        return compute(string.concat("CS", Strings.toString(batch)));
    }

    /// body: 1..21 characters from [0-9A-Z].
    function compute(string memory body) internal pure returns (string memory) {
        uint256 cd = checkDigits(body);
        bytes memory d = new bytes(2);
        d[0] = bytes1(uint8(48 + cd / 10));
        d[1] = bytes1(uint8(48 + cd % 10));
        return string.concat("RF", string(d), body);
    }

    function checkDigits(string memory body) internal pure returns (uint256) {
        bytes memory b = bytes(body);
        if (b.length == 0 || b.length > 21) {
            revert InvalidBody();
        }
        uint256 n = _mod97(0, b);
        n = _mod97(n, bytes("RF00"));
        return 98 - n;
    }

    /// True iff `ref` is "RF" + 2 digits + a valid body whose check digits verify.
    function isValid(string memory ref) internal pure returns (bool) {
        bytes memory r = bytes(ref);
        if (r.length < 5 || r.length > 25 || r[0] != "R" || r[1] != "F") {
            return false;
        }
        if (!_isDigit(r[2]) || !_isDigit(r[3])) {
            return false;
        }
        bytes memory body = new bytes(r.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = r[i + 4];
            if (!_isDigit(body[i]) && !_isUpper(body[i])) {
                return false;
            }
        }
        bytes memory head = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            head[i] = r[i];
        }
        return _mod97(_mod97(0, body), head) == 1;
    }

    function _mod97(uint256 n, bytes memory s) private pure returns (uint256) {
        for (uint256 i = 0; i < s.length; i++) {
            bytes1 c = s[i];
            if (_isDigit(c)) {
                n = (n * 10 + (uint8(c) - 48)) % 97;
            } else if (_isUpper(c)) {
                n = (n * 100 + (uint8(c) - 55)) % 97;
            } else {
                revert InvalidBody();
            }
        }
        return n;
    }

    function _isDigit(bytes1 c) private pure returns (bool) {
        return c >= "0" && c <= "9";
    }

    function _isUpper(bytes1 c) private pure returns (bool) {
        return c >= "A" && c <= "Z";
    }
}
