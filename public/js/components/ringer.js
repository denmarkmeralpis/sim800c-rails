// Two-tone ring using Web Audio while an incoming call is ringing. Browsers may block audio
// until the user has interacted with the page; failures are silent.

let ctx = null;
let timer = null;

function burst() {
  try {
    ctx ??= new AudioContext();
    if (ctx.state === 'suspended') void ctx.resume();
    const now = ctx.currentTime;
    for (const [freq, start] of [
      [880, 0],
      [660, 0.25],
      [880, 0.5],
      [660, 0.75],
    ]) {
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, now + start);
      gain.gain.exponentialRampToValueAtTime(0.08, now + start + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + start + 0.22);
      osc.connect(gain).connect(ctx.destination);
      osc.start(now + start);
      osc.stop(now + start + 0.24);
    }
  } catch {
    /* audio unavailable */
  }
}

export function startRinging() {
  if (timer) return;
  burst();
  timer = setInterval(burst, 3000);
}

export function stopRinging() {
  clearInterval(timer);
  timer = null;
}
