import bs58 from 'bs58'
import { BigNumber, Contract, ContractTransaction } from 'ethers'
import { parseUnits } from 'ethers/lib/utils'
import { HardhatRuntimeEnvironment } from 'hardhat/types'

import { makeBytes32 } from '@layerzerolabs/devtools'
import { createGetHreByEid } from '@layerzerolabs/devtools-evm-hardhat'
import { createLogger, promptToContinue } from '@layerzerolabs/io-devtools'
import { ChainType, endpointIdToChainType, endpointIdToNetwork } from '@layerzerolabs/lz-definitions'

import layerzeroConfig from '../../layerzero.config'
import { SendResult } from '../common/types'
import { DebugLogger, KnownErrors, MSG_TYPE, isEmptyOptionsEvm } from '../common/utils'
import { getLayerZeroScanLink } from '../solana'
const logger = createLogger()

function sleep(ms: number) {
    return new Promise((resolve) => setTimeout(resolve, ms))
}

// Minimal ABI for LayerZero V2 OFT-compatible adapters (works for OFT and OFTAdapter).
// We avoid relying on Hardhat artifacts so this workspace can talk to already-deployed external OFTs/adapters.
const OFT_ABI = [
    'function token() view returns (address)',
    'function enforcedOptions(uint32 eid, uint16 msgType) view returns (bytes)',
    'function quoteSend((uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, bytes extraOptions, bytes composeMsg, bytes oftCmd) _sendParam, bool _payInLzToken) view returns ((uint256 nativeFee, uint256 lzTokenFee))',
    'function send((uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, bytes extraOptions, bytes composeMsg, bytes oftCmd) _sendParam, (uint256 nativeFee, uint256 lzTokenFee) _fee, address _refundAddress) payable',
]

const ERC20_ABI = [
    'function decimals() view returns (uint8)',
    'function allowance(address owner, address spender) view returns (uint256)',
    'function approve(address spender, uint256 amount) returns (bool)',
]
export interface EvmArgs {
    srcEid: number
    dstEid: number
    amount: string
    to: string
    minAmount?: string
    extraOptions?: string
    composeMsg?: string
    oftAddress?: string
}
export async function sendEvm(
    { srcEid, dstEid, amount, to, minAmount, extraOptions, composeMsg, oftAddress }: EvmArgs,
    hre: HardhatRuntimeEnvironment
): Promise<SendResult> {
    if (endpointIdToChainType(srcEid) !== ChainType.EVM) {
        throw new Error(`non-EVM srcEid (${srcEid}) not supported here`)
    }
    const getHreByEid = createGetHreByEid(hre)
    let srcEidHre: HardhatRuntimeEnvironment
    try {
        srcEidHre = await getHreByEid(srcEid)
    } catch (error) {
        DebugLogger.printErrorAndFixSuggestion(
            KnownErrors.ERROR_GETTING_HRE,
            `For network: ${endpointIdToNetwork(srcEid)}, OFT: ${oftAddress}`
        )
        throw error
    }
    const signer = await srcEidHre.ethers.getNamedSigner('deployer')
    // 1️⃣ resolve the OFT wrapper address
    let wrapperAddress: string
    if (oftAddress) {
        wrapperAddress = oftAddress
    } else {
        const { contracts } = typeof layerzeroConfig === 'function' ? await layerzeroConfig() : layerzeroConfig
        const wrapper = contracts.find((c) => c.contract.eid === srcEid)
        if (!wrapper) throw new Error(`No config for EID ${srcEid}`)
        wrapperAddress = wrapper.contract.contractName
            ? (await srcEidHre.deployments.get(wrapper.contract.contractName)).address
            : wrapper.contract.address!
    }
    // 2️⃣ load OFT ABI
    const oft = new Contract(wrapperAddress, OFT_ABI, signer as any)
    // 3️⃣ fetch the underlying ERC-20
    const underlying = await oft.token()
    // 4️⃣ fetch decimals from the underlying token
    const erc20 = new Contract(underlying, ERC20_ABI, signer as any)
    const decimals: number = await erc20.decimals()
    // 5️⃣ normalize the user-supplied amount
    const amountUnits: BigNumber = parseUnits(amount, decimals)

    // 5.5️⃣ ensure allowance for adapter debit (OFTAdapter requires transferFrom on the underlying token)
    // Approve MaxUint256 once, so subsequent sends don't need another approval.
    const currentAllowance: BigNumber = await erc20.allowance(signer.address, wrapperAddress)
    if (currentAllowance.lt(amountUnits)) {
        logger.info(`Approving underlying token for adapter spend...`)
        try {
            const tx = await erc20.approve(wrapperAddress, BigNumber.from(2).pow(256).sub(1))
            await tx.wait()
            logger.info(`Approval confirmed: ${tx.hash}`)
        } catch (e: any) {
            const msg = String(e?.message ?? e)
            // Some RPCs return "already known" if the exact same approval tx is already in mempool.
            // In that case, just wait a bit and re-check allowance.
            if (msg.toLowerCase().includes('already known')) {
                logger.warn(
                    `Approval tx is already known by the RPC (likely pending). Waiting for allowance to update...`
                )
                const deadline = Date.now() + 60_000
                while (Date.now() < deadline) {
                    await sleep(5_000)
                    const a: BigNumber = await erc20.allowance(signer.address, wrapperAddress)
                    if (a.gte(amountUnits)) {
                        logger.info(`Allowance is now sufficient.`)
                        break
                    }
                }
                const finalAllowance: BigNumber = await erc20.allowance(signer.address, wrapperAddress)
                if (finalAllowance.lt(amountUnits)) {
                    throw e
                }
            } else {
                throw e
            }
        }
    }
    // Decide how to encode `to` based on target chain:
    const dstChain = endpointIdToChainType(dstEid)
    let toBytes: string
    if (dstChain === ChainType.SOLANA) {
        // Base58→32-byte buffer
        toBytes = makeBytes32(bs58.decode(to))
    } else {
        // hex string → Uint8Array → zero-pad to 32 bytes
        toBytes = makeBytes32(to)
    }
    // 6️⃣ build sendParam and dispatch
    const sendParam = {
        dstEid,
        to: toBytes,
        amountLD: amountUnits.toString(),
        minAmountLD: minAmount ? parseUnits(minAmount, decimals).toString() : amountUnits.toString(),
        extraOptions: extraOptions ? extraOptions.toString() : '0x',
        composeMsg: composeMsg ? composeMsg.toString() : '0x',
        oftCmd: '0x',
    }

    // Check whether there are extra options or enforced options. If not, warn the user.
    // Read on Message Options: https://docs.layerzero.network/v2/concepts/message-options
    if (!extraOptions) {
        try {
            const enforcedOptions = composeMsg
                ? await oft.enforcedOptions(dstEid, MSG_TYPE.SEND_AND_CALL)
                : await oft.enforcedOptions(dstEid, MSG_TYPE.SEND)

            if (isEmptyOptionsEvm(enforcedOptions)) {
                const autoYes =
                    process.env.CI === '1' ||
                    process.env.CI === 'true' ||
                    process.env.LZ_ASSUME_YES === '1' ||
                    process.env.NON_INTERACTIVE === '1'
                const proceed = autoYes
                    ? true
                    : await promptToContinue(
                          'No extra options were included and OFT has no set enforced options. Your quote / send will most likely fail. Continue?'
                      )
                if (!proceed) {
                    throw new Error('Aborted due to missing options')
                }
            }
        } catch (error) {
            logger.debug(`Failed to check enforced options: ${error}`)
        }
    }

    // 6️⃣ Quote (MessagingFee = { nativeFee, lzTokenFee })
    logger.info('Quoting the native gas cost for the send transaction...')
    let msgFee: { nativeFee: BigNumber; lzTokenFee: BigNumber }
    try {
        msgFee = await oft.quoteSend(sendParam, false)
    } catch (error) {
        DebugLogger.printErrorAndFixSuggestion(
            KnownErrors.ERROR_QUOTING_NATIVE_GAS_COST,
            `For network: ${endpointIdToNetwork(srcEid)}, OFT: ${oftAddress}`
        )
        throw error
    }
    logger.info('Sending the transaction...')
    let tx: ContractTransaction
    try {
        tx = await oft.send(sendParam, msgFee, signer.address, {
            value: msgFee.nativeFee,
        })
    } catch (error) {
        DebugLogger.printErrorAndFixSuggestion(
            KnownErrors.ERROR_SENDING_TRANSACTION,
            `For network: ${endpointIdToNetwork(srcEid)}, OFT: ${oftAddress}`
        )
        throw error
    }
    const receipt = await tx.wait()
    const txHash = receipt.transactionHash
    const scanLink = getLayerZeroScanLink(txHash, srcEid >= 40_000 && srcEid < 50_000)
    return { txHash, scanLink }
}
