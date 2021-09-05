// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "./Denominations.sol";
import "./PriceOracle.sol";
import "./interfaces/BandReference.sol";
import "./interfaces/CurveTokenInterface.sol";
import "./interfaces/FeedRegistryInterface.sol";
import "./interfaces/V1PriceOracleInterface.sol";
import "./interfaces/YVaultTokenInterface.sol";
import "../JErc20.sol";
import "../JToken.sol";
import "../Exponential.sol";
import "../EIP20Interface.sol";

contract PriceOracleProxyIB is PriceOracle, Exponential, Denominations {
    /// @notice Admin address
    address public admin;

    /// @notice Guardian address
    address public guardian;

    struct AggregatorInfo {
        /// @notice The base
        address base;
        /// @notice The quote denomination
        address quote;
        /// @notice It's being used or not.
        bool isUsed;
    }

    struct ReferenceInfo {
        /// @notice The symbol used in reference
        string symbol;
        /// @notice It's being used or not.
        bool isUsed;
    }

    /// @notice Chainlink Aggregators
    mapping(address => AggregatorInfo) public aggregators;

    /// @notice Band Reference
    mapping(address => ReferenceInfo) public references;

    /// @notice Mapping of token to y-vault token
    mapping(address => address) public yVaults;

    /// @notice Mapping of token to curve swap
    mapping(address => address) public curveSwap;

    /// @notice The v1 price oracle, maintain by CREAM
    V1PriceOracleInterface public v1PriceOracle;

    /// @notice The ChainLink registry address
    FeedRegistryInterface public reg;

    /// @notice The BAND reference address
    StdReferenceInterface public ref;

    /// @notice Quote symbol we used for BAND reference contract
    string public constant QUOTE_SYMBOL = "USD";

    address public constant y3CRVAddress = 0x9cA85572E6A3EbF24dEDd195623F188735A5179f;

    /**
     * @param admin_ The address of admin to set aggregators
     * @param v1PriceOracle_ The v1 price oracle
     * @param registry_ The address of ChainLink registry
     * @param reference_ The address of Band reference
     */
    constructor(
        address admin_,
        address v1PriceOracle_,
        address registry_,
        address reference_
    ) public {
        admin = admin_;
        v1PriceOracle = V1PriceOracleInterface(v1PriceOracle_);
        reg = FeedRegistryInterface(registry_);
        ref = StdReferenceInterface(reference_);

        yVaults[y3CRVAddress] = 0x9cA85572E6A3EbF24dEDd195623F188735A5179f; // y-vault 3Crv
        curveSwap[y3CRVAddress] = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7; // curve 3 pool
    }

    /**
     * @notice Get the underlying price of a listed jToken asset
     * @param jToken The jToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18)
     */
    function getUnderlyingPrice(JToken jToken) public view returns (uint256) {
        address underlying = JErc20(address(jToken)).underlying();

        // Handle y3Crv.
        if (underlying == y3CRVAddress) {
            uint256 yVaultPrice = YVaultV1Interface(yVaults[y3CRVAddress]).getPricePerFullShare();
            uint256 virtualPrice = CurveSwapInterface(curveSwap[y3CRVAddress]).get_virtual_price();
            return mul_(yVaultPrice, Exp({mantissa: virtualPrice}));
        }

        // Get price from ChainLink.
        AggregatorInfo storage aggregatorInfo = aggregators[underlying];
        if (aggregatorInfo.isUsed) {
            uint256 price = getPriceFromChainlink(aggregatorInfo.base, aggregatorInfo.quote);
            if (aggregatorInfo.quote == Denominations.ETH) {
                // Convert the price to USD based if it's ETH based.
                uint256 ethUsdPrice = getPriceFromChainlink(Denominations.ETH, Denominations.USD);
                price = mul_(price, Exp({mantissa: ethUsdPrice}));
            }
            return getNormalizedPrice(price, underlying);
        }

        // Get price from Band.
        ReferenceInfo storage referenceInfo = references[underlying];
        if (referenceInfo.isUsed) {
            uint256 price = getPriceFromBAND(referenceInfo.symbol);
            return getNormalizedPrice(price, underlying);
        }

        // Get price from v1.
        return getPriceFromV1(underlying);
    }

    /*** Internal fucntions ***/

    /**
     * @notice Get price from ChainLink
     * @param base The base token that ChainLink aggregator gets the price of
     * @param quote The quote token, currenlty support ETH and USD
     * @return The price, scaled by 1e18
     */
    function getPriceFromChainlink(address base, address quote) internal view returns (uint256) {
        (, int256 price, , , ) = reg.latestRoundData(base, quote);
        require(price > 0, "invalid price");

        // Extend the decimals to 1e18.
        return mul_(uint256(price), 10**(18 - uint256(reg.decimals(base, quote))));
    }

    /**
     * @notice Get price from BAND protocol.
     * @param symbol The symbol that used to get price of
     * @return The price, scaled by 1e18
     */
    function getPriceFromBAND(string memory symbol) internal view returns (uint256) {
        StdReferenceInterface.ReferenceData memory data = ref.getReferenceData(symbol, QUOTE_SYMBOL);
        require(data.rate > 0, "invalid price");

        // Price from BAND is always 1e18 base.
        return data.rate;
    }

    /**
     * @notice Normalize the price according to the token decimals.
     * @param price The original price
     * @param tokenAddress The token address
     * @return The normalized price.
     */
    function getNormalizedPrice(uint256 price, address tokenAddress) internal view returns (uint256) {
        uint256 underlyingDecimals = EIP20Interface(tokenAddress).decimals();
        return mul_(price, 10**(18 - underlyingDecimals));
    }

    /**
     * @notice Get price from v1 price oracle
     * @param token The token to get the price of
     * @return The price
     */
    function getPriceFromV1(address token) internal view returns (uint256) {
        return v1PriceOracle.assetPrices(token);
    }

    /*** Admin or guardian functions ***/

    event AggregatorUpdated(address tokenAddress, address base, address quote, bool isUsed);
    event ReferenceUpdated(address tokenAddress, string symbol, bool isUsed);
    event SetGuardian(address guardian);
    event SetAdmin(address admin);

    /**
     * @notice Set guardian for price oracle proxy
     * @param _guardian The new guardian
     */
    function _setGuardian(address _guardian) external {
        require(msg.sender == admin, "only the admin may set new guardian");
        guardian = _guardian;
        emit SetGuardian(guardian);
    }

    /**
     * @notice Set admin for price oracle proxy
     * @param _admin The new admin
     */
    function _setAdmin(address _admin) external {
        require(msg.sender == admin, "only the admin may set new admin");
        admin = _admin;
        emit SetAdmin(admin);
    }

    /**
     * @notice Set ChainLink aggregators for multiple tokens
     * @param tokenAddresses The list of underlying tokens
     * @param bases The list of ChainLink aggregator bases
     * @param quotes The list of ChainLink aggregator quotes, currently support 'ETH' and 'USD'
     */
    function _setAggregators(
        address[] calldata tokenAddresses,
        address[] calldata bases,
        address[] calldata quotes
    ) external {
        require(msg.sender == admin || msg.sender == guardian, "only the admin or guardian may set the aggregators");
        require(tokenAddresses.length == bases.length && tokenAddresses.length == quotes.length, "mismatched data");
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            bool isUsed;
            if (bases[i] != address(0)) {
                require(msg.sender == admin, "guardian may only clear the aggregator");
                require(quotes[i] == Denominations.ETH || quotes[i] == Denominations.USD, "unsupported denomination");
                isUsed = true;

                // Make sure the aggregator exists.
                address aggregator = reg.getFeed(bases[i], quotes[i]);
                require(reg.isFeedEnabled(aggregator), "aggregator not enabled");
            }
            aggregators[tokenAddresses[i]] = AggregatorInfo({base: bases[i], quote: quotes[i], isUsed: isUsed});
            emit AggregatorUpdated(tokenAddresses[i], bases[i], quotes[i], isUsed);
        }
    }

    /**
     * @notice Set Band references for multiple tokens
     * @param tokenAddresses The list of underlying tokens
     * @param symbols The list of symbols used by Band reference
     */
    function _setReferences(address[] calldata tokenAddresses, string[] calldata symbols) external {
        require(msg.sender == admin || msg.sender == guardian, "only the admin or guardian may set the references");
        require(tokenAddresses.length == symbols.length, "mismatched data");
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            bool isUsed;
            if (bytes(symbols[i]).length != 0) {
                require(msg.sender == admin, "guardian may only clear the reference");
                isUsed = true;

                // Make sure we could get the price.
                getPriceFromBAND(symbols[i]);
            }

            references[tokenAddresses[i]] = ReferenceInfo({symbol: symbols[i], isUsed: isUsed});
            emit ReferenceUpdated(tokenAddresses[i], symbols[i], isUsed);
        }
    }
}
