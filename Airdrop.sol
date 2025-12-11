// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract Airdrop is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IERC20 public immutable rewardToken;
    
    address public nft1;
    address public nft2;
    
    uint256 public nft1DailyAmount;
    uint256 public nft2DailyAmount;

    // nftAddress => tokenId => lastClaimCycleId
    mapping(address => mapping(uint256 => uint256)) public nftClaims;

    event Claimed(address indexed user, uint256 amount, uint256 cycleId);
    event Nft1Updated(address indexed oldNft, address indexed newNft);
    event Nft2Updated(address indexed oldNft, address indexed newNft);
    event Nft1DailyAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event Nft2DailyAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event ManagerAdded(address indexed manager);
    event ManagerRemoved(address indexed manager);
    event RescueTokens(address indexed token, address indexed recipient, uint256 amount);

    constructor(address _token) {
        require(_token != address(0), "Invalid token address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        rewardToken = IERC20(_token);
        
        // Initialize with default amounts (assuming 18 decimals)
        // Can be updated via setters
        nft1DailyAmount = 100 * 10**6; 
        nft2DailyAmount = 10 * 10**6;
    }

    function setNft1(address _nft) external onlyRole(MANAGER_ROLE) {
        // Allow setting to 0 to disable
        emit Nft1Updated(nft1, _nft);
        nft1 = _nft;
    }

    function setNft2(address _nft) external onlyRole(MANAGER_ROLE) {
        // Allow setting to 0 to disable
        emit Nft2Updated(nft2, _nft);
        nft2 = _nft;
    }

    function setNft1DailyAmount(uint256 _amount) external onlyRole(MANAGER_ROLE) {
        emit Nft1DailyAmountUpdated(nft1DailyAmount, _amount);
        nft1DailyAmount = _amount;
    }

    function setNft2DailyAmount(uint256 _amount) external onlyRole(MANAGER_ROLE) {
        emit Nft2DailyAmountUpdated(nft2DailyAmount, _amount);
        nft2DailyAmount = _amount;
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

    function getCurrentCycleId() public view returns (uint256) {
        // Refresh at 14:00 UTC+0
        // Unix timestamp 0 was 00:00 UTC.
        // 14:00 UTC is 14 hours after 00:00 UTC.
        // To align 14:00 UTC to be the start of a cycle (0 mod 24h), we need to shift time.
        // If T = 14:00, we want (T + offset) % 24h == 0.
        // 14 + 10 = 24 = 0 (mod 24).
        // So we add 10 hours to timestamp.
        return (block.timestamp + 10 hours) / 1 days;
    }

    function claimable(address nft, uint256 tokenId) public view returns (uint256) {
        if (nft == address(0)) return 0;
        
        uint256 cycleId = getCurrentCycleId();
        if (nftClaims[nft][tokenId] == cycleId) {
            return 0; // Already claimed for this cycle
        }

        if (nft == nft1) {
            return nft1DailyAmount;
        } else if (nft == nft2) {
            return nft2DailyAmount;
        }
        return 0;
    }

    function claim(uint256[] calldata nft1Ids, uint256[] calldata nft2Ids) external nonReentrant whenNotPaused {
        uint256 cycleId = getCurrentCycleId();
        uint256 totalClaimAmount = 0;

        // Process NFT1 claims
        if (nft1 != address(0)) {
            for (uint256 i = 0; i < nft1Ids.length; i++) {
                uint256 tokenId = nft1Ids[i];
                require(IERC721(nft1).ownerOf(tokenId) == msg.sender, "Not owner of NFT1");
                require(nftClaims[nft1][tokenId] != cycleId, "NFT1 already claimed today");
                
                nftClaims[nft1][tokenId] = cycleId;
                totalClaimAmount += nft1DailyAmount;
            }
        }

        // Process NFT2 claims
        if (nft2 != address(0)) {
            for (uint256 i = 0; i < nft2Ids.length; i++) {
                uint256 tokenId = nft2Ids[i];
                require(IERC721(nft2).ownerOf(tokenId) == msg.sender, "Not owner of NFT2");
                require(nftClaims[nft2][tokenId] != cycleId, "NFT2 already claimed today");
                
                nftClaims[nft2][tokenId] = cycleId;
                totalClaimAmount += nft2DailyAmount;
            }
        }

        require(totalClaimAmount > 0, "Nothing to claim");
        require(rewardToken.balanceOf(address(this)) >= totalClaimAmount, "Insufficient contract balance");

        // Transfer rewards directly to the NFT owner
        rewardToken.safeTransfer(msg.sender, totalClaimAmount);
        
        emit Claimed(msg.sender, totalClaimAmount, cycleId);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Rescue tokens from the contract (emergency only)
     * @dev Can rescue any token including the reward token. Use with caution.
     * @param token Token address to rescue (address(0) for native currency)
     * @param amount Amount to rescue
     * @param recipient Address to receive the tokens
     */
    function rescueTokens(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(recipient != address(0), "Cannot withdraw to zero address");
        require(amount > 0, "Amount must be greater than zero");

        if (token == address(0)) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            require(success, "Native currency transfer failed");
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
        emit RescueTokens(token, recipient, amount);
    }
}
