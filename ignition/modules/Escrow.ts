import { buildModule } from "@nomicfoundation/hardhat-ignition/modules"

/**
 * Chainlink ETH/USD price feed proxy on Ethereum Sepolia.
 * Source: https://docs.chain.link/data-feeds/using-data-feeds (Sepolia ETH/USD example)
 * and https://docs.chain.link/data-feeds/price-feeds/addresses (Ethereum Sepolia).
 */
export const SEPOLIA_ETH_USD_FEED = "0x694AA1769357215DE4FAC081bf1f309aDC325306"

/**
 * Deploys Escrow against an existing Chainlink ETH/USD feed.
 *
 * Parameters (see ignition/parameters/sepolia.json):
 *  - priceFeed:   feed proxy address (defaults to the Sepolia ETH/USD feed)
 *  - maxPriceAge: seconds before a feed answer is treated as stale (default 3h)
 *  - arbiter:     optional dispute resolver, zero address to disable
 */
export default buildModule("EscrowModule", (m) => {
    const priceFeed = m.getParameter("priceFeed", SEPOLIA_ETH_USD_FEED)
    const maxPriceAge = m.getParameter("maxPriceAge", 10_800n)
    const arbiter = m.getParameter("arbiter", "0x0000000000000000000000000000000000000000")

    const escrow = m.contract("Escrow", [priceFeed, maxPriceAge, arbiter])

    return { escrow }
})
