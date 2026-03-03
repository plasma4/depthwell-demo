const alphabet = "abcdefghijklmnopqrstuvwxyz";
const base = 26n;

/** Creates a seed; won't work properly past length 100. */
export function makeSeed(seedLength = 100) {
    // 68 bytes > 2*10^173. Max seeds possible around ~3.14*10^141, so this is a sufficient amount of bytes.
    const bytes = new Uint8Array(72);
    crypto.getRandomValues(bytes);

    let randomBigInt = 0n;
    const view = new DataView(bytes.buffer);
    for (let i = 0; i < bytes.length; i += 8) {
        randomBigInt = (randomBigInt << 64n) | view.getBigUint64(i);
    }

    // Bijective base conversion
    let result = "";
    let temp = randomBigInt % base ** BigInt(seedLength);

    while (temp >= 0n) {
        result += alphabet[Number(temp % base)];
        temp = temp / base - 1n;
        if (temp < 0n) break;
    }
    return result;
}

/** Bijective string-to-BigInt (Same as before) */
function seedToBigInt(seed: string): bigint {
    let total = 0n;
    for (let i = 0; i < seed.length; i++) {
        const charValue = BigInt(seed.charCodeAt(i) - 97);
        total = total * base + (charValue + 1n);
    }
    return total;
}

/**
 * Bijective 512-bit Mixer using HMAC-SHA256 in a Feistel Network.
 */
export async function seedToMemory(
    seed: string,
    outArray: BigUint64Array,
): Promise<BigUint64Array> {
    const total = seedToBigInt(seed);

    const buffer = new Uint8Array(64);
    for (let i = 0; i < 64; i++) {
        buffer[63 - i] = Number((total >> BigInt(i * 8)) & 0xffn);
    }

    // Split into lower and upper halves
    let L = buffer.slice(0, 32);
    let R = buffer.slice(32, 64);

    // Now run 4 rounds of Feistel
    // 4 rounds with a cryptographic hash is sufficient for complete diffusion.
    for (let i = 0; i < 4; i++) {
        const roundKey = await crypto.subtle.importKey(
            "raw",
            new Uint8Array([i]), // Using round index as the key
            { name: "HMAC", hash: "SHA-256" },
            false,
            ["sign"],
        );

        // Calculate F(R)
        const hmacSignature = await crypto.subtle.sign("HMAC", roundKey, R);
        const F_R = new Uint8Array(hmacSignature);

        // L_next = R
        // R_next = L ^ F(R)
        const nextR = new Uint8Array(32);
        for (let j = 0; j < 32; j++) {
            nextR[j] = L[j] ^ F_R[j];
        }

        L = R;
        R = nextR;
    }

    // Combine and return
    outArray.set(new BigUint64Array(L.buffer));
    outArray.set(new BigUint64Array(R.buffer), 4);
    return outArray;
}
