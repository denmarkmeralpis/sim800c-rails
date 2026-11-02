// Mirrors the server's encoding/segmentation rules (src/modem/pdu) for the live character counter.

const BASIC = new Set(
  '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà',
);
const EXTENSION = new Set('\f^{}\\[~]|€');

export function smsInfo(text) {
  const chars = [...text];
  const gsm = chars.every((c) => BASIC.has(c) || EXTENSION.has(c));
  const lengths = chars.map((c) => (gsm ? (EXTENSION.has(c) ? 2 : 1) : c.length));
  const [single, multi] = gsm ? [160, 153] : [70, 67];
  const total = lengths.reduce((a, b) => a + b, 0);

  let parts = total === 0 ? 0 : 1;
  let current = 0;
  if (total > single) {
    for (const len of lengths) {
      if (current + len > multi) {
        parts++;
        current = 0;
      }
      current += len;
    }
  } else {
    current = total;
  }
  const limit = parts > 1 ? multi : single;
  return {
    encoding: gsm ? 'GSM-7' : 'Unicode (UCS-2)',
    length: total,
    parts,
    remaining: limit - current,
    nonGsm: gsm ? [] : [...new Set(chars.filter((c) => !BASIC.has(c) && !EXTENSION.has(c)))].slice(0, 5),
  };
}
