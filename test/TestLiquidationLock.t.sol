// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;
import "forge-std/Test.sol";

import "../src/aggregators/gmxV2/GmxV2Adapter.sol";
import "../src/aggregators/gmxV2/libraries/LibGmxV2.sol";
import "../src/test/MockGmxV2Reader.sol";

contract MockExchangeRouter {
    function setSavedCallbackContract(address, address) external {}
    
    function createOrder(IExchangeRouter.CreateOrderParams calldata) external returns (bytes32) {
        return keccak256("successful_liquidation_order");
    }
}

interface ITestProxyFactory {
    function createProxy(uint256, address, address, bool) external returns (address);
    function upgradeTo(uint256, address) external;
    function setProjectConfig(uint256, uint256[] memory) external;
    function setProjectAssetConfig(uint256, address, uint256[] memory) external;
    function setBorrowConfig(uint256, address, uint8, uint256) external;
    function setKeeper(address, bool) external;
}

interface IGmxV2AdapterTest {
    struct OrderCreateParams {
        bytes swapPath;
        uint256 initialCollateralAmount;
        uint256 tokenOutMinAmount;
        uint256 borrowCollateralAmount;
        uint256 sizeDeltaUsd;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        IOrder.OrderType orderType;
    }
    struct Prices {
        uint256 collateralPrice;
        uint256 indexTokenPrice;
        uint256 longTokenPrice;
        uint256 shortTokenPrice;
    }
    function placeOrder(OrderCreateParams memory) external payable returns (bytes32);
    function liquidatePosition(Prices memory, uint256, uint256) external payable;
}

contract TestLiquidationLock is Test {
    uint256 constant FORK_BLOCK    = 144707133;
    uint256 constant PROJECT_ID_V2 = 2;

    ITestProxyFactory constant FACTORY = ITestProxyFactory(0x2ff2f1D9826ae2410979ae19B88c361073Ab0918);
    address constant ADMIN   = 0xc2D28778447B1B0B2Ae3aD17dC6616b546FBBeBb;
    address constant WETH    = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC    = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant MARKET  = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address constant ORDER_VAULT    = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    address constant DATA_STORE     = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant REFERRAL_STORE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
    address constant SWAP_ROUTER    = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    MockGmxV2Reader    mockReader;
    MockExchangeRouter mockExRouter;
    address adapter;
    address user;

    function addrToConfig(address a) internal pure returns (uint256) {
        return uint256(bytes32(bytes20(uint160(a))));
    }

    function setUp() public {
        vm.createSelectFork(("RPC_URL"), FORK_BLOCK);

        user = makeAddr("user");
        vm.deal(user, 100 ether);
        vm.deal(ADMIN, 1 ether);

        mockReader   = new MockGmxV2Reader();
        mockExRouter = new MockExchangeRouter();

        vm.startPrank(ADMIN);
        GmxV2Adapter adapterImp = new GmxV2Adapter();
        FACTORY.upgradeTo(PROJECT_ID_V2, address(adapterImp));

        uint256[] memory projectConfig = new uint256[](12);
        projectConfig[0]  = addrToConfig(SWAP_ROUTER);
        projectConfig[1]  = addrToConfig(address(mockExRouter));
        projectConfig[2]  = addrToConfig(ORDER_VAULT);
        projectConfig[3]  = addrToConfig(DATA_STORE);
        projectConfig[4]  = addrToConfig(REFERRAL_STORE);
        projectConfig[5]  = addrToConfig(address(mockReader));
        projectConfig[6]  = addrToConfig(0xcEC7Aa1402CEc258dBEefa74cdf9393E33D15984);
        projectConfig[7]  = addrToConfig(0x6c3A43eB0B374Ca565F926d3E32E91e71ea48329);
        projectConfig[8]  = uint256(bytes32("muxprotocol"));
        projectConfig[9]  = 3;
        projectConfig[10] = addrToConfig(WETH);
        projectConfig[11] = 86400 * 2;
        FACTORY.setProjectConfig(PROJECT_ID_V2, projectConfig);

        uint256[] memory marketConfig = new uint256[](7);
        marketConfig[0] = 0.02e5;
        marketConfig[1] = 0.006e5;
        marketConfig[2] = 0.005e5;
        marketConfig[3] = 0;
        marketConfig[4] = 0.02e5;
        marketConfig[5] = 18;
        marketConfig[6] = 1;
        FACTORY.setProjectAssetConfig(PROJECT_ID_V2, MARKET, marketConfig);

        FACTORY.setBorrowConfig(PROJECT_ID_V2, WETH, 3, 1000 ether);
        FACTORY.setBorrowConfig(PROJECT_ID_V2, USDC, 11, 1000 ether);
        FACTORY.setKeeper(user, true);
        FACTORY.setKeeper(address(mockExRouter), true);
        vm.stopPrank();

        vm.prank(user);
        adapter = FACTORY.createProxy(PROJECT_ID_V2, WETH, MARKET, true);
    }

    function test_liquidation_flag_stuck_full_flow() public {
        // Mock all external auth-sensitive system calls
        vm.mockCall(
            address(0x6c3A43eB0B374Ca565F926d3E32E91e71ea48329),
            abi.encodeWithSignature("onPlaceLiquidateOrder(address,(uint256,uint256,uint256,uint256))"),
            abi.encode()
        );
        vm.mockCall(
            address(0x0000000000000000000000000000000000000064),
            abi.encodeWithSignature("arbBlockNumber()"),
            abi.encode(FORK_BLOCK)
        );
        vm.mockCall(
            address(0x6c3A43eB0B374Ca565F926d3E32E91e71ea48329),
            abi.encodeWithSignature("onUpdateDebt(address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"),
            abi.encode()
        );

        // Step 1: Set position size in mock reader to bypass sizeInUsd > 0 requirement
        mockReader.setSizeInUsd(10000 * 1e30);

        // Step 2: Trigger liquidation as a registered keeper
        vm.prank(user); 
        IGmxV2AdapterTest(adapter).liquidatePosition(
            IGmxV2AdapterTest.Prices({
                collateralPrice: 1700e18,
                indexTokenPrice: 1700e18,
                longTokenPrice: 1700e18,
                shortTokenPrice: 1e18
            }),
            0, 
            0  
        );

        // Step 3: Verify isLiquidating flag is set to True (Slot 45 based on storage layout)
        bytes32 isLiquidatingSlot = bytes32(uint256(45));
        uint256 flagValue = uint256(vm.load(adapter, isLiquidatingSlot));
        assertEq(flagValue, 1, "isLiquidating must be True");

        // Step 4: Simulate GMX order cancellation callback
        bytes32 realOrderKey = keccak256("successful_liquidation_order");
        IOrder.PropsV21 memory dummyProps;
        IEvent.EventLogData memory dummyLog;

        vm.prank(address(mockExRouter));
        GmxV2Adapter(payable(adapter)).afterOrderCancellation(realOrderKey, dummyProps, dummyLog);

        // Step 5: Flag remains Stuck at True because of missing reset logic in callback
        uint256 flagAfterCancel = uint256(vm.load(adapter, isLiquidatingSlot));
        assertEq(flagAfterCancel, 1, "isLiquidating still True after cancellation");

        // Step 6: Demonstration of permanent User DoS
        vm.expectRevert("Liquidating");
        vm.prank(user);
        IGmxV2AdapterTest(adapter).placeOrder(IGmxV2AdapterTest.OrderCreateParams({
            swapPath: "", 
            initialCollateralAmount: 0, 
            tokenOutMinAmount: 0,
            borrowCollateralAmount: 0, 
            sizeDeltaUsd: 0, 
            triggerPrice: 0,
            acceptablePrice: 0, 
            executionFee: 0, 
            callbackGasLimit: 0,
            orderType: IOrder.OrderType.MarketIncrease
        }));

        console.log("User account is permanently frozen");
    }
}