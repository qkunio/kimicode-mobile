"""合成推广片的全部音效 + 背景音乐，按 cues.json 的时间点混成一条立体声 WAV。

所有声音都是现场算出来的（振荡器 + 噪声 + 滤波 + 包络），不依赖任何采样素材。
用法：python3 sfx.py cues.json out.wav
"""
import json
import sys
import wave

import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt

SR = 48000
rng = np.random.default_rng(7)


# ---------- 基础积木 ----------
def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def env(dur, a=0.002, d=None, curve=6.0):
    """起音 a 秒后指数衰减到结尾。"""
    t = t_axis(dur)
    e = np.exp(-curve * t / dur) if d is None else np.exp(-t / d)
    if a > 0:
        e = e * np.clip(t / a, 0, 1)
    return e


def sweep(f0, f1, dur, shape="exp"):
    t = t_axis(dur)
    f = f0 * (f1 / f0) ** (t / dur) if shape == "exp" else f0 + (f1 - f0) * t / dur
    return np.sin(2 * np.pi * np.cumsum(f) / SR)


def tone(freq, dur, partials=((1, 1.0),), detune=0.0):
    t = t_axis(dur)
    out = np.zeros_like(t)
    for mul, amp in partials:
        out += amp * np.sin(2 * np.pi * freq * mul * (1 + detune) * t + rng.uniform(0, 6.28))
    return out


def noise(dur):
    return rng.standard_normal(int(dur * SR))


def filt(x, kind, f, order=2):
    sos = butter(order, f, btype=kind, fs=SR, output="sos")
    return sosfilt(sos, x)


def moving_lp(x, f_start, f_end):
    """分块扫频低通，给 whoosh 用。"""
    out = np.zeros_like(x)
    n = len(x)
    blocks = 64
    edges = np.linspace(0, n, blocks + 1).astype(int)
    zi = None
    for i in range(blocks):
        f = f_start * (f_end / f_start) ** (i / (blocks - 1))
        sos = butter(2, min(f, SR / 2 - 100), btype="low", fs=SR, output="sos")
        seg = x[edges[i]:edges[i + 1]]
        if zi is None:
            zi = np.zeros((sos.shape[0], 2))
        y, zi = sosfilt(sos, seg, zi=zi)
        out[edges[i]:edges[i + 1]] = y
    return out


def norm(x, peak=1.0):
    m = np.max(np.abs(x)) or 1
    return x / m * peak


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def bell(freq, dur, bright=1.0):
    parts = ((1, 1.0), (2.0, 0.45 * bright), (3.01, 0.22 * bright), (4.2, 0.12 * bright), (5.4, 0.06 * bright))
    t = t_axis(dur)
    out = np.zeros_like(t)
    for i, (mul, amp) in enumerate(parts):
        out += amp * np.sin(2 * np.pi * freq * mul * t) * np.exp(-t * (3 + i * 2.5))
    return out * np.clip(t / 0.003, 0, 1)


# ---------- 音效 ----------
def s_key():
    d = 0.06
    click = filt(noise(d), "band", (2500, 7000)) * env(d, 0.0005, 0.006)
    body = tone(rng.uniform(180, 230), d) * env(d, 0.001, 0.012)
    return norm(click * 0.8 + body * 0.5, 0.55)


def s_enter():
    d = 0.18
    click = filt(noise(d), "band", (1500, 6000)) * env(d, 0.0005, 0.01)
    thump = sweep(160, 60, d) * env(d, 0.001, 0.05)
    return norm(click * 0.7 + thump, 0.8)


def s_type():
    d = 0.04
    x = filt(noise(d), "band", (3000, 9000)) * env(d, 0.0003, 0.004)
    return norm(x, 0.35)


def s_tick():
    d = 0.08
    return norm(tone(1350, d, ((1, 1), (2, .3))) * env(d, 0.001, 0.015), 0.35)


def s_stream():
    d = 0.03
    return norm(tone(rng.uniform(2200, 2800), d) * env(d, 0.0005, 0.005), 0.12)


def s_blip():
    a = bell(midi(84), 0.5)
    b = bell(midi(91), 0.6)
    out = np.zeros(int(0.8 * SR))
    out[:len(a)] += a
    o = int(0.07 * SR)
    out[o:o + len(b)] += b * 0.8
    return norm(out, 0.45)


def s_whoosh(dur=0.75, f0=300, f1=6000, rise=0.6):
    t = t_axis(dur)
    x = moving_lp(noise(dur), f0, f1)
    x = filt(x, "high", 150)
    shape = np.where(t < dur * rise, (t / (dur * rise)) ** 2, np.exp(-(t - dur * rise) / (dur * 0.12)))
    return norm(x * shape, 0.7)


def s_swoosh():
    return s_whoosh(0.4, 600, 7000, 0.45) * 0.7


def s_swoosh_up():
    return s_whoosh(0.9, 200, 5000, 0.7) * 0.8


def s_impact():
    d = 2.2
    boom = sweep(110, 32, d) * env(d, 0.002, 0.45)
    sub = tone(42, d) * env(d, 0.01, 0.7) * 0.6
    crack = filt(noise(d), "band", (800, 8000)) * env(d, 0.0005, 0.03)
    tail = filt(noise(d), "low", 1200) * env(d, 0.01, 0.5) * 0.25
    return norm(np.tanh(1.6 * (boom + sub + crack * 0.8 + tail)), 0.95)


def s_shimmer():
    d = 1.6
    t = t_axis(d)
    out = np.zeros_like(t)
    notes = [88, 91, 93, 95, 96, 98, 100, 103]  # E6..G7，五声音阶的亮晶晶
    for i, n in enumerate(notes):
        st = i * 0.06 + rng.uniform(0, 0.03)
        seg = bell(midi(n), d - st, 0.4) * 0.6
        o = int(st * SR)
        out[o:o + len(seg)] += seg[: len(out) - o]
    air = filt(filt(noise(d), "high", 6000), "low", 13000) * np.sin(np.pi * t / d) ** 2 * 0.03
    return norm(out + air, 0.4)


def s_tap():
    d = 0.07
    body = sweep(900, 500, d) * env(d, 0.0005, 0.012)
    click = filt(noise(d), "high", 3000) * env(d, 0.0003, 0.003)
    return norm(body + click * 0.6, 0.55)


def s_send():
    d = 0.22
    x = sweep(420, 1500, d) * env(d, 0.004, 0.06)
    air = s_whoosh(0.22, 1500, 9000, 0.3) * 0.3
    return norm(x + air, 0.5)


def s_pop():
    d = 0.12
    return norm(sweep(1000, 320, d) * env(d, 0.001, 0.03), 0.5)


def s_notify():
    out = np.zeros(int(1.4 * SR))
    for i, n in enumerate((88, 95)):  # E6 → B6
        b = bell(midi(n), 1.2)
        o = int(i * 0.13 * SR)
        out[o:o + len(b)] += b
    return norm(out, 0.55)


def s_approve():
    out = np.zeros(int(1.3 * SR))
    for i, n in enumerate((79, 83, 86, 91)):  # G 大三和弦上行
        b = bell(midi(n), 1.0, 0.7)
        o = int(i * 0.065 * SR)
        out[o:o + len(b)] += b * (0.8 + i * 0.07)
    return norm(out, 0.55)


def s_success():
    out = np.zeros(int(1.5 * SR))
    for i, n in enumerate((84, 91)):  # C6 → G6
        b = bell(midi(n), 1.3, 0.6)
        o = int(i * 0.1 * SR)
        out[o:o + len(b)] += b
    return norm(out, 0.5)


def s_riser():
    d = 0.6
    t = t_axis(d)
    x = moving_lp(noise(d), 400, 10000) * (t / d) ** 2
    s = sweep(200, 1600, d) * (t / d) ** 3 * 0.4
    return norm(x + s, 0.6)


SFX = {k[2:]: v for k, v in globals().items() if k.startswith("s_")}


# ---------- 背景音乐 ----------
BPM = 120
BEAT = 60 / BPM


def kick():
    d = 0.4
    return np.tanh(2 * (sweep(150, 45, d) * env(d, 0.001, 0.12) + filt(noise(d), "high", 4000) * env(d, 0.0003, 0.002) * 0.3))


def hat(open_=False):
    d = 0.2 if open_ else 0.05
    return filt(noise(d), "high", 7000) * env(d, 0.0005, 0.06 if open_ else 0.012)


def clap():
    d = 0.25
    n = filt(noise(d), "band", (900, 5000)) * env(d, 0.001, 0.07)
    return n + tone(190, d) * env(d, 0.001, 0.03) * 0.4


def saw(freq, dur, voices=5, spread=0.012):
    t = t_axis(dur)
    out = np.zeros_like(t)
    for v in range(voices):
        det = 1 + spread * (v - (voices - 1) / 2) / voices
        ph = rng.uniform(0, 1)
        out += 2 * ((freq * det * t + ph) % 1) - 1
    return out / voices


# 和弦（MIDI），每小节一个：F – G – Am – Em（C 大调的明亮走向）
CHORDS = [(53, 57, 60, 64), (55, 59, 62, 67), (57, 60, 64, 69), (52, 55, 59, 64)]
ROOTS = [41, 43, 45, 40]


def music(dur, marks):
    n = int(dur * SR)
    L = np.zeros(n)
    R = np.zeros(n)
    drop, outro = marks["drop"], marks["outroHit"]

    def add(buf, x, at, gain=1.0):
        o = int(at * SR)
        if o >= n or o + len(x) <= 0:
            return
        s = max(0, -o)
        e = min(len(x), n - o)
        buf[o + s:o + e] += x[s:e] * gain

    def both(x, at, g=1.0, pan=0.0):
        add(L, x, at, g * (1 - max(0, pan)))
        add(R, x, at, g * (1 + min(0, pan)))

    def level(t):
        """各段强度：logo 段全开，手机演示段收一点给音效让位，功能墙再推上去。"""
        if t < drop:
            return 0.0
        if t < 8.5:
            return 1.0
        if t < 32.4:
            return 0.7
        if t < outro:
            return 0.95
        return 0.0

    # 前奏：低频铺底 + 渐强
    intro = np.zeros(int(drop * SR))
    for f in (45, 52, 57):
        intro += filt(saw(midi(f), drop, 3), "low", 900)
    ti = t_axis(drop)
    intro *= (ti / drop) ** 1.5 * 0.18
    both(intro, 0)
    both(s_whoosh(1.0, 200, 9000, 0.92) * 0.35, drop - 0.95)

    # 主体循环
    bar = BEAT * 4
    nbars = int(np.ceil((outro - drop) / bar))
    for b in range(nbars):
        t0 = drop + b * bar
        ci = b % 4
        lv = level(t0 + 0.01)
        if lv == 0:
            continue
        # pad：超锯齿 + 低通 + 侧链感
        pd = bar + 0.05
        pad = np.zeros(int(pd * SR))
        for m in CHORDS[ci]:
            pad += saw(midi(m + 12), pd, 5, 0.018)
        pad = filt(pad, "low", 2200)
        tp = t_axis(pd)
        duck = 1 - 0.55 * np.exp(-((tp % BEAT) / 0.12))
        pad *= duck * np.clip(tp / 0.08, 0, 1) * np.clip((pd - tp) / 0.05, 0, 1)
        both(pad * 0.075 * lv, t0, pan=-0.15)
        both(pad * 0.075 * lv, t0 + 0.012, pan=0.15)
        for k in range(4):
            tb = t0 + k * BEAT
            if tb >= outro:
                break
            both(kick() * 0.55 * lv, tb)
            both(hat() * 0.12 * lv, tb + BEAT / 2, pan=0.3)
            if k in (1, 3):
                both(clap() * 0.22 * lv, tb, pan=-0.05)
            # bass：八分音符根音
            for h in (0, 1):
                bd = BEAT / 2 - 0.01
                bs = filt(saw(midi(ROOTS[ci]), bd, 2, 0.004), "low", 420) * env(bd, 0.004, 0.25)
                both(bs * 0.32 * lv, tb + h * BEAT / 2)
            # 琶音拨弦：十六分
            for s in range(4):
                idx = (k * 4 + s) % 8
                seq = [0, 2, 1, 3, 2, 1, 3, 2]
                note = CHORDS[ci][seq[idx]] + 24
                pl = bell(midi(note), 0.35, 0.3) * 0.5
                both(pl * 0.14 * lv, tb + s * BEAT / 4, pan=0.35 if s % 2 else -0.35)

    # 功能墙前的空拍：留 0.6s 给 riser
    # 片尾：大和弦延音
    od = dur - outro
    tail = np.zeros(int(od * SR))
    for m in (41, 53, 60, 64, 67, 72, 76):
        tail += saw(midi(m), od, 5, 0.02) * (0.5 if m < 50 else 1)
    tail = filt(tail, "low", 2600)
    to = t_axis(od)
    tail *= np.clip(to / 0.02, 0, 1) * np.exp(-to / 2.6)
    both(tail * 0.11, outro)
    for i, m in enumerate((72, 76, 79, 84, 88)):
        both(bell(midi(m), 2.5, 0.4) * 0.12, outro + 0.8 + i * 0.25, pan=(-0.4 + i * 0.2))

    return L, R


def reverb(x, secs=1.4, wet=0.2):
    ir = rng.standard_normal(int(secs * SR)) * np.exp(-np.arange(int(secs * SR)) / SR / (secs / 5))
    ir = filt(ir, "low", 5000)
    ir /= np.sqrt(np.sum(ir ** 2))
    y = fftconvolve(x, ir)[: len(x)]
    return x + wet * y


def main():
    meta = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    dur = meta["dur"]
    n = int(dur * SR)

    # 音效总线（带轻微声像）
    L = np.zeros(n)
    R = np.zeros(n)
    cache = {}
    for t, name, vol in meta["cues"]:
        # 键盘类每次重新生成，避免机械重复；其余缓存
        x = SFX[name]() if name in ("key", "type", "stream") else cache.setdefault(name, SFX[name]())
        o = int(t * SR)
        e = min(n, o + len(x))
        pan = rng.uniform(-0.15, 0.15) if name in ("key", "type", "stream") else 0.0
        L[o:e] += x[: e - o] * vol * (1 - max(0, pan))
        R[o:e] += x[: e - o] * vol * (1 + min(0, pan))
    L, R = reverb(L, 1.0, 0.18), reverb(R, 1.05, 0.18)

    mL, mR = music(dur, meta["marks"])
    mL, mR = reverb(mL, 1.6, 0.25), reverb(mR, 1.7, 0.25)

    mixL = L + mL * 0.8
    mixR = R + mR * 0.8
    # 结尾淡出
    fade = np.clip((dur - t_axis(dur)) / 0.9, 0, 1)
    mix = np.stack([mixL, mixR], 1) * fade[:, None]
    mix = np.tanh(mix * 1.1)
    mix = mix / np.max(np.abs(mix)) * 0.89  # ≈ -1 dBFS
    pcm = (mix * 32767).astype("<i2")
    with wave.open(out, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {out}: {dur:.1f}s, {len(meta['cues'])} cues")


if __name__ == "__main__":
    main()
