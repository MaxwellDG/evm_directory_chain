import { expect } from "chai"
import { network } from "hardhat"

const { ethers } = await network.connect()

const PRICE = 2_000n * 10n ** 8n // $2,000 with 8 decimals
const MAX_AGE = 3_600n

async function deploy() {
    const [seller, buyer, arbiter, stranger] = await ethers.getSigners()
    const feed = await ethers.deployContract("MockV3Aggregator", [8, PRICE])
    const escrow = await ethers.deployContract("Escrow", [await feed.getAddress(), MAX_AGE, arbiter.address])
    return { feed, escrow, seller, buyer, arbiter, stranger }
}

describe("Escrow", function () {
    it("runs a sell listing through create -> accept -> sale with the expected events", async function () {
        const { escrow, seller, buyer } = await deploy()
        const amount = ethers.parseEther("1.5")
        const usd = ethers.parseEther("3000")

        await expect(escrow.connect(seller).createOffer(0, ethers.ZeroAddress, amount))
            .to.emit(escrow, "OfferCreated")
            .withArgs(1n, seller.address, ethers.ZeroAddress, seller.address, 0n, amount, usd)

        await expect(escrow.connect(buyer).acceptOffer(1n, { value: amount }))
            .to.emit(escrow, "OfferAccepted")
            .withArgs(1n, seller.address, buyer.address, amount)

        await expect(escrow.connect(buyer).completeSale(1n))
            .to.emit(escrow, "SaleExecuted")
            .withArgs(1n, seller.address, buyer.address, amount, usd)
    })

    it("returns a buy offer's deposit on cancel", async function () {
        const { escrow, buyer } = await deploy()
        const amount = ethers.parseEther("1")
        await escrow.connect(buyer).createOffer(1, ethers.ZeroAddress, amount, { value: amount })
        expect(await ethers.provider.getBalance(await escrow.getAddress())).to.equal(amount)

        await expect(escrow.connect(buyer).cancelOffer(1n))
            .to.emit(escrow, "OfferCancelled")
            .withArgs(1n, buyer.address)
        expect(await ethers.provider.getBalance(await escrow.getAddress())).to.equal(0n)
    })

    it("lets the arbiter refund an accepted offer", async function () {
        const { escrow, seller, buyer, arbiter } = await deploy()
        const amount = ethers.parseEther("1")
        await escrow.connect(seller).createOffer(0, ethers.ZeroAddress, amount)
        await escrow.connect(buyer).acceptOffer(1n, { value: amount })

        await expect(escrow.connect(arbiter).refund(1n))
            .to.emit(escrow, "Refunded")
            .withArgs(1n, buyer.address, arbiter.address, amount)
    })

    it("rejects strangers and stale prices", async function () {
        const { escrow, feed, seller, buyer, stranger } = await deploy()
        const amount = ethers.parseEther("1")
        await escrow.connect(seller).createOffer(0, buyer.address, amount)

        await expect(escrow.connect(stranger).acceptOffer(1n, { value: amount })).to.be.revertedWithCustomError(
            escrow,
            "Unauthorized",
        )

        const block = await ethers.provider.getBlock("latest")
        await feed.updateRoundData(2, PRICE, BigInt(block!.timestamp) - MAX_AGE - 1n)
        await expect(escrow.connect(seller).createOffer(0, ethers.ZeroAddress, amount)).to.be.revertedWithCustomError(
            escrow,
            "StalePrice",
        )
    })
})
