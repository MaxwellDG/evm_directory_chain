import { buildModule } from "@nomicfoundation/hardhat-ignition/modules"

/**
 * Local-only deployment: deploys a MockV3Aggregator ($2,000/ETH, 8 decimals)
 * and an Escrow pointing at it. Do not use on Sepolia; use EscrowModule there.
 */
export default buildModule("EscrowLocalModule", (m) => {
    const initialPrice = m.getParameter("initialPrice", 2_000n * 10n ** 8n)
    const maxPriceAge = m.getParameter("maxPriceAge", 10_800n)
    const arbiter = m.getParameter("arbiter", "0x0000000000000000000000000000000000000000")

    const priceFeed = m.contract("MockV3Aggregator", [8, initialPrice])
    const escrow = m.contract("Escrow", [priceFeed, maxPriceAge, arbiter])

    return { priceFeed, escrow }
})
