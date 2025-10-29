// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title RewardyContract
 * @notice EIP-7702 위임(implementation)용 배치 실행 컨트랙트
 * - 여러 EOA가 같은 구현에 위임하여 사용 (스토리지는 각 EOA 주소에 기록)
 * - 서명 검증 방식: personal_sign 스타일 (toEthSignedMessageHash)
 * - 호출 시점에 수수료(Fee) 파라미터를 자유롭게 지정 (토큰/금액/수취인)
 *   * fee.token == address(0) => 네이티브(ETH) 수수료
 *   * fee.amount == 0 => 수수료 없음
 * - ETH/ERC20 전송 모두 지원 (calls에 자유롭게 구성)
 * - nonce는 slot(0)에 저장 (호환성 위해)
 */
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract RewardyContract {
    using ECDSA for bytes32;

    /// @dev slot0 - replay 보호용 nonce (EOA별 스토리지)
    uint256 public nonce;

    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    struct Fee {
        address token;   // 0x0이면 ETH 수수료
        uint256 amount;  // 0이면 수수료 없음
        address receiver;
    }

    event CallExecuted(address indexed to, uint256 value, bytes data);
    event BatchExecuted(uint256 indexed nonce, uint256 callCount, bytes32 callsHash);
    event FeeCharged(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice 수수료 없이 서명 기반 배치 실행
     * @param calls  (to,value,data)[] 호출들
     * @param deadline 유효 기간 (block.timestamp <= deadline)
     * @param signature address(this)로 복구되는 personal_sign 서명
     */
    function executeWithAuthorization(
        Call[] calldata calls,
        uint256 deadline,
        bytes calldata signature
    ) external payable {
        Fee memory fee = Fee(address(0), 0, address(0));
        _verifyAndExecute(calls, fee, deadline, signature);
    }

    /**
     * @notice 수수료(ETH/토큰)를 포함한 서명 기반 배치 실행
     * @param calls  (to,value,data)[] 호출들
     * @param fee    호출 시점 지정 수수료
     * @param deadline 유효 기간
     * @param signature address(this)로 복구되는 personal_sign 서명
     */
    function executeWithFee(
        Call[] calldata calls,
        Fee calldata fee,
        uint256 deadline,
        bytes calldata signature
    ) external payable {
        _verifyAndExecute(calls, fee, deadline, signature);
    }

    /**
     * @notice self-call 경로(스폰서 없이 계정이 직접 실행할 때) — 서명 불필요
     */
    function executeDirect(Call[] calldata calls) external payable {
        require(msg.sender == address(this), "Rewardy: invalid authority");
        _executeBatch(calls);
    }

    // ---------------- internal ----------------

    function _verifyAndExecute(
        Call[] calldata calls,
        Fee memory fee,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        require(block.timestamp <= deadline, "Rewardy: expired");

        // callsHash = keccak256( packed( (to,value,data)... ) )
        bytes32 callsHash = _hashCalls(calls);

        // digest = keccak256( abi.encode(callsHash, fee.token, fee.amount, fee.receiver, nonce, deadline) )
        bytes32 digest = keccak256(
            abi.encode(
                callsHash,
                fee.token,
                fee.amount,
                fee.receiver,
                nonce,
                deadline
            )
        );

        // personal_sign 스타일
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(digest);
        address recovered = ECDSA.recover(ethHash, signature);

        // 7702: EOA와 스마트계정 주소가 동일해야 하므로, 복구 주소 == address(this)
        require(recovered == address(this), "Rewardy: bad signature");

        // 수수료 처리 (트랜잭션 전체가 하나로 revert되므로 선차감 안전)
        if (fee.amount > 0) {
            if (fee.token == address(0)) {
                // ETH 수수료
                (bool ok, ) = payable(fee.receiver).call{value: fee.amount}("");
                require(ok, "Rewardy: fee eth failed");
            } else {
                // ERC20 수수료
                require(IERC20(fee.token).transfer(fee.receiver, fee.amount), "Rewardy: fee token failed");
            }
            emit FeeCharged(fee.token, fee.receiver, fee.amount);
        }

        _executeBatch(calls);
    }

    function _executeBatch(Call[] calldata calls) internal {
        uint256 current = nonce;
        nonce = current + 1;

        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, ) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            require(ok, "Rewardy: call reverted");
            emit CallExecuted(calls[i].to, calls[i].value, calls[i].data);
        }

        emit BatchExecuted(current, calls.length, _hashCalls(calls));
    }

    function _hashCalls(Call[] calldata calls) internal pure returns (bytes32) {
        bytes memory enc;
        for (uint256 i = 0; i < calls.length; i++) {
            enc = abi.encodePacked(enc, calls[i].to, calls[i].value, calls[i].data);
        }
        return keccak256(enc);
    }

    // 수신
    receive() external payable {}
    fallback() external payable {}
}
