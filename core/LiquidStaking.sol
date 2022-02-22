//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { ERC20 } from "OpenZeppelin/openzeppelin-contracts@4.4.1/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "OpenZeppelin/openzeppelin-contracts@4.4.1/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "OpenZeppelin/openzeppelin-contracts@4.4.1/contracts/access/Ownable.sol";
import { StakingContract } from "../lib/StakingContract.sol";
import { LockedONE } from "./LockedONE.sol";

contract LiquidStaking is StakingContract, Ownable, ERC20("LiquidONE", "drONE") {
    event Staked(address user, uint256 amount);
    event Unstaked(address user, uint256 amount);
    event Claimed(address user, uint256 amount);
    event RebalanceInitiated(
        uint256 rebalanceNumber,
        address[] delegateAddresses_,
        uint256[] delegatePercentages_
    );
    event RebalanceCompleted(uint256 rebalanceNumber);
    event RewardsCollected(uint256 totalRewards);

    uint256 totalRebalances; // number of rebalances so far, starts with 0
    uint256 constant BASE = 1e4;
    uint256 END_EPOCH = 7;
    uint256 amountStakedDuringRebalance = 0;
    LockedONE public immutable nONE;
    uint256 public totalClaimableBalance; // pending undelegations to pay out fucntion -> need to adjust it with claimable balance /// Not using it in the code
    uint256 public totalStaked;
    uint256 public collectedFee; // so far
    uint256 public rewardFee; // factor of the collected fee (% / bps)

    uint256 public rebalanceInitiateEpoch;
    uint256 public rebalanceCompleteEpoch;
    address[] public validatorAddresses;
    bool public isRebalancing;
    mapping(address => uint256) public accruedPendingDelegations;
    uint256 public totalAccruedPendingDelegations;
    mapping(address => uint256) public validatorPercentages;
    mapping(address => uint256) public validatorStakedAmount;
    address public feeCollector;
    address rebalancer;

    constructor(
        address[] memory validatorAddresses_,
        uint256[] memory validatorPercentages_,
        address rebalancer_
    ) {
        require(
            validatorAddresses_.length == validatorPercentages_.length,
            "The length of arrays should be equal"
        );
        validatorAddresses = validatorAddresses_;
        uint256 _totalDelegationPercentages;
        uint256 _validatorsLength = validatorAddresses.length;

        for (uint256 i = 0; i < _validatorsLength; i++) {
            _totalDelegationPercentages = _totalDelegationPercentages + validatorPercentages_[i];
            validatorPercentages[validatorAddresses_[i]] = validatorPercentages_[i];
        }
        require(_totalDelegationPercentages == 1e4, "Wrong percentage inputs");
        nONE = new LockedONE();
        rebalancer = rebalancer_;
        isRebalancing = false;
    }

    function reDelegate(uint256 tokenId_) external {
        uint256 amount_ = nONE.getAmountOfTokenByIndex(tokenId_);
        uint256 epoch_ = nONE.getMintedEpochOfTokenByIndex(tokenId_);
        require(msg.sender == nONE.ownerOf(tokenId_), "Only token owner can claim this token");
        require(amount_ >= 1e20, "Only Claimable, min amount is 100 ONE");
        require(_epoch() > epoch_, "Try again on Next epoch");
        stakeRewards();
        uint256 _supply = totalSupply();
        //
        uint256 _toMint = _supply == 0 ? amount_ : ((amount_ * _supply) / totalStaked);
        uint256 _toBurn = tokenId_;
        _stake(amount_);
        _updateClaimableBalance(false);
        totalStaked = totalStaked + amount_;
        nONE.burn(_toBurn);
        _mint(msg.sender, _toMint);

        emit Staked(msg.sender, _toMint);
    }

    function stake(uint256 amount_) external payable {
        require(amount_ >= 1e20, "Minimum amount to stake is 100 ONE");
        uint256 _supply = totalSupply();
        stakeRewards();
        uint256 _toMint = _supply == 0 ? amount_ : ((amount_ * _supply) / totalStaked);
        _stake(amount_);
        totalStaked = totalStaked + amount_;
        _updateClaimableBalance(false);
        _mint(msg.sender, _toMint);
        emit Staked(msg.sender, _toMint);
    }

    function unstake(uint256 amount_) external {
        // The user should have more drONEs than the input amount
        require(balanceOf(msg.sender) >= amount_, "Not enough drONE");
        stakeRewards();
        uint256 _toUnstake = (amount_ * totalStaked) / totalSupply();
        _unstake(_toUnstake);
        _updateClaimableBalance(false);
        uint256 _endEpoch;
        if (isRebalancing) {
            _endEpoch = _epoch() + 1 + END_EPOCH;
        } else {
            _endEpoch = _epoch() + END_EPOCH;
        }
        nONE.mint(msg.sender, _epoch(), _endEpoch, _toUnstake);
        _burn(msg.sender, amount_);

        totalStaked = totalStaked - _toUnstake;
        emit Unstaked(msg.sender, amount_);
    }

    function claim(uint256 tokenId_) external {
        // need to check if he is the owner of the token ID
        _updateClaimableBalance(false);
        stakeRewards();
        require(nONE.checkOwnerOrApproved(msg.sender, tokenId_ ), "Not Owner and not approved");
        uint256 amount_ = nONE.getAmountOfTokenByIndex(tokenId_);
        require(amount_ <= totalClaimableBalance, "Not enough ONE in the pool");
        require(
            _epoch() > nONE.getClaimableEpochOfTokenByIndex(tokenId_),
            " Your Token is yet to be matured for conversion "
        );
        nONE.burn(tokenId_);
        totalClaimableBalance = totalClaimableBalance - amount_;

        (bool success, ) = payable(msg.sender).call{ value: amount_ }("");
        require(success, "Failed to send Ether");
        emit Claimed(msg.sender, amount_);
    }

    function stakeRewards() public {
        uint256 contractBalancePreReward = address(this).balance;
        _collectRewards();
        uint256 contractBalancePostReward = address(this).balance;
        uint256 rewards = contractBalancePostReward - contractBalancePreReward;
        collectedFee += (rewards * rewardFee) / BASE;
        rewards = (rewards * (BASE - rewardFee)) / BASE;
        totalStaked = totalStaked + rewards;
        uint256 _validatorsLength = validatorAddresses.length;
        for (uint256 i = 0; i < _validatorsLength; i++) {
            uint256 _rewardStake = (validatorPercentages[validatorAddresses[i]] * rewards) / BASE;
            accruedPendingDelegations[validatorAddresses[i]] =
                accruedPendingDelegations[validatorAddresses[i]] +
                _rewardStake;
            totalAccruedPendingDelegations = totalAccruedPendingDelegations + _rewardStake;
        }
        // Net of fees
        emit RewardsCollected(rewards);
        delete rewards;
    }

    function rebalanceInitiate(
        address[] memory delegateAddresses_,
        uint256[] memory delegatePercentages_
    ) external onlyRebalancer {
        //checks:
        //epoch greater than last
        //lengths equal
        //undelegatePercentages_[i] <= validatorPercentages[i]
        //
        uint256 _currentEpoch = _epoch();
        uint256 i;
        require(
            _currentEpoch > rebalanceInitiateEpoch,
            "Rebalance already initiated in this epoch"
        );
        require(
            rebalanceCompleteEpoch >= rebalanceInitiateEpoch,
            "Previous rebalance not completed yet"
        );
        require(
            delegateAddresses_.length == delegatePercentages_.length,
            "Length of delegateAddresses_ and delegatePercentages_ should be equal"
        );
        stakeRewards();

        uint256 amount_to_delegate = address(this).balance - totalClaimableBalance - collectedFee;
        _stake(amount_to_delegate);

        uint256 _totalDelegationPercentages;
        for (i = 0; i < delegatePercentages_.length; i++) {
            _totalDelegationPercentages = _totalDelegationPercentages + delegatePercentages_[i];
        }
        require(_totalDelegationPercentages == 10000, "Total delegation should be 100 percent");

        uint256 amount_to_undelegate = totalStaked;
        _unstake(amount_to_undelegate);
        for (i = 0; i < validatorAddresses.length; i++) {
            validatorPercentages[validatorAddresses[i]] = 0.0;
        }
        delete validatorAddresses;
        validatorAddresses = delegateAddresses_;
        for (i = 0; i < delegateAddresses_.length; i++) {
            validatorPercentages[delegateAddresses_[i]] = delegatePercentages_[i];
        }

        rebalanceInitiateEpoch = _currentEpoch;
        isRebalancing = true;

        emit RebalanceInitiated(totalRebalances++, delegateAddresses_, delegatePercentages_);
    }

    function rebalanceComplete() external onlyRebalancer {
        uint256 _currentEpoch = _epoch();
        require(isRebalancing == true, "Rebalance not initiated");
        require(_currentEpoch > rebalanceInitiateEpoch, "Cannot redelegate in current epoch");
        require(rebalanceInitiateEpoch > rebalanceCompleteEpoch, "Already completed rebalance");
        stakeRewards();
        uint256 amountToDelegate = totalStaked -
            amountStakedDuringRebalance +
            totalAccruedPendingDelegations -
            totalClaimableBalance;
        _stake(amountToDelegate);
        rebalanceCompleteEpoch = _currentEpoch;
        isRebalancing = false;
        amountStakedDuringRebalance = 0;
        emit RebalanceCompleted(totalRebalances);
    }

    function collectFee() external onlyOwner {
        uint256 _toSend = collectedFee;
        //set to 0 before sending to avoid re-entrancy
        collectedFee = 0;
        //send last to avoid re-entrancy
        payable(feeCollector).call{ value: _toSend };
    }

    function setFeeCollector(address feeCollector_) external onlyOwner {
        feeCollector = feeCollector_;
    }

    function setFee(uint256 rewardFee_) external onlyOwner {
        rewardFee = rewardFee_;
    }

    function setRebalancer(address rebalancer_) external onlyOwner {
        rebalancer = rebalancer_;
    }

    function setEndEpoch(uint256 endEpoch_) external onlyOwner {
        END_EPOCH = endEpoch_;
    }

    function _stake(uint256 amount_) internal {
        _updateClaimableBalance(true);
        uint256 _validatorsLength = validatorAddresses.length;
        for (uint256 i = 0; i < _validatorsLength; i++) {
            uint256 _toStake = (validatorPercentages[validatorAddresses[i]] * amount_) / BASE;
            if (_toStake + accruedPendingDelegations[validatorAddresses[i]] < 1e20) {
                accruedPendingDelegations[validatorAddresses[i]] += _toStake;
                totalAccruedPendingDelegations += _toStake;
            } else {
                require(
                    _delegate(
                        validatorAddresses[i],
                        (_toStake + accruedPendingDelegations[validatorAddresses[i]])
                    ),
                    "Could not delegate"
                );
                validatorStakedAmount[validatorAddresses[i]] +=
                    _toStake +
                    accruedPendingDelegations[validatorAddresses[i]];
                totalAccruedPendingDelegations =
                    totalAccruedPendingDelegations -
                    accruedPendingDelegations[validatorAddresses[i]];
                accruedPendingDelegations[validatorAddresses[i]] = 0;
                if (isRebalancing) {
                    amountStakedDuringRebalance += _toStake;
                }
            }
        }
    }

    function _unstake(uint256 amount_) internal {
        _updateClaimableBalance(false);
        if (isRebalancing) {} else {
            uint256 _validatorsLength = validatorAddresses.length;
            for (uint256 i = 0; i < _validatorsLength; i++) {
                address validator = validatorAddresses[i];
                uint256 _toUnstake = (validatorPercentages[validator] * amount_) / BASE;
                uint256 validatorPendingDelegation = accruedPendingDelegations[validator];

                uint256 totalStakedAtValidator = validatorStakedAmount[validator];
                if (_toUnstake <= validatorPendingDelegation) {
                    accruedPendingDelegations[validatorAddresses[i]] -= _toUnstake;
                    totalAccruedPendingDelegations -= _toUnstake;
                } else {
                    totalAccruedPendingDelegations -= validatorPendingDelegation;
                    accruedPendingDelegations[validator] = 0;
                    uint256 amountToUndelegate = _toUnstake - validatorPendingDelegation;
                    require(_undelegate(validator, amountToUndelegate), "Could not undelegate");
                    validatorStakedAmount[validator] -= amountToUndelegate;
                }
            }
        }
    }

    function _updateClaimableBalance(bool stake_) internal {
        totalClaimableBalance =
            address(this).balance -
            collectedFee -
            (stake_ ? msg.value : 0) -
            totalAccruedPendingDelegations;
    }

    modifier onlyRebalancer() {
        require(msg.sender == rebalancer, "Not authorized to rebalance");
        _;
    }
}
