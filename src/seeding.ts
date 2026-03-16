const alphabet = "abcdefghijklmnopqrstuvwxyz";
const base = 26n;

/** Creates a seed up from 1 to seedLength characters; won't work properly past length 100. */
export function makeSeed(seedLength = 100) {
    // 68 bytes > 2*10^173. The amount of possible seed combinations is around ~3.29*10^141, so this is a sufficient amount of bytes.
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
 * Bijective 512-bit mixer using HMAC-SHA256 in a Feistel Network. This isn't your typical string-to-binary algorithm as it preserves true bijectivity while being cryptographically secure...why not.
 */
export async function seedToMemory(
    seed: string,
    outArray: BigUint64Array,
): Promise<BigUint64Array> {
    const total = seedToBigInt(seed);
    const view = new DataView(new ArrayBuffer(64));

    // Efficiently pack the BigInt
    for (let i = 0; i < 8; i++) {
        view.setBigUint64(
            i * 8,
            (total >> BigInt((7 - i) * 64)) & 0xffffffffffffffffn,
        );
    }

    let L = new Uint8Array(view.buffer, 0, 32);
    let R = new Uint8Array(view.buffer, 32, 32);

    // pre-import keys
    const keys = await Promise.all(
        [0, 1, 2, 3].map((i) =>
            crypto.subtle.importKey(
                "raw",
                new Uint8Array([i]),
                { name: "HMAC", hash: "SHA-256" },
                false,
                ["sign"],
            ),
        ),
    );

    for (const roundKey of keys) {
        const fR = new Uint8Array(
            await crypto.subtle.sign("HMAC", roundKey, R),
        );

        const nextR = new Uint8Array(32);
        for (let j = 0; j < 32; j++) {
            nextR[j] = L[j] ^ fR[j];
        }

        L = R;
        R = nextR;
    }

    // Direct copy-to-output
    const finalBuffer = new Uint8Array(64);
    finalBuffer.set(L, 0);
    finalBuffer.set(R, 32);
    outArray.set(new BigUint64Array(finalBuffer.buffer));

    return outArray;
}
