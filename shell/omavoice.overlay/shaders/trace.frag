#version 440
// omavoice recording overlay, "trace" style. A lie detector pen on scrolling
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

// No bitwise operators or integer clamp/min/max anywhere: Qt picks the
// GLSL 120 bake on compatibility-profile OpenGL, which has neither.
int iclamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

float hv(int i) {
    i = iclamp(i, 0, N - 1);
    int q = i / 4;
    vec4 v = H[q];
    int c = i - q * 4;
    return c == 0 ? v.x : (c == 1 ? v.y : (c == 2 ? v.z : v.w));
}

float hash21(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Plot geometry, set in main().
float xPen, dxS, yMid, amp, xLeft;

vec2 pt(int k) {
    // k = 0 is the live pen; committed samples slide left by `shift`.
    float x = k == 0 ? xPen : xPen - (float(k - 1) + shift) * dxS;
    return vec2(x, yMid - hv(k) * amp);
}

float segDist(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

// Distance from p to the trace polyline (the few segments near p.x).
float traceDist(vec2 p) {
    float s = (xPen - p.x) / dxS - shift + 1.0;
    int k = int(floor(max(s, 0.0)));
    if (p.x > xPen - shift * dxS) k = 0;
    float d = 1e4;
    for (int j = -1; j <= 1; j++) {
        int a = iclamp(k + j, 0, N - 2);
        d = min(d, segDist(p, pt(a), pt(a + 1)));
    }
    return d;
}

// Signed deflection of the trace at x, for the phosphor fill under it.
float traceY(float x) {
    float s = (xPen - x) / dxS - shift + 1.0;
    if (x >= xPen - shift * dxS) {
        vec2 a = pt(0), b = pt(1);
        return mix(a.y, b.y, clamp((a.x - x) / max(a.x - b.x, 1e-3), 0.0, 1.0));
    }
    int k = int(floor(max(s, 1.0)));
    vec2 a = pt(k), b = pt(k + 1);
    return mix(a.y, b.y, clamp((a.x - x) / max(a.x - b.x, 1e-3), 0.0, 1.0));
}

// Chamfered rectangle: a box with its four corners cut at 45 degrees.
float sdChamfer(vec2 p, vec2 b, float c) {
    vec2 q = abs(p) - b;
    float box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float cut = (abs(p.x) + abs(p.y) - (b.x + b.y - c)) * 0.70710678;
    return max(box, cut);
}

// 3x5 glyphs, rows top to bottom, 3 bits each (MSB = left).
int glyph(int i) {
    if (i <= 0) return 0;          // ' '
    if (i == 1) return 0x0002;     // '.'
    if (i == 2) return 0x0410;     // ':'
    if (i == 3) return 0x01C0;     // '-'
    if (i == 4) return 0x0E38;     // '='
    if (i == 5) return 0x05D0;     // '+'
    if (i == 6) return 0x0AAA;     // '*'
    if (i == 7) return 0x5F7D;     // '#'
    if (i == 8) return 0x4A95;     // '%'
    return 0x7B67;                 // '@'
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

    xLeft = c.x - hs.x + 8.0;
    xPen = c.x + hs.x - 22.0;
    dxS = (xPen - xLeft) / float(N - 3);
    yMid = c.y;
    amp = hs.y - 7.0;

    // ------------------------------------------------ outside: halo + shadow
    float outer = max(sd, 0.0);
    float haloA = exp(-outer * outer / 60.0) * (0.16 + 0.34 * level + 0.25 * onset) * (1.0 - inside);
    float shadowA = exp(-pow(max(sdChamfer(p - c - vec2(0.0, 2.5), hs, chamfer), 0.0), 2.0) / 40.0) * 0.28 * (1.0 - inside);

    // ------------------------------------------------ panel
    vec3 col = colBg.rgb;
    float gx = p.x - xLeft;
    float lum = 0.0;

    // Graticule, scrolling with the paper: minor every 4 steps, major every 16.
    float paper = gx + (seq + shift) * dxS;
    float minorX = abs(fract(paper / (dxS * 4.0) + 0.5) - 0.5) * dxS * 4.0;
    float majorX = abs(fract(paper / (dxS * 16.0) + 0.5) - 0.5) * dxS * 16.0;
    float rowY = abs(fract((p.y - yMid) / (amp * 0.5) + 0.5) - 0.5) * amp * 0.5;
    float grid = (1.0 - smoothstep(0.0, 0.9, minorX)) * 0.05 + (1.0 - smoothstep(0.0, 0.9, majorX)) * 0.07
               + (1.0 - smoothstep(0.0, 0.9, rowY)) * 0.05;
    // Baseline: dashed, a little brighter.
    float base = (1.0 - smoothstep(0.0, 0.8, abs(p.y - yMid))) * step(0.5, fract(paper / 6.0)) * 0.12;
    float plotMask = smoothstep(xLeft - 4.0, xLeft + 10.0, p.x) * (1.0 - smoothstep(xPen + 4.0, xPen + 6.0, p.x));
    // The pen side fades in the way the old paper fades out on the left,
    // instead of the trace starting abruptly at the right edge.
    float penFade = 1.0 - smoothstep(xPen - 40.0, xPen + 4.0, p.x);
    col = mix(col, colLine.rgb, (grid + base) * plotMask);

    // Glow field of the trace, then ASCII glyphs quantize it.
    float d = traceDist(p);
    float age = smoothstep(xLeft - 6.0, xPen, p.x);   // older paper, dimmer ink
    float sigma = 2.2 + 5.0 * level + 3.0 * onset;
    float glow = exp(-d * d / (sigma * sigma)) * (0.35 + 0.65 * age) * penFade;

    vec2 cell = vec2(4.0, 6.0);
    vec2 ci = floor((p - vec2(xLeft - 8.0, yMid - amp - 3.0)) / cell);
    vec2 cc = vec2(xLeft - 8.0, yMid - amp - 3.0) + (ci + 0.5) * cell;
    float dc = traceDist(cc);
    float ty = traceY(cc.x);
    float under = (cc.y - yMid) * (ty - yMid) > 0.0 && abs(cc.y - yMid) < abs(ty - yMid) ? 1.0 : 0.0;
    float spread = 5.0 + 11.0 * level + 5.0 * onset;
    float cellAge = smoothstep(xLeft - 6.0, xPen, cc.x);
    float sweep = processing * exp(-pow((cc.x - mix(xLeft, xPen, fract(time * 0.8))) / 12.0, 2.0));
    float flick = hash21(ci + floor(time * 14.0)) - 0.5;
    lum = exp(-dc * dc / (spread * spread)) * (0.35 + 0.65 * cellAge) + under * 0.18 * cellAge
        + 0.06 + sweep * 0.55 + flick * (0.1 + 0.12 * level);
    lum = clamp(lum, 0.0, 0.999) * plotMask * (1.0 - smoothstep(xPen - 40.0, xPen + 4.0, cc.x));
    int gi = int(lum * 10.0);
    vec2 lp = floor(p - (cc - cell * 0.5));   // pixel inside the cell, 0..3 x 0..5
    float on = 0.0;
    if (lp.x < 3.0 && lp.y >= 0.0 && lp.y < 5.0) {
        float bit = (4.0 - lp.y) * 3.0 + (2.0 - lp.x);
        on = mod(floor(float(glyph(gi)) / exp2(bit)), 2.0);
    }
    vec3 asciiCol = mix(colMid.rgb, colRim.rgb, clamp(lum * 1.2, 0.0, 1.0));
    col = mix(col, asciiCol, on * (0.2 + 0.42 * lum) * mix(0.7, 1.0, dark));

    // The trace: soft glow, then a crisp core with a slight RGB split that
    // widens with loudness.
    vec3 glowCol = colRim.rgb;
    if (dark > 0.5) col += glowCol * glow * 0.55 * dark;
    else col = mix(col, glowCol, glow * 0.4);
    float split = 0.35 + 0.9 * level;
    float dR = traceDist(p + vec2(split, 0.0));
    float dB = traceDist(p - vec2(split, 0.0));
    float w = 0.7 + 0.35 * level;
    float coreR = 1.0 - smoothstep(w - 0.5, w + 0.6, dR);
    float coreG = 1.0 - smoothstep(w - 0.5, w + 0.6, d);
    float coreB = 1.0 - smoothstep(w - 0.5, w + 0.6, dB);
    vec3 ink = mix(colRim.rgb, colSpark.rgb, 0.55 + 0.45 * age);
    col = mix(col, ink, vec3(coreR, coreG, coreB) * (0.45 + 0.55 * age) * plotMask * penFade);

    // Stylus: arm from the right edge, head on the live pen, ruler ticks.
    vec2 pen = pt(0);
    float arm = (1.0 - smoothstep(0.3, 1.0, abs(p.y - pen.y))) * step(pen.x + 3.0, p.x) * step(p.x, c.x + hs.x - 5.0);
    col = mix(col, colLine.rgb, arm * 0.35 * penFade);
    float rulerX = c.x + hs.x - 7.0;
    float tick = (1.0 - smoothstep(0.3, 1.0, abs(fract((p.y - yMid) / (amp / 4.0) + 0.5) - 0.5) * amp / 4.0))
               * step(abs(p.x - rulerX), 2.0) * step(abs(p.y - yMid), amp + 0.5);
    col = mix(col, colLine.rgb, tick * 0.3);
    float headR = 2.0 + 1.6 * onset + 0.8 * level;
    float head = length(p - pen);
    col = mix(col, colCore.rgb, (1.0 - smoothstep(headR - 0.6, headR + 0.6, head)) * penFade);
    if (dark > 0.5) col += colCore.rgb * exp(-head * head / (18.0 + 40.0 * level)) * (0.35 + 0.5 * activity) * dark * penFade;
    else col = mix(col, colCore.rgb, exp(-head * head / (18.0 + 40.0 * level)) * 0.25 * penFade);

    // Rim: thin edge, brighter HUD brackets along the chamfers.
    float edge = 1.0 - smoothstep(0.0, 1.1, abs(sd + 0.6));
    vec2 q = abs(p - c);
    float bracket = step(hs.x - 26.0, q.x) * step(hs.y - 16.0, q.y);
    vec3 rimCol = mix(colEdge.rgb, colRim.rgb, 0.35 + 0.65 * bracket);
    col = mix(col, rimCol, edge * (0.55 + 0.45 * bracket));

    // Scanlines and grain.
    float scan = 1.0 - 0.06 * step(0.5, fract(gl_FragCoord.y * 0.5));
    col *= mix(1.0, scan, dark);
    float n = hash21(p * 1.7 + fract(time * 23.0) * 91.0) - 0.5;
    col += n * grain * 1.4;
    float dither = (hash21(gl_FragCoord.xy + 0.37) + hash21(gl_FragCoord.xy + 5.1) - 1.0) / 255.0;
    col += dither;

    // Premultiplied layers: shadow, then halo, then the panel.
    float sa = shadowA * (1.0 - 0.6 * dark);
    float ha = haloA * (dark > 0.5 ? 1.0 : 0.6);
    vec3 outer3 = colHalo.rgb * ha;
    float outerA = ha + sa * (1.0 - ha);
    float pa = colBg.a * inside;
    vec3 prem = clamp(col, 0.0, 1.0) * pa + outer3 * (1.0 - pa);
    float alpha = pa + outerA * (1.0 - pa);
    fragColor = vec4(prem, alpha) * qt_Opacity;
}
