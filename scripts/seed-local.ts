/**
 * Seeds a local Hardhat node with realistic DirectoryEscrow activity spread over ~3 weeks:
 * creates, accepts, completes, cancels, refunds and expires offers (time-travelling for expiry).
 *
 *   pnpm node:local     # terminal 1: Hardhat node (chain 31337) starting 60 days ago
 *   pnpm deploy:local   # mock ETH/USD feed + Escrow (deterministic addresses on a fresh node)
 *   pnpm seed:local
 *
 * ESCROW_ADDRESS / FEED_ADDRESS override the default (first deployment on a fresh node) addresses.
 * Local only: refuses to run on any chain other than 31337.
 */
import { network } from "hardhat"

const ESCROW = process.env.ESCROW_ADDRESS ?? "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
const FEED = process.env.FEED_ADDRESS ?? "0x5FbDB2315678afecb367f032d93F642f64180aa3"
const DAY = 86_400
const SELL = 0
const BUY = 1

const { ethers } = await network.connect()
const { chainId } = await ethers.provider.getNetwork()
if (chainId !== 31337n) throw new Error(`seed-local only runs on a local chain (got chainId ${chainId})`)

const escrow = await ethers.getContractAt("Escrow", ESCROW)
const feed = await ethers.getContractAt("MockV3Aggregator", FEED)
const users = (await ethers.getSigners()).slice(1, 9)
const settlement = Number(await escrow.settlementPeriod())

let seed = 42
const rand = () => ((seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31)
const pick = <T>(xs: T[]) => xs[Math.floor(rand() * xs.length)]
let price = 2_000

async function travel(seconds: number) {
    await ethers.provider.send("evm_increaseTime", [seconds])
    await ethers.provider.send("evm_mine", [])
    // Keep the mock feed fresh so createOffer's staleness check passes, with a little drift.
    price = Math.max(1_200, price * (1 + (rand() - 0.5) * 0.06))
    await (await feed.updateAnswer(BigInt(Math.round(price * 1e8)))).wait()
}

type Pending = { id: bigint; buyer: (typeof users)[number]; seller: (typeof users)[number] }
const accepted: Pending[] = []
const stale: Pending[] = []
const counts: Record<string, number> = {}
const bump = (k: string) => (counts[k] = (counts[k] ?? 0) + 1)

// 21 simulated days of activity (the localDev chain starts 60 days in the past).
for (let day = 0; day < 21; day++) {
    await travel(DAY - 3_600 + Math.floor(rand() * 7_200))
    const n = 1 + Math.floor(rand() * 4)
    for (let i = 0; i < n; i++) {
        const creator = pick(users)
        let other = pick(users)
        while (other === creator) other = pick(users)
        const side = rand() < 0.5 ? SELL : BUY
        const amount = ethers.parseEther((0.05 + rand() * 2).toFixed(3))
        await (await escrow.connect(creator).createOffer(side, ethers.ZeroAddress, amount, { value: side === BUY ? amount : 0n })).wait()
        const id = await escrow.offerCount()
        bump("created")
        const r = rand()
        if (r < 0.15) {
            await (await escrow.connect(creator).cancelOffer(id)).wait()
            bump("cancelled")
            continue
        }
        if (r < 0.25) continue // left open
        await (await escrow.connect(other).acceptOffer(id, { value: side === SELL ? amount : 0n })).wait()
        bump("accepted")
        const buyer = side === BUY ? creator : other
        const seller = side === BUY ? other : creator
        accepted.push({ id, buyer, seller })
    }
    // Settle some accepted offers each day; leave others to expire.
    for (const p of accepted.splice(0)) {
        const r = rand()
        if (r < 0.55) {
            await (await escrow.connect(p.buyer).completeSale(p.id)).wait()
            bump("completed")
        } else if (r < 0.7) {
            await (await escrow.connect(p.seller).refund(p.id)).wait()
            bump("refunded")
        } else if (r < 0.85) {
            accepted.push(p) // still pending; may be settled tomorrow
        } else {
            stale.push(p)
        }
    }
    // Expire anything whose settlement period has passed: half by Automation, half by expireOffer.
    if (stale.length && day % 5 === 4) {
        await travel(settlement)
        const [needed, data] = await escrow.checkUpkeep("0x")
        if (needed) {
            const ids = ethers.AbiCoder.defaultAbiCoder().decode(["uint256[]"], data)[0] as bigint[]
            await (await escrow.connect(users[0]).performUpkeep(data)).wait()
            counts.expired = (counts.expired ?? 0) + ids.length
            stale.length = 0
            accepted.length = 0 // anything else accepted before travel was expired too
        }
    }
}

// Catch the chain up to (just before) wall-clock time so the frontend's "last 30 days" view is populated.
const latest = (await ethers.provider.getBlock("latest"))!.timestamp
const gap = Math.floor(Date.now() / 1000) - 600 - latest
if (gap > 0) await travel(gap)

console.log("Seeded offers:", counts, "offerCount:", (await escrow.offerCount()).toString())
