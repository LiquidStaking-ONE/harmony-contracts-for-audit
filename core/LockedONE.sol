//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "OpenZeppelin/openzeppelin-contracts@4.4.1/contracts/token/ERC721/ERC721.sol";
import "OpenZeppelin/openzeppelin-contracts@4.4.1/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "OpenZeppelin/openzeppelin-contracts@4.4.1/contracts/access/Ownable.sol";

contract LockedONE is
    ERC721Enumerable,
    Ownable {
    uint256 private _tokenCounter;

    struct NonFungibleONE {
        uint256 mintedAtEpoch;
        uint256 amount;
        uint256 claimableAtEpoch;
    }

    mapping(uint256 => NonFungibleONE) private _tokenIdToNonFungibleONE;

    constructor() ERC721("nft ONE", "nONE")
    {
        _tokenCounter = 0;
    }

    function mint(
        address user_,
        uint256 epoch_,
        uint256 endEpoch_,
        uint256 amount_
    ) external onlyOwner {
        uint256 newTokenId = _tokenCounter;
        bool flag = false;
        uint256 length = this.balanceOf(user_);

        for (uint256 index = 0; index < length; index++) {
            uint256 userTokenID = tokenOfOwnerByIndex(user_, index);
            if (
                getMintedEpochOfTokenByIndex(userTokenID) == epoch_ &&
                getClaimableEpochOfTokenByIndex(userTokenID) == endEpoch_
            ) {
                setAmountOfTokenByIndex(userTokenID, amount_);
                flag = true;
                return;
            }
        }
        if (!flag) {
            NonFungibleONE memory nfo = NonFungibleONE(epoch_, amount_, endEpoch_);
            addNFO(newTokenId, nfo);
            _mint(user_, newTokenId);
            _tokenCounter = _tokenCounter + 1;
        }
    }

    function burn(uint256 tokenId_) external onlyOwner {
        _burn(tokenId_);
        delete _tokenIdToNonFungibleONE[tokenId_];
    }

    function getMintedEpochOfTokenByIndex(uint256 tokenId) public view returns (uint256) {
        require(_tokenIdToNonFungibleONE[tokenId].mintedAtEpoch != 0, "TokenID doesnt exist");
        return _tokenIdToNonFungibleONE[tokenId].mintedAtEpoch;
    }

    function getClaimableEpochOfTokenByIndex(uint256 tokenId) public view returns (uint256) {
        require(_tokenIdToNonFungibleONE[tokenId].mintedAtEpoch != 0, "TokenID doesnt exist");
        return _tokenIdToNonFungibleONE[tokenId].claimableAtEpoch;
    }

    function getAmountOfTokenByIndex(uint256 tokenId) public view returns (uint256) {
        require(_tokenIdToNonFungibleONE[tokenId].mintedAtEpoch != 0, "TokenID doesnt exist");
        return _tokenIdToNonFungibleONE[tokenId].amount;
    }

    function setAmountOfTokenByIndex(uint256 tokenId, uint256 amount_) private {
        require(_tokenIdToNonFungibleONE[tokenId].mintedAtEpoch != 0, "TokenID doesnt exist");
        _tokenIdToNonFungibleONE[tokenId].amount += amount_;
    }

    function addNFO(uint256 tokenId, NonFungibleONE memory nfo_) private {
        require(_tokenIdToNonFungibleONE[tokenId].mintedAtEpoch == 0, "TokenID already exist");
        _tokenIdToNonFungibleONE[tokenId] = nfo_;
    }

    function checkOwnerOrApproved(address sender_, uint256 tokenId_) public view returns(bool){
      return _isApprovedOrOwner(sender_, tokenId_);
    }
}
