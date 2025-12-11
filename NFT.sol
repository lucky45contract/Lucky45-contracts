// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract NFT is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant PERMIT_ROLE = keccak256("PERMIT_ROLE");

    IERC20 public immutable paymentToken;
    uint256 public nftPrice;
    uint256 public totalBuyValue;
    uint256 public checkPoint1;
    uint256 public checkPoint2;

    event NFTBought(address indexed user, string nftType, uint64 nftPage, uint64 nftNumber, uint64 nftAmount, uint256 totalPrice);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event ManagerAdded(address indexed manager);
    event ManagerRemoved(address indexed manager);
    event DistributorAdded(address indexed distributor);
    event DistributorRemoved(address indexed distributor);
    event CheckPoint1Updated(address indexed caller, uint256 newValue);
    event CheckPoint2Updated(address indexed caller, uint256 newValue);
    event WithdrawByAmount(address indexed caller, address indexed recipient, uint256 amount);
    event WithdrawByPercent(address indexed caller, address indexed recipient, uint256 percent, uint256 amount);
    event ProcessingError(
        address indexed user, 
        string nftType, 
        uint64 nftPage, 
        string reason
    );
    event PermitterAdded(address indexed permitter);
    event PermitterRemoved(address indexed permitter);

    struct BuyRequest {
        string nftType;
        address user;
        uint64 nftPage;
        uint64 nftNumber;
        uint64 nftAmount;
        uint64 timestamp;
    }

    uint256 private constant VALIDITY_PERIOD = 3 minutes;

    constructor(address _token, uint256 _nftPrice) {
        require(_token != address(0), "Invalid token address");
        require(_nftPrice > 0, "Price must be positive");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(PERMIT_ROLE, msg.sender);

        paymentToken = IERC20(_token);
        nftPrice = _nftPrice;
    }

    function setNftPrice(uint256 _price) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_price > 0, "Price must be positive");
        nftPrice = _price;
    }

    function addOperator(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(operator != address(0), "Invalid operator address");
        require(!hasRole(OPERATOR_ROLE, operator), "Already an operator");
        
        _grantRole(OPERATOR_ROLE, operator);
        emit OperatorAdded(operator);
    }

    function removeOperator(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(operator != address(0), "Invalid operator address");
        require(hasRole(OPERATOR_ROLE, operator), "Not an operator");
        require(operator != msg.sender, "Cannot remove self");
        
        _revokeRole(OPERATOR_ROLE, operator);
        emit OperatorRemoved(operator);
    }

    function isOperator(address account) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }

    function addManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(manager != address(0), "Invalid manager address");
        require(!hasRole(MANAGER_ROLE, manager), "Already a manager");
        _grantRole(MANAGER_ROLE, manager);
        emit ManagerAdded(manager);
    }

    function removeManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(manager != address(0), "Invalid manager address");
        require(hasRole(MANAGER_ROLE, manager), "Not a manager");
        require(manager != msg.sender, "Cannot remove self");
        _revokeRole(MANAGER_ROLE, manager);
        emit ManagerRemoved(manager);
    }

    function isManager(address account) external view returns (bool) {
        return hasRole(MANAGER_ROLE, account);
    }

    function addDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(distributor != address(0), "Invalid distributor address");
        require(!hasRole(DISTRIBUTOR_ROLE, distributor), "Already a distributor");
        
        _grantRole(DISTRIBUTOR_ROLE, distributor);
        emit DistributorAdded(distributor);
    }

    function removeDistributor(address distributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(distributor != address(0), "Invalid distributor address");
        require(hasRole(DISTRIBUTOR_ROLE, distributor), "Not a distributor");
        require(distributor != msg.sender, "Cannot remove self");
        
        _revokeRole(DISTRIBUTOR_ROLE, distributor);
        emit DistributorRemoved(distributor);
    }

    function isDistributor(address account) external view returns (bool) {
        return hasRole(DISTRIBUTOR_ROLE, account);
    }

    function addPermitter(address permitter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(permitter != address(0), "Invalid permitter address");
        require(!hasRole(PERMIT_ROLE, permitter), "Already a permitter");
        
        _grantRole(PERMIT_ROLE, permitter);
        emit PermitterAdded(permitter);
    }

    function removePermitter(address permitter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(permitter != address(0), "Invalid permitter address");
        require(hasRole(PERMIT_ROLE, permitter), "Not a permitter");
        require(permitter != msg.sender, "Cannot remove self");
        
        _revokeRole(PERMIT_ROLE, permitter);
        emit PermitterRemoved(permitter);
    }

    function isPermitter(address account) external view returns (bool) {
        return hasRole(PERMIT_ROLE, account);
    }

    function approveWithPermit(
        address user,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(PERMIT_ROLE) {
        require(block.timestamp <= deadline, "Permit expired");
        
        // Use permit to approve tokens
        IERC20Permit(address(paymentToken)).permit(
            user,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
    }

    function batchApproveWithPermit(
        address[] calldata users,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external onlyRole(PERMIT_ROLE) {
        require(users.length == amounts.length, "Length mismatch: users/amounts");
        require(users.length == deadlines.length, "Length mismatch: users/deadlines");
        require(users.length == v.length, "Length mismatch: users/v");
        require(users.length == r.length, "Length mismatch: users/r");
        require(users.length == s.length, "Length mismatch: users/s");
        require(users.length > 0, "Empty arrays");

        for (uint256 i = 0; i < users.length; ) {
            require(block.timestamp <= deadlines[i], "Permit expired");
            
            IERC20Permit(address(paymentToken)).permit(
                users[i],
                address(this),
                amounts[i],
                deadlines[i],
                v[i],
                r[i],
                s[i]
            );
            
            unchecked {
                ++i;
            }
        }
    }

    function _buySingle(
        BuyRequest calldata request,
        bytes calldata signature
    ) internal returns (bool) {
        try this._verifyAndProcess(request, signature) {
            return true;
        } catch Error(string memory reason) {
            // This catches require() failures like "Expired" and "Invalid signature"
            emit ProcessingError(
                request.user, 
                request.nftType, 
                request.nftPage, 
                reason
            );
            return false;
        } catch {
            // This catches safeTransferFrom failures - NOW diagnose what went wrong
            uint256 allowance = paymentToken.allowance(request.user, address(this));
            uint256 totalPrice = uint256(request.nftAmount) * nftPrice;
            
            string memory errorReason;
            if (allowance < totalPrice) {
                errorReason = "Insufficient allowance";
            } else {
                uint256 balance = paymentToken.balanceOf(request.user);
                if (balance < totalPrice) {
                    errorReason = "Insufficient balance";
                } else {
                    errorReason = "Unknown error";
                }
            }
             emit ProcessingError(
                request.user, 
                request.nftType, 
                request.nftPage, 
                errorReason
            );

            return false;
        }
    }

    function _verifyAndProcess(BuyRequest calldata request, bytes calldata signature) external onlyRole(OPERATOR_ROLE) {
        require(block.timestamp <= request.timestamp + VALIDITY_PERIOD, "Expired");

        bytes32 messageHash = keccak256(
            abi.encode(request.nftType, request.nftPage, request.nftAmount, request.timestamp)
        );

        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ECDSA.recover(ethSignedMessageHash, signature);
        require(signer == request.user, "Invalid signature");

        uint256 totalPrice = uint256(request.nftAmount) * nftPrice;
        
        paymentToken.safeTransferFrom(request.user, address(this), totalPrice);
        
        totalBuyValue += totalPrice;
        emit NFTBought(request.user, request.nftType, request.nftPage, request.nftNumber, request.nftAmount, totalPrice);
    }

    function buyBatch(
        BuyRequest[] calldata requests,
        bytes[] calldata signatures
    ) public nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        require(requests.length == signatures.length, "Length mismatch");

        uint256 length = requests.length;
        for (uint i = 0; i < length; ) {
            _buySingle(requests[i], signatures[i]);
            unchecked {
                ++i;
            }
        }
    }

    function distributeRewards(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyRole(DISTRIBUTOR_ROLE) {
        require(recipients.length == amounts.length, "Length mismatch");

        uint256 length = recipients.length;
        for (uint i = 0; i < length; ) {
            paymentToken.safeTransfer(recipients[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function updateCheckPoint1(uint256 newValue) external onlyRole(MANAGER_ROLE) {
        checkPoint1 = newValue;
        emit CheckPoint1Updated(msg.sender, newValue);
    }

    function updateCheckPoint2(uint256 newValue) external onlyRole(MANAGER_ROLE) {
        checkPoint2 = newValue;
        emit CheckPoint2Updated(msg.sender, newValue);
    }

    function withdrawTokenByAmount(uint256 amount, address recipient) external onlyRole(MANAGER_ROLE) {
        require(recipient != address(0), "Cannot withdraw to zero address");
        require(amount > 0, "Amount must be greater than zero");
        paymentToken.safeTransfer(recipient, amount);
        emit WithdrawByAmount(msg.sender, recipient, amount);
    }

    function withdrawByPercent(uint256 percent, address recipient) external onlyRole(MANAGER_ROLE) {
        require(recipient != address(0), "Cannot withdraw to zero address");
        require(percent > 0 && percent <= 100, "Percent must be 1-100");
        uint256 balance = paymentToken.balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");
        uint256 amount = (balance * percent) / 100;
        require(amount > 0, "Withdraw amount is zero");
        paymentToken.safeTransfer(recipient, amount);
        emit WithdrawByPercent(msg.sender, recipient, percent, amount);
    }

   

    function rescueTokens(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(recipient != address(0), "Cannot withdraw to zero address");
        require(amount > 0, "Amount must be greater than zero");

        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            require(success, "Native currency transfer failed");
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
