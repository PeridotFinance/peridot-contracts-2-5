import base58

solana_address_b58 = "EhDUmmxeFwNYtKPw5swPqshVLRoJmzvbkxcnSLGcybBW"
address_bytes = base58.b58decode(solana_address_b58)

if len(address_bytes) == 32:
    address_hex_bytes32 = "0x" + address_bytes.hex()
    print(f"Update your Solidity script. Replace YOUR_SOLANA_RECIPIENT_ADDRESS_AS_BYTES32 with: {address_hex_bytes32}")
else:
    # Wormhole expects the 32-byte public key for a Solana address.
    # If your base58 decoded address is not 32 bytes, there might be an issue
    # with the address itself or the way it's being converted.
    # A standard Solana public key, when base58 decoded, should yield 32 bytes.
    print(f"Error: Decoded address is {len(address_bytes)} bytes long, but Wormhole expects a 32-byte address for Solana.")
    print("Please double-check the Solana address or ensure it's a valid 32-byte public key when decoded.")
