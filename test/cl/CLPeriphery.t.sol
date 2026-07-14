// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {CLMasterChef} from "../../src/core/CLMasterChef.sol";
import {ICLFactory} from "../../src/core/interfaces/ICLFactory.sol";
import {ICLNonfungiblePositionManager} from "../../src/core/interfaces/ICLNonfungiblePositionManager.sol";
import {ApexErrors} from "../../src/core/libraries/common/ApexErrors.sol";

interface ICLPoolDeployerForPeripheryTest {
    function setFactoryAddress(address factory) external;
}

interface INonfungiblePositionManagerForTest {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function mintAndStake(MintParams calldata params, address stakingReceiver)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function tokenURI(uint256 tokenId) external view returns (string memory);

    function approve(address to, uint256 tokenId) external;

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface ISwapRouterForTest {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IQuoterV2ForTest {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

contract CLPeripheryToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ApexMintAndStakeCaller {
    function mintAndStake(
        INonfungiblePositionManagerForTest nfp,
        INonfungiblePositionManagerForTest.MintParams calldata params,
        address stakingReceiver
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        return nfp.mintAndStake(params, stakingReceiver);
    }
}

contract SpoofingStakeReceiver {
    address public immutable nonfungiblePositionManager;

    constructor(address _nonfungiblePositionManager) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
    }
}

contract CLPeripheryTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    ICLFactory internal factory;
    INonfungiblePositionManagerForTest internal nfp;
    ISwapRouterForTest internal router;
    IQuoterV2ForTest internal quoter;
    CLPeripheryToken internal token0;
    CLPeripheryToken internal token1;
    CLPeripheryToken internal controllerRewardToken;
    uint256 internal rewardPerSecond;
    uint256 internal rewardEndTime;
    uint256 internal forfeitedReward;
    address internal canonicalClMasterChef;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal weth = address(0xBEEF);

    function setUp() public {
        CLPeripheryToken tokenA = new CLPeripheryToken("Token A", "TKNA");
        CLPeripheryToken tokenB = new CLPeripheryToken("Token B", "TKNB");
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        ICLPoolDeployerForPeripheryTest deployer =
            ICLPoolDeployerForPeripheryTest(deployCode("core/CLPoolDeployer.sol:CLPoolDeployer"));
        factory = ICLFactory(deployCode("core/CLFactory.sol:CLFactory", abi.encode(address(deployer), address(this))));
        deployer.setFactoryAddress(address(factory));

        nfp = INonfungiblePositionManagerForTest(
            deployCode(
                "NonfungiblePositionManager.sol:NonfungiblePositionManager",
                abi.encode(
                    address(deployer),
                    address(factory),
                    weth,
                    deployCode("periphery/SimplePositionDescriptor.sol:SimplePositionDescriptor")
                )
            )
        );
        router = ISwapRouterForTest(
            deployCode("periphery/SwapRouter.sol:SwapRouter", abi.encode(address(deployer), address(factory), weth))
        );
        quoter = IQuoterV2ForTest(
            deployCode("periphery/QuoterV2.sol:QuoterV2", abi.encode(address(deployer), address(factory), weth))
        );

        token0.mint(alice, 1_000_000 ether);
        token1.mint(alice, 1_000_000 ether);
        token0.mint(bob, 1_000 ether);
    }

    function testNonfungiblePositionManagerCreatesPoolAndMintsPosition() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);

        assertEq(factory.getPool(address(token0), address(token1), POOL_FEE), pool);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nfp.mint(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(nfp.ownerOf(tokenId), alice);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);

        (,, address positionToken0, address positionToken1, uint24 fee,,,,,,,) = nfp.positions(tokenId);
        assertEq(positionToken0, address(token0));
        assertEq(positionToken1, address(token1));
        assertEq(fee, POOL_FEE);
    }

    function testNonfungiblePositionManagerTokenURIReturnsPlainMetadata() public {
        nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId,,,) = nfp.mint(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(
            nfp.tokenURI(tokenId),
            "data:application/json;utf8,{\"name\":\"Apex CL Position #1\",\"description\":\"Apex concentrated liquidity position NFT. Position activity is available from NonfungiblePositionManager events.\"}"
        );
    }

    function testNonfungiblePositionManagerMintsAndStakesPosition() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        assertEq(clChef.mevResistanceWindow(), 120);

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId, uint128 liquidity,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );
        vm.stopPrank();

        (uint128 stakedLiquidity,,,,, address staker, uint256 stakedPid,) = clChef.userPositionInfos(tokenId);
        assertEq(nfp.ownerOf(tokenId), address(clChef));
        assertEq(staker, alice);
        assertEq(stakedPid, clChef.v3PoolAddressPid(pool));
        assertEq(clChef.balanceOf(alice), 1);
        assertEq(clChef.tokenOfOwnerByIndex(alice, 0), tokenId);
        assertEq(stakedLiquidity, liquidity);
        assertGt(liquidity, 0);
    }

    function testMintAndStakeCreditsRecipientWhenCalledByContract() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));
        ApexMintAndStakeCaller caller = new ApexMintAndStakeCaller();

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);
        token0.mint(address(caller), 1_000 ether);
        token1.mint(address(caller), 1_000 ether);

        vm.startPrank(address(caller));
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        vm.stopPrank();

        (uint256 tokenId,,,) = caller.mintAndStake(
            nfp,
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );

        (,,,,, address staker, uint256 stakedPid,) = clChef.userPositionInfos(tokenId);
        assertEq(nfp.ownerOf(tokenId), address(clChef));
        assertEq(staker, alice);
        assertEq(stakedPid, clChef.v3PoolAddressPid(pool));

        vm.prank(address(caller));
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_TOKEN_OWNER.selector, tokenId));
        clChef.withdraw(tokenId, address(caller));
    }

    function testMintAndStakeRejectsStrandingRecipients() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        vm.expectRevert(bytes("Invalid staking recipient"));
        nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(clChef),
                deadline: block.timestamp
            }),
            address(clChef)
        );
        vm.expectRevert(bytes("Invalid staking recipient"));
        nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(nfp),
                deadline: block.timestamp
            }),
            address(clChef)
        );
        vm.stopPrank();
    }

    function testMintAndStakeRejectsNonChefReceiver() public {
        nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        vm.expectRevert(bytes("Invalid staking receiver"));
        nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            bob
        );
        vm.stopPrank();
    }

    function testMintAndStakeRejectsSpoofedReceiver() public {
        nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        SpoofingStakeReceiver spoofingReceiver = new SpoofingStakeReceiver(address(nfp));

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        vm.expectRevert(bytes("Invalid staking receiver"));
        nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(spoofingReceiver)
        );
        vm.stopPrank();
    }

    function testDirectStakeCannotSpoofEncodedBeneficiary() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId,,,) = nfp.mint(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        nfp.approve(bob, tokenId);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(ApexErrors.INVALID_TRANSFER.selector);
        nfp.safeTransferFrom(alice, address(clChef), tokenId, abi.encode(bob));

        vm.prank(alice);
        nfp.safeTransferFrom(alice, address(clChef), tokenId, "");

        (,,,,, address staker, uint256 stakedPid,) = clChef.userPositionInfos(tokenId);
        assertEq(staker, alice);
        assertEq(stakedPid, clChef.v3PoolAddressPid(pool));
    }

    function testCLMasterChefManagesStakedPositionLikePancake() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId, uint128 mintedLiquidity,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );

        token0.approve(address(clChef), type(uint256).max);
        token1.approve(address(clChef), type(uint256).max);
        (uint128 addedLiquidity,,) = clChef.increaseLiquidity(
            ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        (uint128 liquidityAfterIncrease,,,,, address staker, uint256 stakedPid,) = clChef.userPositionInfos(tokenId);
        assertEq(nfp.ownerOf(tokenId), address(clChef));
        assertEq(staker, alice);
        assertEq(stakedPid, clChef.v3PoolAddressPid(pool));
        assertEq(liquidityAfterIncrease, mintedLiquidity + addedLiquidity);

        vm.startPrank(alice);
        (uint256 amount0Decreased, uint256 amount1Decreased) = clChef.decreaseLiquidity(
            ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: addedLiquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        assertGt(amount0Decreased, 0);
        assertGt(amount1Decreased, 0);

        uint256 token0BeforeCollect = token0.balanceOf(alice);
        uint256 token1BeforeCollect = token1.balanceOf(alice);
        clChef.collect(
            ICLNonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: alice, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        assertGt(token0.balanceOf(alice), token0BeforeCollect);
        assertGt(token1.balanceOf(alice), token1BeforeCollect);

        (uint128 remainingLiquidity,,,,,,,) = clChef.userPositionInfos(tokenId);
        clChef.decreaseLiquidity(
            ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: remainingLiquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        clChef.collect(
            ICLNonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: alice, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        clChef.burn(tokenId);
        vm.stopPrank();

        (uint128 burnedLiquidity,,,,, address burnedStaker, uint256 burnedPid,) = clChef.userPositionInfos(tokenId);
        assertEq(burnedLiquidity, 0);
        assertEq(burnedStaker, address(0));
        assertEq(burnedPid, 0);
        vm.expectRevert();
        nfp.ownerOf(tokenId);
    }

    function testCLMasterChefRejectsDonatedLiquidityToStakedPosition() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId,,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );
        vm.stopPrank();

        token1.mint(bob, 1_000 ether);
        vm.startPrank(bob);
        token0.approve(address(clChef), type(uint256).max);
        token1.approve(address(clChef), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ApexErrors.NOT_TOKEN_OWNER.selector, tokenId));
        clChef.increaseLiquidity(
            ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function testNonfungiblePositionManagerRejectsLiquidityDonations() public {
        nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        token1.mint(bob, 1_000 ether);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId,,,) = nfp.mint(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        vm.expectRevert(bytes("Not approved"));
        ICLNonfungiblePositionManager(address(nfp))
            .increaseLiquidity(
                ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
            );
        vm.stopPrank();
    }

    function testStakedPositionCannotBypassChefThroughNfpIncreaseLiquidity() public {
        (CLMasterChef clChef,,) = _deployRewardingCLChef(1_000, 120);
        (uint256 tokenId,) = _mintAndStake(clChef);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        vm.expectRevert(bytes("Not approved"));
        ICLNonfungiblePositionManager(address(nfp))
            .increaseLiquidity(
                ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
            );
        vm.stopPrank();

        vm.startPrank(alice);
        token0.approve(address(clChef), type(uint256).max);
        token1.approve(address(clChef), type(uint256).max);
        (uint128 addedLiquidity,,) = clChef.increaseLiquidity(
            ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertGt(addedLiquidity, 0);
    }

    function testCLMevResistancePaysNormallyAfterWindow() public {
        (CLMasterChef clChef, CLPeripheryToken apex,) = _deployRewardingCLChef(1_000, 100);
        (uint256 tokenId,) = _mintAndStake(clChef);

        vm.warp(block.timestamp + 101);

        vm.prank(alice);
        uint256 paid = clChef.harvest(tokenId, alice);

        assertGt(paid, 0);
        assertEq(apex.balanceOf(alice), paid);
        assertEq(forfeitedReward, 0);
    }

    function testCLMevResistanceIncreaseLiquiditySlashesAndResetsTimer() public {
        (CLMasterChef clChef, CLPeripheryToken apex,) = _deployRewardingCLChef(1_000, 100);
        (uint256 tokenId,) = _mintAndStake(clChef);

        vm.warp(block.timestamp + 50);

        vm.startPrank(alice);
        token0.approve(address(clChef), type(uint256).max);
        token1.approve(address(clChef), type(uint256).max);
        (uint128 addedLiquidity,,) = clChef.increaseLiquidity(
            ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        (,,,,,,, uint40 lastLiquidityChange) = clChef.userPositionInfos(tokenId);
        assertGt(addedLiquidity, 0);
        assertEq(lastLiquidityChange, uint40(block.timestamp));
        assertGt(forfeitedReward, 0);
        assertEq(apex.balanceOf(alice), 0);
        assertEq(clChef.pendingReward(tokenId), 0);

        vm.warp(block.timestamp + 101);
        vm.prank(alice);
        uint256 paid = clChef.harvest(tokenId, alice);

        assertGt(paid, 0);
        assertEq(apex.balanceOf(alice), paid);
    }

    function testCLMevResistanceIncreaseLiquidityPaysMatureRewardsBeforeReset() public {
        (CLMasterChef clChef, CLPeripheryToken apex,) = _deployRewardingCLChef(1_000, 100);
        (uint256 tokenId,) = _mintAndStake(clChef);

        vm.warp(block.timestamp + 101);

        vm.startPrank(alice);
        token0.approve(address(clChef), type(uint256).max);
        token1.approve(address(clChef), type(uint256).max);
        clChef.increaseLiquidity(
            ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        uint256 matureReward = apex.balanceOf(alice);
        assertGt(matureReward, 0);
        assertEq(forfeitedReward, 0);

        vm.warp(block.timestamp + 50);
        uint256 paid = clChef.harvest(tokenId, alice);
        vm.stopPrank();

        assertEq(paid, 0);
        assertEq(apex.balanceOf(alice), matureReward);
        assertGt(forfeitedReward, 0);
    }

    function testCLMevResistanceDecreaseLiquiditySlashesAndResetsTimer() public {
        (CLMasterChef clChef, CLPeripheryToken apex,) = _deployRewardingCLChef(1_000, 100);
        (uint256 tokenId, uint128 liquidity) = _mintAndStake(clChef);

        vm.warp(block.timestamp + 50);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = clChef.decreaseLiquidity(
            ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity / 2, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );

        (,,,,,,, uint40 lastLiquidityChange) = clChef.userPositionInfos(tokenId);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(lastLiquidityChange, uint40(block.timestamp));
        assertGt(forfeitedReward, 0);
        assertEq(apex.balanceOf(alice), 0);
        assertEq(clChef.pendingReward(tokenId), 0);

        vm.warp(block.timestamp + 101);
        vm.prank(alice);
        uint256 paid = clChef.harvest(tokenId, alice);

        assertGt(paid, 0);
        assertEq(apex.balanceOf(alice), paid);
    }

    function testCLMevResistanceDecreaseLiquidityPaysMatureRewardsBeforeReset() public {
        (CLMasterChef clChef, CLPeripheryToken apex,) = _deployRewardingCLChef(1_000, 100);
        (uint256 tokenId, uint128 liquidity) = _mintAndStake(clChef);

        vm.warp(block.timestamp + 101);

        vm.prank(alice);
        clChef.decreaseLiquidity(
            ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity / 2, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );

        uint256 matureReward = apex.balanceOf(alice);
        assertGt(matureReward, 0);
        assertEq(forfeitedReward, 0);

        vm.warp(block.timestamp + 50);
        vm.prank(alice);
        uint256 paid = clChef.harvest(tokenId, alice);

        assertEq(paid, 0);
        assertEq(apex.balanceOf(alice), matureReward);
        assertGt(forfeitedReward, 0);
    }

    function testCLMevResistanceUpdateLiquidityDoesNotSlashOrResetTimer() public {
        (CLMasterChef clChef, CLPeripheryToken apex,) = _deployRewardingCLChef(1_000, 100);
        (uint256 tokenId,) = _mintAndStake(clChef);
        (,,,,,,, uint40 initialLastLiquidityChange) = clChef.userPositionInfos(tokenId);

        vm.warp(block.timestamp + 50);
        vm.prank(bob);
        clChef.updateLiquidity(tokenId);

        (,,,,,,, uint40 lastLiquidityChange) = clChef.userPositionInfos(tokenId);
        assertEq(lastLiquidityChange, initialLastLiquidityChange);
        assertEq(forfeitedReward, 0);
        assertEq(clChef.pendingReward(tokenId), 0);

        vm.warp(uint256(initialLastLiquidityChange) + 101);
        vm.prank(alice);
        uint256 paid = clChef.harvest(tokenId, alice);

        assertGt(paid, 0);
        assertEq(apex.balanceOf(alice), paid);
        assertEq(forfeitedReward, 0);
    }

    function testCLMevResistanceZeroWindowDoesNotSlash() public {
        (CLMasterChef clChef, CLPeripheryToken apex,) = _deployRewardingCLChef(1_000, 0);
        (uint256 tokenId,) = _mintAndStake(clChef);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 paid = clChef.harvest(tokenId, alice);

        assertGt(paid, 0);
        assertEq(apex.balanceOf(alice), paid);
        assertEq(forfeitedReward, 0);
    }

    function testStakedPositionCanCloseCollectRewardsAndBurnThroughMulticall() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken apex = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(apex), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 1_000);
        controllerRewardToken = apex;
        rewardPerSecond = 1 ether * 1e12;
        rewardEndTime = block.timestamp + 100;
        apex.mint(address(this), 100 ether);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId, uint128 liquidity,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 121);

        uint256 token0Before = token0.balanceOf(alice);
        uint256 token1Before = token1.balanceOf(alice);
        uint256 rewardBefore = apex.balanceOf(alice);

        bytes[] memory data = new bytes[](4);
        data[0] = abi.encodeCall(CLMasterChef.harvest, (tokenId, alice));
        data[1] = abi.encodeCall(
            CLMasterChef.decreaseLiquidity,
            (ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                }))
        );
        data[2] = abi.encodeCall(
            CLMasterChef.collectTo,
            (
                ICLNonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(0),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                }),
                alice
            )
        );
        data[3] = abi.encodeCall(CLMasterChef.burn, (tokenId));

        vm.prank(alice);
        clChef.multicall(data);

        assertGt(token0.balanceOf(alice), token0Before);
        assertGt(token1.balanceOf(alice), token1Before);
        assertGt(apex.balanceOf(alice), rewardBefore);
        (uint128 burnedLiquidity,,,,, address burnedStaker, uint256 burnedPid,) = clChef.userPositionInfos(tokenId);
        assertEq(burnedLiquidity, 0);
        assertEq(burnedStaker, address(0));
        assertEq(burnedPid, 0);
        vm.expectRevert();
        nfp.ownerOf(tokenId);
    }

    function testStakedPositionCanCloseAndBurnThroughMulticallWithoutRewards() public {
        address pool =
            nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        CLPeripheryToken rewardToken = new CLPeripheryToken("Apex", "APEX");
        CLMasterChef clChef = new CLMasterChef(address(rewardToken), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);

        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId, uint128 liquidity,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );

        bytes[] memory data = new bytes[](4);
        data[0] = abi.encodeCall(CLMasterChef.harvest, (tokenId, alice));
        data[1] = abi.encodeCall(
            CLMasterChef.decreaseLiquidity,
            (ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                }))
        );
        data[2] = abi.encodeCall(
            CLMasterChef.collectTo,
            (
                ICLNonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(0),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                }),
                alice
            )
        );
        data[3] = abi.encodeCall(CLMasterChef.burn, (tokenId));

        clChef.multicall(data);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(alice), 0);
        (uint128 burnedLiquidity,,,,, address burnedStaker, uint256 burnedPid,) = clChef.userPositionInfos(tokenId);
        assertEq(burnedLiquidity, 0);
        assertEq(burnedStaker, address(0));
        assertEq(burnedPid, 0);
        vm.expectRevert();
        nfp.ownerOf(tokenId);
    }

    function testCollectToForwardsApexWhenApexIsPoolToken() public {
        CLPeripheryToken apex = new CLPeripheryToken("Apex", "APEX");
        apex.mint(alice, 1_000_000 ether);
        (address pairToken0, address pairToken1) =
            address(apex) < address(token1) ? (address(apex), address(token1)) : (address(token1), address(apex));
        address pool = nfp.createAndInitializePoolIfNecessary(pairToken0, pairToken1, POOL_FEE, SQRT_PRICE_1_1);
        CLMasterChef clChef = new CLMasterChef(address(apex), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 0);

        vm.startPrank(alice);
        apex.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId, uint128 liquidity,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: pairToken0,
                token1: pairToken1,
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );

        uint256 apexBefore = apex.balanceOf(alice);
        clChef.decreaseLiquidity(
            ICLNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        clChef.collectTo(
            ICLNonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(0), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            }),
            alice
        );
        vm.stopPrank();

        assertGt(apex.balanceOf(alice), apexBefore);
        assertEq(apex.balanceOf(address(clChef)), 0);
    }

    function testIncreaseLiquidityDoesNotUsePendingApexRewardAsPoolTokenPayment() public {
        CLPeripheryToken apex = new CLPeripheryToken("Apex", "APEX");
        apex.mint(alice, 1_000_000 ether);
        (address pairToken0, address pairToken1) =
            address(apex) < address(token1) ? (address(apex), address(token1)) : (address(token1), address(apex));
        address pool = nfp.createAndInitializePoolIfNecessary(pairToken0, pairToken1, POOL_FEE, SQRT_PRICE_1_1);
        CLMasterChef clChef = new CLMasterChef(address(apex), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, 1_000);
        controllerRewardToken = apex;
        rewardPerSecond = 1 ether * 1e12;
        rewardEndTime = block.timestamp + 1_000;
        apex.mint(address(this), 1_000 ether);

        vm.startPrank(alice);
        apex.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (uint256 tokenId,,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: pairToken0,
                token1: pairToken1,
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(clChef)
        );

        apex.transfer(bob, apex.balanceOf(alice));
        vm.warp(block.timestamp + 101);

        apex.approve(address(clChef), type(uint256).max);
        token1.approve(address(clChef), type(uint256).max);
        uint256 amount0Desired = pairToken0 == address(apex) ? 1 : 100 ether;
        uint256 amount1Desired = pairToken1 == address(apex) ? 1 : 100 ether;
        vm.expectRevert();
        clChef.increaseLiquidity(
            ICLNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(apex.balanceOf(alice), 0);
        assertEq(forfeitedReward, 0);
    }

    function _deployRewardingCLChef(uint256 _allocPoint, uint32 _mevWindow)
        internal
        returns (CLMasterChef clChef, CLPeripheryToken apex, address pool)
    {
        pool = nfp.createAndInitializePoolIfNecessary(address(token0), address(token1), POOL_FEE, SQRT_PRICE_1_1);
        apex = new CLPeripheryToken("Apex", "APEX");
        clChef = new CLMasterChef(address(apex), address(this), address(nfp));
        canonicalClMasterChef = address(clChef);
        address lmPoolDeployer = deployCode("core/LmPoolDeployer.sol:LmPoolDeployer", abi.encode(address(clChef)));

        clChef.setLmPoolDeployer(lmPoolDeployer);
        factory.setLmPoolDeployer(lmPoolDeployer);
        clChef.addPool(pool, _allocPoint);
        clChef.setMevResistanceWindow(_mevWindow);

        controllerRewardToken = apex;
        rewardPerSecond = 1 ether * 1e12;
        rewardEndTime = block.timestamp + 1_000;
        forfeitedReward = 0;
        apex.mint(address(this), 1_000 ether);
    }

    function _mintAndStake(CLMasterChef _clChef) internal returns (uint256 tokenId, uint128 liquidity) {
        vm.startPrank(alice);
        token0.approve(address(nfp), type(uint256).max);
        token1.approve(address(nfp), type(uint256).max);
        (tokenId, liquidity,,) = nfp.mintAndStake(
            INonfungiblePositionManagerForTest.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1_000 ether,
                amount1Desired: 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp
            }),
            address(_clChef)
        );
        vm.stopPrank();
    }

    function payReward(address, address to, uint256 amount) external returns (uint256 paid) {
        paid = amount;
        if (paid != 0) require(controllerRewardToken.transfer(to, paid), "reward transfer failed");
    }

    function forfeitReward(address, uint256 amount) external returns (uint256 forfeited) {
        forfeitedReward += amount;
        return amount;
    }

    function getCLMasterChef() external view returns (address) {
        return canonicalClMasterChef;
    }

    function getLatestPeriodInfo(address) external view returns (uint256, uint256) {
        return (rewardPerSecond, rewardEndTime);
    }

    function testSwapRouterAndQuoterUseApexPool() public {
        testNonfungiblePositionManagerCreatesPoolAndMintsPosition();

        uint256 amountIn = 1 ether;
        (uint256 quotedAmountOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2ForTest.QuoteExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                amountIn: amountIn,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            })
        );

        vm.startPrank(bob);
        token0.approve(address(router), amountIn);
        uint256 amountOut = router.exactInputSingle(
            ISwapRouterForTest.ExactInputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                fee: POOL_FEE,
                recipient: bob,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        assertGt(quotedAmountOut, 0);
        assertEq(amountOut, quotedAmountOut);
        assertEq(token1.balanceOf(bob), amountOut);
    }
}
