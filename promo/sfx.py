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


def s_whoosh(dur=0.75, f0=300, f1=4500, rise=0.6):
    t = t_axis(dur)
    x = moving_lp(noise(dur), f0, f1)
    x = filt(x, "high", 150)
    shape = np.where(t < dur * rise, (t / (dur * rise)) ** 2, np.exp(-(t - dur * rise) / (dur * 0.12)))
    return norm(x * shape, 0.7)


def s_swoosh():
    return s_whoosh(0.4, 500, 5000, 0.45) * 0.45


def s_swoosh_up():
    return s_whoosh(0.9, 200, 4000, 0.7) * 0.5


def s_impact():
    d = 2.2
    boom = sweep(110, 32, d) * env(d, 0.002, 0.45)
    sub = tone(42, d) * env(d, 0.01, 0.7) * 0.6
    crack = filt(noise(d), "band", (800, 8000)) * env(d, 0.0005, 0.03)
    tail = filt(noise(d), "low", 1200) * env(d, 0.01, 0.5) * 0.25
    return norm(boom * 0.7 + sub + crack * 0.15 + tail * 0.6, 0.6)


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


# ---------- 背景音乐：钢琴独奏 ----------
def piano(m, dur, vel):
    """加法合成的钢琴音：带琴弦刚度的非谐泛音、高次泛音衰减更快、两段式衰减、
    同音三根弦微失谐（产生钢琴特有的"呼吸"）、琴槌击弦噪声。dur 是踩着踏板保持的时长。"""
    f = midi(m)
    ring = float(np.clip(5.5 * (261.6 / f) ** 0.55, 1.2, 9.0))  # 低音持续更久
    length = min(dur, ring * 1.2) + 0.35
    t = t_axis(length)
    B = 0.00035 * (f / 261.6) ** 0.5
    out = np.zeros_like(t)
    strings = (-0.9, 0.0, 0.8) if m > 45 else (-0.5, 0.5)
    for k in range(1, 18):
        fk = f * k * np.sqrt(1 + B * k * k)
        if fk > 14000:
            break
        amp = (1 / k ** 1.15) * np.exp(-(k - 1) * (0.55 - 0.4 * vel))  # 越用力越亮
        if k == 1:
            amp *= 0.8
        tk = ring / (1 + 0.45 * (k - 1))
        decay = 0.65 * np.exp(-t / (tk * 0.22)) + 0.35 * np.exp(-t / tk)
        part = np.zeros_like(t)
        for c in strings:
            part += np.sin(2 * np.pi * fk * (1 + c / 1200 * 0.9) * t + rng.uniform(0, 6.28))
        out += amp * decay * part / len(strings)
    hammer = filt(noise(0.03), "band", (min(f * 2, 6000), min(f * 8, 16000))) * env(0.03, 0.0005, 0.004)
    out[: len(hammer)] += hammer * 0.05 * vel
    out *= np.clip(t / 0.0015, 0, 1)
    rel = np.clip((dur + 0.3 - t) / 0.3, 0, 1)  # 抬踏板：0.3s 内制音
    return out * rel * vel ** 1.3


_pcache = {}


def piano_c(m, dur, vel):
    key = (m, round(dur, 2), round(vel, 2))
    if key not in _pcache:
        _pcache[key] = piano(m, dur, vel)
    return _pcache[key]


BPM = 87  # 让第 12 小节的强拍恰好落在片尾那一下（4.35 + 12 × 4 拍 ≈ 37.45s）
BEAT = 60 / BPM
MAJ, MIN = (0, 7, 12, 16, 19), (0, 7, 12, 15, 19)
# 12 小节：F G Em Am | F G C C | F Em Dm G  → 片尾落到 C
BARS = [(41, MAJ), (43, MAJ), (40, MIN), (45, MIN), (41, MAJ), (43, MAJ), (36, MAJ), (36, MAJ),
        (41, MAJ), (40, MIN), (38, MIN), (43, MAJ)]
# 右手旋律：(拍内起点, MIDI, 拍数)
MELODY = [
    [(0, 81, 2), (2, 79, 1), (3, 77, 1)],
    [(0, 79, 1.5), (1.5, 74, .5), (2, 76, 2)],
    [(0, 79, 2), (2, 83, 1), (3, 81, 1)],
    [(0, 76, 3), (3, 72, 1)],
    [(0, 81, 1), (1, 84, 1), (2, 83, 1), (3, 81, 1)],
    [(0, 79, 2), (2, 74, 1), (3, 79, 1)],
    [(0, 76, 1.5), (1.5, 79, .5), (2, 84, 2)],
    [(0, 84, 3), (3, 83, .5), (3.5, 81, .5)],
    [(0, 84, 2), (2, 81, 1), (3, 79, 1)],
    [(0, 79, 2), (2, 83, 2)],
    [(0, 81, 1), (1, 77, 1), (2, 74, 1), (3, 77, 1)],
    [(0, 79, 2), (2, 83, 1), (3, 86, 1)],
]


def music(dur, marks):
    n = int(dur * SR)
    L = np.zeros(n)
    R = np.zeros(n)
    drop, outro = marks["drop"], marks["outroHit"]

    def note(at, m, length, vel):
        at += rng.normal(0, 0.006)  # 人手的微小不齐
        vel = float(np.clip(vel * rng.uniform(0.93, 1.05), 0.05, 1))
        x = piano_c(m, length, round(vel, 2))
        o = max(0, int(at * SR))
        e = min(n, o + len(x))
        pan = np.clip((m - 64) / 48, -0.45, 0.45)  # 低音偏左、高音偏右，像坐在琴凳上听
        L[o:e] += x[: e - o] * (1 - max(0, pan))
        R[o:e] += x[: e - o] * (1 + min(0, pan))

    def dyn(t):
        """力度：logo 段舒展，演示段收着给音效让位，功能墙再推上去。"""
        if t < 8.5:
            return 0.8
        if t < 32.4:
            return 0.55
        return 0.75

    # 前奏：几颗散落的高音，像在试音
    for at, m, ln, v in [(0.15, 45, 4.2, .45), (0.2, 64, 3.5, .35), (0.9, 76, 2.5, .38), (1.75, 79, 2.2, .34),
                         (2.55, 74, 2.0, .33), (3.3, 72, 1.8, .32), (3.8, 71, 0.8, .3)]:
        note(at, m, ln, v)

    bar = BEAT * 4
    for b, (root, iv) in enumerate(BARS):
        t0 = drop + b * bar
        d = dyn(t0 + 0.01)
        # 左手：分解和弦八分音符，踩着踏板到小节末
        pattern = (0, 1, 2, 3, 4, 3, 2, 1)
        for k, idx in enumerate(pattern):
            at = t0 + k * BEAT / 2
            if at >= outro - 0.05:
                break
            v = (0.62 if k == 0 else 0.42 if k % 2 == 0 else 0.36) * d
            note(at, root + iv[idx], t0 + bar - at + 0.15, v)
        # 右手旋律；功能墙段加上低八度重叠，更饱满
        for beat, m, ln in MELODY[b]:
            at = t0 + beat * BEAT
            if at >= outro - 0.05:
                continue
            note(at, m, ln * BEAT + 0.25, 0.72 * d)
            if b >= 10:
                note(at + 0.01, m - 12, ln * BEAT + 0.25, 0.45 * d)
        # logo 那一下：第一小节加一个厚和弦
        if b == 0:
            for m in (53, 57, 60, 64, 69):
                note(t0 + 0.02, m, bar, 0.5)

    # 片尾：C 大九和弦从低到高琶音展开，长踏板，最后几颗高音
    for i, m in enumerate((36, 43, 48, 52, 55, 59, 62, 64, 67, 72, 76, 79)):
        note(outro + i * 0.045, m, dur - outro, 0.78 if i < 3 else 0.6)
    for i, m in enumerate((84, 88, 91, 96)):
        note(outro + 1.4 + i * 0.32, m, 2.5, 0.35)

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
    mL, mR = reverb(mL, 2.6, 0.32), reverb(mR, 2.7, 0.32)

    mixL = L + mL * 0.8
    mixR = R + mR * 0.8
    # 结尾淡出
    fade = np.clip((dur - t_axis(dur)) / 0.9, 0, 1)
    mix = np.stack([mixL, mixR], 1) * fade[:, None]
    mix = np.tanh(mix * 0.9)
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
