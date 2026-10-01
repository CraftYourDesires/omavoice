#version 440
// omavoice recording overlay, the "scope" and "clip" styles (variant uniform):
// 0 scope: a synth oscilloscope, harmonics brighten as the voice gets louder,
//   with a phosphor ghost of the moment before.
// 1 bars: a mirrored spectrum analyzer, center bars react first, peak caps
//   (not offered as a style yet).
// 2 clip: a DAW clip waveform that grows out from the center (newest sound
//   in the middle), so nothing waits for paper to scroll.
// Panel, ASCII glow, scanlines and grain are the trace style's.
// Was "trace" style: A lie detector pen on scrolling
// paper, in a chamfered cyberpunk panel: a calm baseline in silence that
// swings into jagged peaks as the voice gets louder. The glow around the
// trace is rendered as grainy ASCII glyphs (a 3x5 bitmap ramp " .:-=+*#%@"),
// over a graticule that scrolls with the paper. Every color is a uniform
// from the current Omarchy theme (OverlayModel.paletteFrom), the same roles
// the neon style uses. Compile with shaders/build.sh (qsb).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // item size in logical pixels
    float time;       // seconds, free running
    float level;      // smoothed speech level 0..1
    float activity;   // speech gate 0..1
    float onset;      // onset energy 0..1
    float processing; // 0..1 while Voxtype transcribes
    float bgLum;      // OKLab lightness of the theme background
    float grain;      // film grain strength
    float margin;     // transparent space around the panel
    float shift;      // 0..1 progress toward the next paper step
    float seq;        // committed samples so far (scrolls the graticule)
    float variant;    // 0 scope, 1 bars, 2 clip
    vec4 h0; vec4 h1; vec4 h2; vec4 h3; vec4 h4; vec4 h5; vec4 h6; vec4 h7;
    vec4 h8; vec4 h9; vec4 h10; vec4 h11; vec4 h12; vec4 h13; vec4 h14; vec4 h15;
    vec4 colBg;
    vec4 colEdge;
    vec4 colCore;
    vec4 colMid;
    vec4 colRim;
    vec4 colSpark;
    vec4 colLine;
    vec4 colHalo;
};

const int N = 64;
vec4 H[16];

int iclamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Level history, newest (live) first.
float hv(int i) {
    i = iclamp(i, 0, N - 1);
    int q = i / 4;
    vec4 v = H[q];
    int c = i - q * 4;
    return c == 0 ? v.x : (c == 1 ? v.y : (c == 2 ? v.z : v.w));
}
// Smoothly scrolling history at fractional age f (in paper steps).
float Lf(float f) {
    f = max(f, 0.0);
    if (f >= 1.0) f += shift;
    float i0 = floor(f);
    return mix(hv(int(i0)), hv(int(i0) + 1), f - i0);
}

float hash21(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}
float hash11(float n) { return fract(sin(n * 91.3458 + 47.853) * 43758.5453); }

float sdChamfer(vec2 p, vec2 b, float c) {
    vec2 q = abs(p) - b;
    float box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float cut = (abs(p.x) + abs(p.y) - (b.x + b.y - c)) * 0.70710678;
    return max(box, cut);
}

int glyph(int i) {
    if (i <= 0) return 0;
    if (i == 1) return 0x0002;
    if (i == 2) return 0x0410;
    if (i == 3) return 0x01C0;
    if (i == 4) return 0x0E38;
    if (i == 5) return 0x05D0;
    if (i == 6) return 0x0AAA;
    if (i == 7) return 0x5F7D;
    if (i == 8) return 0x4A95;
    return 0x7B67;
}

float xL, xR, yMid, amp;

// ---- scope
float scopeY(float x, float lv, float t) {
    float u = clamp((x - xL) / (xR - xL), 0.0, 1.0);
    float win = pow(sin(3.14159265 * u), 1.3);
    float w = sin(6.2831853 * 2.5 * u - t * 7.0)
            + (0.25 + 0.9 * onset) * 0.55 * sin(6.2831853 * 6.0 * u + t * 11.0)
            + lv * 0.4 * sin(6.2831853 * 11.0 * u - t * 17.0);
    return yMid - lv * amp * 0.95 * win * w / 2.0;
}
float curveDist(vec2 p, float lv, float t) {
    float y = scopeY(p.x, lv, t);
    float dy = (scopeY(p.x + 1.0, lv, t) - scopeY(p.x - 1.0, lv, t)) * 0.5;
    return abs(p.y - y) / sqrt(1.0 + dy * dy);
}

// ---- bars
const float NB = 30.0;
float barH(float b, float t) {
    float cd = abs((b + 0.5) / NB - 0.5) * 2.0;
    float formant = 0.6 + 0.4 * sin(b * 1.7 + t * 2.3 + hash11(b) * 6.0);
    float tilt = 1.0 - 0.45 * pow(cd, 1.4);
    float lag = cd * 5.0 + hash11(b + 7.0) * 1.5;
    return pow(Lf(lag), 0.8) * formant * tilt * 1.15;
}
float barCap(float b, float t) {
    float cd = abs((b + 0.5) / NB - 0.5) * 2.0;
    float formant = 0.55 + 0.45 * sin(b * 1.7 + t * 2.3 + hash11(b) * 6.0);
    float tilt = 1.0 - 0.55 * pow(cd, 1.4);
    float m = 0.0;
    for (int k = 0; k < 14; k++) {
        float age = float(k) * 1.5;
        m = max(m, Lf(cd * 5.0 + age) * (1.0 - age / 24.0));
    }
    return pow(m, 0.8) * formant * tilt * 1.15;
}

// ---- clip
float clipE(float x) {
    // 3px sample columns, like a zoomed-in audio clip in a DAW. Each column
    // keeps its own random reach as it travels outward with the sound.
    float cx = floor((x - 0.5 * (xL + xR)) / 3.0);
    float u = (cx * 3.0) / (xR - xL);
    float d = abs(u) * 2.0;
    float f = d * 40.0;
    float age = floor(f + seq + shift);
    float tex = 0.3 + 0.7 * hash11(age * 3.0 + sign(cx) * 0.5 + 17.0);
    return Lf(f) * tex * 0.95 * (1.0 - smoothstep(0.8, 1.0, d));
}

// Distance to the bright edge of the shape and whether q is inside its body.
float shapeAt(vec2 q, out float fill) {
    fill = 0.0;
    int v = int(variant + 0.5);
    if (v == 0) {
        float lv = max(level, Lf(0.0));
        float d = curveDist(q, lv, time);
        float ghost = curveDist(q, Lf(4.0), time - 0.09) + 2.2;
        float y = scopeY(q.x, lv, time);
        fill = (q.y - yMid) * (y - yMid) > 0.0 && abs(q.y - yMid) < abs(y - yMid) ? 0.6 : 0.0;
        return min(d, ghost);
    }
    if (v == 1) {
        float u = (q.x - xL) / (xR - xL);
        if (u < 0.0 || u > 1.0) return 1e3;
        float b = floor(u * NB);
        float bx = fract(u * NB);
        float gap = step(0.18, bx) * step(bx, 0.82);
        float h = max(barH(b, time) * amp * 0.95, 0.8);
        float cap = barCap(b, time) * amp * 0.95 + 2.5;
        float ay = abs(q.y - yMid);
        fill = gap * step(ay, h) * (0.35 + 0.65 * ay / max(h, 1.0));
        float top = abs(ay - h);
        float capD = abs(ay - cap) + 1.2;
        return gap > 0.5 ? min(top, capD) : 1e3;
    }
    float e = max(clipE(q.x) * amp * 0.95, 0.6);
    float ay = abs(q.y - yMid);
    fill = step(ay, e) * (0.4 + 0.6 * ay / max(e, 1.0));
    return abs(ay - e);
}

void main() {
    H[0] = h0; H[1] = h1; H[2] = h2; H[3] = h3; H[4] = h4; H[5] = h5; H[6] = h6; H[7] = h7;
    H[8] = h8; H[9] = h9; H[10] = h10; H[11] = h11; H[12] = h12; H[13] = h13; H[14] = h14; H[15] = h15;

    vec2 p = qt_TexCoord0 * size;
    vec2 c = size * 0.5;
    float dark = 1.0 - smoothstep(0.5, 0.72, bgLum);

    vec2 hs = size * 0.5 - vec2(margin);
    float chamfer = 11.0;
    float sd = sdChamfer(p - c, hs, chamfer);
    float aa = max(fwidth(sd), 1e-4);
    float inside = clamp(0.5 - sd / aa, 0.0, 1.0);

    xL = c.x - hs.x + 8.0;
    xR = c.x + hs.x - 8.0;
    yMid = c.y;
    amp = hs.y - 7.0;
    int v = int(variant + 0.5);

    float outer = max(sd, 0.0);
    float haloA = exp(-outer * outer / 60.0) * (0.16 + 0.34 * level + 0.25 * onset) * (1.0 - inside);
    float shadowA = exp(-pow(max(sdChamfer(p - c - vec2(0.0, 2.5), hs, chamfer), 0.0), 2.0) / 40.0) * 0.28 * (1.0 - inside);

    vec3 col = colBg.rgb;
    // Both ends fade, like the trace style's old paper on the left.
    float plotMask = smoothstep(xL - 4.0, xL + 12.0, p.x) * (1.0 - smoothstep(xR - 12.0, xR + 4.0, p.x));
    float drift = v == 2 ? 0.0 : time * 6.0;
    float minorX = abs(fract((p.x - c.x + drift) / 16.0 + 0.5) - 0.5) * 16.0;
    float rowY = abs(fract((p.y - yMid) / (amp * 0.5) + 0.5) - 0.5) * amp * 0.5;
    float grid = (1.0 - smoothstep(0.0, 0.9, minorX)) * 0.05 + (1.0 - smoothstep(0.0, 0.9, rowY)) * 0.05;
    col = mix(col, colLine.rgb, grid * plotMask);

    float fill;
    float d = shapeAt(p, fill);
    float sigma = 2.2 + 5.0 * level + 3.0 * onset;
    float glow = exp(-d * d / (sigma * sigma)) * plotMask;

    vec2 cell = vec2(4.0, 6.0);
    vec2 org = vec2(xL - 8.0, yMid - amp - 3.0);
    vec2 ci = floor((p - org) / cell);
    vec2 cc = org + (ci + 0.5) * cell;
    float cfill;
    float dc = shapeAt(cc, cfill);
    float spread = 5.0 + 11.0 * level + 5.0 * onset;
    float cmask = smoothstep(xL - 4.0, xL + 12.0, cc.x) * (1.0 - smoothstep(xR - 12.0, xR + 4.0, cc.x));
    float sweep = processing * exp(-pow((cc.x - mix(xL, xR, fract(time * 0.8))) / 12.0, 2.0));
    float flick = hash21(ci + floor(time * 14.0)) - 0.5;
    float lum = exp(-dc * dc / (spread * spread)) * 0.8 + cfill * 0.45 + 0.06 + sweep * 0.55 + flick * (0.1 + 0.12 * level);
    lum = clamp(lum, 0.0, 0.999) * cmask;
    int gi = int(lum * 10.0);
    vec2 lp = floor(p - (cc - cell * 0.5));
    float on = 0.0;
    if (lp.x < 3.0 && lp.y >= 0.0 && lp.y < 5.0) {
        float bit = (4.0 - lp.y) * 3.0 + (2.0 - lp.x);
        on = mod(floor(float(glyph(gi)) / exp2(bit)), 2.0);
    }
    vec3 asciiCol = mix(colMid.rgb, colRim.rgb, clamp(lum * 1.2, 0.0, 1.0));
    col = mix(col, asciiCol, on * (0.2 + 0.42 * lum) * mix(0.7, 1.0, dark));

    vec3 glowCol = colRim.rgb;
    if (dark > 0.5) col += glowCol * glow * 0.55 * dark;
    else col = mix(col, glowCol, glow * 0.4);
    float split = 0.35 + 0.9 * level;
    float f2;
    float dR = shapeAt(p + vec2(split, 0.0), f2);
    float dB = shapeAt(p - vec2(split, 0.0), f2);
    float w = 0.7 + 0.35 * level;
    vec3 core = vec3(1.0 - smoothstep(w - 0.5, w + 0.6, dR), 1.0 - smoothstep(w - 0.5, w + 0.6, d), 1.0 - smoothstep(w - 0.5, w + 0.6, dB));
    vec3 ink = mix(colRim.rgb, colSpark.rgb, 0.8);
    col = mix(col, ink, core * plotMask);

    // Hot center: where the newest sound enters (bars and clip) or the
    // scope's brightest point.
    float hx = v == 0 ? c.x : c.x;
    float hd = length(vec2((p.x - hx) * 0.25, p.y - yMid));
    if (dark > 0.5) col += colCore.rgb * exp(-hd * hd / (20.0 + 80.0 * level)) * (0.1 + 0.4 * activity) * dark * inside * (v == 0 ? 0.5 : 1.0);

    float edge = 1.0 - smoothstep(0.0, 1.1, abs(sd + 0.6));
    vec2 q = abs(p - c);
    float bracket = step(hs.x - 26.0, q.x) * step(hs.y - 16.0, q.y);
    vec3 rimCol = mix(colEdge.rgb, colRim.rgb, 0.35 + 0.65 * bracket);
    col = mix(col, rimCol, edge * (0.55 + 0.45 * bracket));

    float scan = 1.0 - 0.06 * step(0.5, fract(gl_FragCoord.y * 0.5));
    col *= mix(1.0, scan, dark);
    float n = hash21(p * 1.7 + fract(time * 23.0) * 91.0) - 0.5;
    col += n * grain * 1.4;
    float dither = (hash21(gl_FragCoord.xy + 0.37) + hash21(gl_FragCoord.xy + 5.1) - 1.0) / 255.0;
    col += dither;

    float sa = shadowA * (1.0 - 0.6 * dark);
    float ha = haloA * (dark > 0.5 ? 1.0 : 0.6);
    vec3 outer3 = colHalo.rgb * ha;
    float outerA = ha + sa * (1.0 - ha);
    float pa = colBg.a * inside;
    vec3 prem = clamp(col, 0.0, 1.0) * pa + outer3 * (1.0 - pa);
    float alpha = pa + outerA * (1.0 - pa);
    fragColor = vec4(prem, alpha) * qt_Opacity;
}
