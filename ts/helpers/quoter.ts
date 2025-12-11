import { JsonRpcProvider } from "ethers";
import { ethers } from "ethers";

export async function quoteUniswapV3(
  provider: JsonRpcProvider,
  quoterAddress: string,
  tokenIn: string,
  tokenOut: string,
  fee: number,
  amountIn: bigint
) {
  const quoter = new ethers.Contract(
    quoterAddress,
    ["function quoteExactInputSingle(address,address,uint24,uint256,uint160) view returns (uint256)"],
    provider
  );
  return quoter.quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);
}
