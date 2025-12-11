import { assert } from "vitest";
import { ethers } from "ethers";
import { quoteUniswapV3 } from "../helpers/quoter";

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL!);

describe("Integration", () => {
  it("uniswap quote", async () => {
    const result = await quoteUniswapV3(
      provider,
      process.env.UNISWAP_V3_QUOTER!,
      process.env.DAI!,
      process.env.WETH!,
      3000,
      ethers.parseUnits("1", 18)
    );
    assert(result > 0n);
  });
});
