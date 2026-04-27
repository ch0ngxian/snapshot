import { randomInt } from "crypto";

// Per tech-plan §173: 6-char base36 (uppercase A-Z, digits 0-9). Uses
// `crypto.randomInt` for unbiased uniform sampling over the 36-char alphabet
// (avoids the modulo bias `Math.random() * 36 | 0` would inherit if the RNG
// is later swapped for one with a non-power-of-two range).
const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const CODE_LENGTH = 6;

export function generateLobbyCode(): string {
  let out = "";
  for (let i = 0; i < CODE_LENGTH; i++) {
    out += ALPHABET[randomInt(ALPHABET.length)];
  }
  return out;
}
