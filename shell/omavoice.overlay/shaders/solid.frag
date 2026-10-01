#version 440
// omavoice recording overlay, the scope waveform in a lit, dimensional
// panel. Same inputs as wave.frag (the level history and the theme roles
// from OverlayModel.paletteFrom); finish picks the material:
// 1 glass: the scope panel's chamfered shape as a slab of frosted glass:
//   a beveled rim with fresnel edge light and lit corner brackets, a top
//   gloss, the scope's grainy ASCII glow suspended inside, and the waveform
//   floating in front of it, casting a shadow on the back pane. Pairs with
//   a Hyprland layer blur for real frost.
// 2 bezel: a brushed metal instrument bezel (screws, a record LED) around a
//   recessed, slightly curved CRT screen with a phosphor trace and glare.
// 3 depth: a glossy slab holding a perspective waterfall: the recent
//   seconds of voice recede as solid ribbons, newest in front.
// Light comes from the top left for every finish. Compile with
// shaders/build.sh (qsb).

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
    float seq;        // committed samples so far
    float finish;     // 1 glass, 2 bezel, 3 depth
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
const float PI = 3.14159265;
vec4 H[16];

int iclamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

float hv(int i) {
    i = iclamp(i, 0, N - 1);
    int q = i / 4;
    vec4 v = H[q];
    int c = i - q * 4;
    return c == 0 ? v.x : (c == 1 ? v.y : (c == 2 ? v.z : v.w));
}
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
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float sdRound(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// The scope's deflection at x, for a trace spanning x0..x1 with amplitude a.
float scopeOff(float x, float lv, float t, float x0, float x1, float a) {
    float u = clamp((x - x0) / (x1 - x0), 0.0, 1.0);
    float win = pow(sin(PI * u), 1.3);
    float w = sin(6.2831853 * 2.5 * u - t * 7.0)
            + (0.25 + 0.9 * onset) * 0.55 * sin(6.2831853 * 6.0 * u + t * 11.0)
            + lv * 0.4 * sin(6.2831853 * 11.0 * u - t * 17.0);
    return -lv * a * 0.95 * win * w / 2.0;
}
// Distance to that curve around baseline y0. Near the curve the slope
// corrected estimate is exact; farther out it collapses on steep stretches
// (vertical streaks in the glow), so it hands over to a sampled minimum.
float scopeDist(vec2 p, float y0, float lv, float t, float x0, float x1, float a) {
    float y = y0 + scopeOff(p.x, lv, t, x0, x1, a);
    float dy = (scopeOff(p.x + 1.0, lv, t, x0, x1, a) - scopeOff(p.x - 1.0, lv, t, x0, x1, a)) * 0.5;
    float local = abs(p.y - y) / sqrt(1.0 + dy * dy);
    if (local < 1.5) return local;
    float best = abs(p.y - y);
    for (int i = -6; i <= 6; i++) {
        float dx = float(i) * 2.5;
        best = min(best, length(vec2(dx, p.y - y0 - scopeOff(p.x + dx, lv, t, x0, x1, a))));
    }
    return mix(local, best, smoothstep(1.5, 3.5, local));
}

vec2 C; vec2 HS; float R;
float sdChamfer(vec2 p, vec2 b, float c) {
    vec2 q = abs(p) - b;
    float box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float cut = (abs(p.x) + abs(p.y) - (b.x + b.y - c)) * 0.70710678;
    return max(box, cut);
}

// The ASCII ramp " .:-=+*#%@" as 3x5 bitmaps, as in wave.frag.
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

// R < 0 means a chamfer of -R instead of rounded corners.
float panelSd(vec2 p) { return R < 0.0 ? sdChamfer(p - C, HS, -R) : sdRound(p - C, HS, R); }
vec2 panelGrad(vec2 p) {
    vec2 g = vec2(panelSd(p + vec2(0.75, 0.0)) - panelSd(p - vec2(0.75, 0.0)),
                  panelSd(p + vec2(0.0, 0.75)) - panelSd(p - vec2(0.0, 0.75)));
    return g / max(length(g), 1e-4);
}

const vec3 LIGHT = vec3(-0.28, -0.78, 0.56);

float gaussian(float d, float s) { return exp(-d * d / (s * s)); }

void main() {
    H[0] = h0; H[1] = h1; H[2] = h2; H[3] = h3; H[4] = h4; H[5] = h5; H[6] = h6; H[7] = h7;
    H[8] = h8; H[9] = h9; H[10] = h10; H[11] = h11; H[12] = h12; H[13] = h13; H[14] = h14; H[15] = h15;

    int F = int(finish + 0.5);
    vec2 p = qt_TexCoord0 * size;
    C = size * 0.5;
    HS = size * 0.5 - vec2(margin);
    R = F == 1 ? -11.0 : (F == 2 ? 13.0 : 17.0);
    float dark = 1.0 - smoothstep(0.5, 0.72, bgLum);
    vec3 L = normalize(LIGHT);
    vec3 white = vec3(1.0);

    float sd = panelSd(p);
    float aa = max(fwidth(sd), 1e-4);
    float inside = clamp(0.5 - sd / aa, 0.0, 1.0);
    vec2 g = panelGrad(p);
    float lv = max(level, Lf(0.0));
    float sweepX = mix(C.x - HS.x - 40.0, C.x + HS.x + 40.0, fract(time * 0.7));

    vec3 col = colBg.rgb;
    float bodyA = 1.0;

    if (F == 1) {
        // ---------------- glass
        float rimW = 11.0;
        float t = clamp(1.0 + sd / rimW, 0.0, 1.0);
        vec3 n = normalize(vec3(g * 1.25 * t * t, 1.0));
        float diff = dot(n, L);
        float fres = pow(1.0 - n.z, 1.6);
        float v = clamp((p.y - (C.y - HS.y)) / (2.0 * HS.y), 0.0, 1.0);

        vec3 tint = mix(colBg.rgb, colRim.rgb, 0.10);
        col = tint * mix(1.25, 0.82, v) + (dark > 0.5 ? 0.035 : 0.0) * (1.0 - v);
        col += (vnoise(p * 0.9) - 0.5) * 0.03;
        // Translucent, so the Hyprland layer blur (hyprland/overlay-blur.lua)
        // shows through as frost; keep it above that rule's ignore_alpha.
        bodyA = mix(0.47, 0.5, dark);

        float xL = C.x - HS.x + 10.0;
        float xR = C.x + HS.x - 10.0;
        float amp = HS.y - 9.0;
        float plotMask = smoothstep(xL - 6.0, xL + 14.0, p.x) * (1.0 - smoothstep(xR - 14.0, xR + 6.0, p.x));

        // Light leaking through the glass under the voice.
        float bloom = gaussian(length(vec2((p.x - C.x) * 0.22, p.y - C.y)), 12.0 + 20.0 * lv);
        col += colCore.rgb * bloom * (0.06 + 0.28 * activity) * (dark > 0.5 ? 1.0 : 0.5);

        // The waveform casts a soft shadow on the back pane.
        float dS = scopeDist(p - vec2(2.5, 4.5), C.y, lv, time, xL, xR, amp);
        col *= 1.0 - 0.38 * gaussian(dS, 3.2) * plotMask;

        // Liquid fill between the curve and the midline.
        float y = C.y + scopeOff(p.x, lv, time, xL, xR, amp);
        float filled = (p.y - C.y) * (y - C.y) > 0.0 && abs(p.y - C.y) < abs(y - C.y) ? 1.0 : 0.0;
        float depthIn = abs(p.y - C.y) / max(abs(y - C.y), 1.0);
        col = mix(col, colRim.rgb, filled * plotMask * (0.12 + 0.22 * depthIn));

        // The scope's dithered ASCII glow, etched into the glass: each 4x6
        // cell picks a glyph by how close its center is to the voice.
        vec2 cell = vec2(4.0, 6.0);
        vec2 org = vec2(xL - 8.0, C.y - amp - 3.0);
        vec2 ci = floor((p - org) / cell);
        vec2 cc = org + (ci + 0.5) * cell;
        float dc = scopeDist(cc, C.y, lv, time, xL, xR, amp);
        float yc = C.y + scopeOff(cc.x, lv, time, xL, xR, amp);
        float cfill = (cc.y - C.y) * (yc - C.y) > 0.0 && abs(cc.y - C.y) < abs(yc - C.y) ? 0.6 : 0.0;
        float spread = 5.0 + 11.0 * level + 5.0 * onset;
        float cmask = smoothstep(xL - 4.0, xL + 12.0, cc.x) * (1.0 - smoothstep(xR - 12.0, xR + 4.0, cc.x));
        float csweep = processing * gaussian(cc.x - mix(xL, xR, fract(time * 0.8)), 12.0);
        float flick = hash21(ci + floor(time * 14.0)) - 0.5;
        float lum = gaussian(dc, spread) * 0.8 + cfill * 0.45 + 0.06 + csweep * 0.55 + flick * (0.1 + 0.12 * level);
        lum = clamp(lum, 0.0, 0.999) * cmask * step(sd, -3.0);
        int gi = int(lum * 10.0);
        vec2 lp = floor(p - (cc - cell * 0.5));
        float on = 0.0;
        if (lp.x < 3.0 && lp.y >= 0.0 && lp.y < 5.0) {
            float bit = (4.0 - lp.y) * 3.0 + (2.0 - lp.x);
            on = mod(floor(float(glyph(gi)) / exp2(bit)), 2.0);
        }
        vec3 asciiCol = mix(colMid.rgb, colRim.rgb, clamp(lum * 1.2, 0.0, 1.0));
        float asciiA = on * (0.22 + 0.45 * lum) * mix(0.75, 1.0, dark);
        col = mix(col, asciiCol, asciiA);
        bodyA = max(bodyA, asciiA * 0.9);

        float d = scopeDist(p, C.y, lv, time, xL, xR, amp);
        float ghost = scopeDist(p, C.y, Lf(4.0), time - 0.09, xL, xR, amp);
        float sigma = 2.4 + 5.0 * lv + 3.0 * onset;
        vec3 glowCol = mix(colRim.rgb, colSpark.rgb, 0.3);
        col += glowCol * gaussian(d, sigma) * plotMask * (dark > 0.5 ? 0.55 : 0.35);
        col = mix(col, colRim.rgb, (1.0 - smoothstep(0.6, 1.6, ghost)) * 0.3 * plotMask);
        float w = 0.85 + 0.35 * lv;
        float core = 1.0 - smoothstep(w - 0.5, w + 0.7, d);
        // A glass tube: hot white center, colored edges.
        float tube = 1.0 - smoothstep(0.0, w + 0.6, d);
        col = mix(col, mix(colRim.rgb, colSpark.rgb, 0.6), core * plotMask);
        col = mix(col, white, tube * tube * 0.55 * plotMask);
        // The light inside the glass is solid even where the pane is clear.
        bodyA = max(bodyA, max(tube, gaussian(d, sigma) * 0.6) * plotMask);

        // Glass surface in front of everything: rim, fresnel, gloss.
        col *= 1.0 - 0.18 * t * t * (0.5 + 0.5 * g.y);
        col += mix(colRim.rgb, white, 0.65) * fres * (0.25 + 0.55 * max(diff, 0.0));
        float gsd = sdChamfer(p - C - vec2(0.0, -HS.y * 0.5), vec2(HS.x - 9.0, HS.y * 0.34), 6.0);
        float gfade = pow(clamp(1.0 - (p.y - (C.y - HS.y + 2.5)) / (HS.y * 0.85), 0.0, 1.0), 1.4);
        float gloss = (1.0 - smoothstep(-1.5, 1.5, gsd)) * gfade;
        col += white * gloss * mix(0.26, 0.2, dark);
        // A crisp specular streak on the top left shoulder of the dome.
        vec2 sp = (p - vec2(C.x - HS.x + 40.0, C.y - HS.y + 4.0)) / vec2(24.0, 1.4);
        col += white * gaussian(length(sp), 1.0) * 0.55;
        // The far wall: a darker band under the gloss, a soft bounce at the bottom.
        col *= 1.0 - 0.16 * gaussian(p.y - (C.y - HS.y * 0.05), HS.y * 0.25) * (1.0 - plotMask * 0.5);
        col += mix(colRim.rgb, white, 0.5) * gaussian(p.y - (C.y + HS.y * 0.72), 3.5) * gaussian(p.x - C.x, HS.x * 0.7) * 0.07;
        bodyA = max(bodyA, gloss * 0.3);
        // Caustic: light bent along the bottom inside edge.
        float caustic = gaussian(sd + 3.0, 1.6) * smoothstep(0.1, 0.9, g.y);
        col += mix(colRim.rgb, white, 0.4) * caustic * (0.22 + 0.25 * activity);
        // Hairline edge, bright where it faces the light.
        float hair = 1.0 - smoothstep(0.0, 1.0, abs(sd + 0.6));
        col = mix(col, white, hair * (0.18 + 0.55 * max(-g.y, 0.0)) * (0.6 + 0.4 * dark));
        bodyA = max(bodyA, hair * 0.85);
        // The scope's corner brackets, lit in the theme color along the rim.
        vec2 qa = abs(p - C);
        float bracket = step(HS.x - 26.0, qa.x) * step(HS.y - 16.0, qa.y);
        float bline = (1.0 - smoothstep(0.0, 1.1, abs(sd + 1.1))) * bracket;
        col = mix(col, mix(colRim.rgb, white, 0.25), bline * 0.85);
        col += colRim.rgb * gaussian(sd + 1.0, 3.0) * bracket * (0.12 + 0.25 * activity);
        bodyA = max(bodyA, bline);

        col += white * processing * 0.22 * gaussian(p.x + (p.y - C.y) * 0.7 - sweepX, 9.0);
    } else if (F == 2) {
        // ---------------- bezel
        float bez = 7.0;
        float t = -sd;
        vec2 sHS = HS - vec2(bez);
        float sRad = R - bez * 0.55;
        float ssd = sdRound(p - C, sHS, sRad);

        // Brushed, anodized metal tinted toward the theme.
        vec3 metal = mix(vec3(dark > 0.5 ? 0.2 : 0.76), colEdge.rgb, 0.28);
        float brushed = vnoise(vec2(p.x * 0.05, p.y * 3.1)) * 0.6 + vnoise(vec2(p.x * 0.4, p.y * 7.0)) * 0.4;
        float tiltOut = 0.85 * (1.0 - smoothstep(0.0, 3.0, t));
        float tiltIn = 1.1 * smoothstep(-2.6, 0.0, ssd);
        vec3 n = normalize(vec3(g * tiltOut - g * tiltIn, 1.0));
        float diff = max(dot(n, L), 0.0);
        float spec = pow(max(dot(n, normalize(L + vec3(0.0, 0.0, 1.0))), 0.0), 40.0);
        float aniso = 0.5 + 0.5 * sin((p.x - C.x) * 0.045 + 0.6);
        vec3 metalCol = metal * (0.45 + 0.75 * diff) * (0.9 + 0.2 * brushed) + white * spec * 0.45
                      + white * aniso * 0.035 * (1.0 - tiltOut);

        // Screws at both ends and a record LED on the top rail.
        vec2 sp = vec2(abs(p.x - C.x) - (HS.x - bez * 0.5 + 0.2), p.y - C.y);
        float sr = length(sp);
        float screw = 1.0 - smoothstep(2.1, 2.7, sr);
        vec2 sn = sp / max(sr, 1e-3);
        float screwLit = 0.55 + 0.45 * dot(-sn, normalize(L.xy)) * smoothstep(0.8, 2.4, sr);
        float slot = (1.0 - smoothstep(0.35, 0.8, abs(sp.x * 0.7 - sp.y * 0.7))) * step(sr, 1.8);
        metalCol = mix(metalCol, metal * 0.85 * screwLit, screw);
        metalCol = mix(metalCol, metal * 0.25, slot * screw);
        metalCol *= 1.0 - 0.35 * gaussian(sr - 2.8, 0.7) * step(2.1, sr) * smoothstep(-0.2, 0.6, sp.y / max(sr, 1e-3));

        vec2 ledP = vec2(C.x - HS.x + 22.0, C.y - HS.y + bez * 0.5);
        float ld = length(p - ledP);
        float ledOn = 0.25 + 0.75 * activity;
        vec3 ledCol = mix(colCore.rgb, colRim.rgb, processing * (0.5 + 0.5 * sin(time * 12.0)));
        metalCol = mix(metalCol, metal * 0.3, 1.0 - smoothstep(1.9, 2.5, ld));
        metalCol = mix(metalCol, mix(ledCol * 0.35, ledCol * 1.5 + 0.15, ledOn), 1.0 - smoothstep(1.3, 1.9, ld));
        metalCol += white * (1.0 - smoothstep(0.0, 0.8, length(p - ledP + vec2(0.5, 0.6)))) * 0.5 * ledOn;
        metalCol += ledCol * gaussian(ld, 5.0) * 0.35 * ledOn * step(2.2, ld);

        // The recessed screen: curved CRT glass, always dark.
        vec2 q = (p - C) / sHS;
        vec2 qc = q * (1.0 + 0.045 * dot(q, q));
        vec2 pc = C + qc * sHS;
        vec3 scr = mix(colBg.rgb * 0.55, vec3(0.025, 0.03, 0.035), dark > 0.5 ? 0.2 : 0.85);
        vec3 phos = colRim.rgb;
        if (dark < 0.5) phos = mix(colRim.rgb, white, 0.15);
        float xL = C.x - sHS.x + 10.0;
        float xR = C.x + sHS.x - 10.0;
        float amp = sHS.y - 5.0;
        float plotMask = smoothstep(xL - 4.0, xL + 12.0, pc.x) * (1.0 - smoothstep(xR - 12.0, xR + 4.0, pc.x));
        float gx = abs(fract((pc.x - C.x) / 20.0 + 0.5) - 0.5) * 20.0;
        float gy = abs(fract((pc.y - C.y) / (sHS.y * 0.5) + 0.5) - 0.5) * sHS.y * 0.5;
        float tick = (1.0 - smoothstep(0.0, 0.8, abs(pc.y - C.y))) * step(0.5, fract(pc.x / 4.0));
        vec3 sc = scr + phos * ((1.0 - smoothstep(0.0, 0.9, gx)) * 0.05 + (1.0 - smoothstep(0.0, 0.9, gy)) * 0.05 + tick * 0.06);

        float d = scopeDist(pc, C.y, lv, time, xL, xR, amp);
        float ghost = scopeDist(pc, C.y, Lf(4.0), time - 0.09, xL, xR, amp);
        float ghost2 = scopeDist(pc, C.y, Lf(8.0), time - 0.18, xL, xR, amp);
        sc += phos * gaussian(ghost, 1.6) * 0.22 * plotMask + phos * gaussian(ghost2, 1.6) * 0.1 * plotMask;
        sc += phos * gaussian(d, 3.0 + 4.0 * lv + 3.0 * onset) * 0.55 * plotMask;
        sc += phos * gaussian(d, 14.0) * (0.08 + 0.15 * lv) * plotMask;
        float w = 0.8 + 0.35 * lv;
        sc = mix(sc, mix(phos, white, 0.55), (1.0 - smoothstep(w - 0.5, w + 0.6, d)) * plotMask);
        float beam = processing * gaussian(pc.x - sweepX, 6.0) * plotMask;
        sc += phos * beam * 0.35;
        sc *= 1.0 - 0.07 * step(0.5, fract(gl_FragCoord.y * 0.5));
        sc *= 1.0 - 0.55 * pow(clamp(length(q * vec2(0.55, 1.0)), 0.0, 1.0), 3.0);
        // The bezel shades the top of the recess; glare sits on the glass.
        float into = -ssd;
        sc *= 1.0 - 0.55 * exp(-into / 2.2) * (0.55 + 0.45 * max(-g.y, 0.0));
        float glare = smoothstep(0.15, -0.5, (q.x * 0.28 + q.y)) * (1.0 - smoothstep(-0.2, 0.9, q.x)) * 0.07;
        sc += white * glare;
        sc += white * gaussian(ssd + 1.6, 0.7) * max(g.y, 0.0) * 0.18;
        float sIn = clamp(0.5 - ssd / max(fwidth(ssd), 1e-4), 0.0, 1.0);
        col = mix(metalCol, sc, sIn);

        float hair = 1.0 - smoothstep(0.0, 1.0, abs(sd + 0.5));
        col = mix(col, white, hair * 0.3 * max(-g.y, 0.0));
        col = mix(col, metal * 0.35, hair * 0.5 * max(g.y, 0.0));
    } else {
        // ---------------- depth
        vec3 slab = dark > 0.5 ? colBg.rgb * 0.9 : colBg.rgb;
        float v = clamp((p.y - (C.y - HS.y)) / (2.0 * HS.y), 0.0, 1.0);
        col = slab * mix(1.0, 0.75, v) + (dark > 0.5 ? 0.03 : 0.0) * (1.0 - v);
        bodyA = 0.96;

        const int K = 7;
        float W = HS.x - 16.0;
        float yF = C.y + HS.y * 0.42;
        float yB = C.y - HS.y * 0.52;
        float sMin = 1.0 / 2.7;
        vec3 fog = col;
        float glowAcc = 0.0;
        vec3 glowCol = vec3(0.0);
        vec3 acc = vec3(0.0);
        float rem = 1.0;
        for (int k = 0; k < K; k++) {
            float z = float(k) / float(K - 1);
            float s = 1.0 / (1.0 + 1.7 * z);
            float base = yB + (yF - yB) * (s - sMin) / (1.0 - sMin);
            float x0 = C.x - W * s;
            float x1 = C.x + W * s;
            float a = HS.y * 0.95 * s;
            float lk = k == 0 ? lv : Lf(float(k) * 3.0);
            float tk = time - float(k) * 0.13;
            float endFade = smoothstep(x0 - 2.0, x0 + 18.0 * s, p.x) * (1.0 - smoothstep(x1 - 18.0 * s, x1 + 2.0, p.x));
            if (p.x < x0 - 2.0 || p.x > x1 + 2.0) continue;
            float y = base + scopeOff(p.x, lk, tk, x0, x1, a);
            float dy = (scopeOff(p.x + 1.0, lk, tk, x0, x1, a) - scopeOff(p.x - 1.0, lk, tk, x0, x1, a)) * 0.5;
            float d = (p.y - y) / sqrt(1.0 + dy * dy);
            float near = mix(1.0, 0.28, z);
            vec3 ink = mix(colRim.rgb, colSpark.rgb, (1.0 - z) * 0.5);
            ink *= 1.0 + processing * 0.5 * (0.5 + 0.5 * sin(time * 9.0 - float(k) * 1.1));
            // The ribbon: a lit top face, then its darker front wall.
            float th = 3.4 * s;
            float lit = clamp(0.55 - dy * 0.45, 0.15, 1.0);
            vec3 top = mix(fog, ink * (0.45 + 0.75 * lit), near * endFade);
            float wallT = smoothstep(th, th + 16.0 * s, d);
            vec3 wall = mix(fog, mix(ink * 0.24, slab * 0.55, wallT), mix(0.9, 0.4, z) * endFade);
            vec3 rc = mix(top, wall, smoothstep(th - 0.6, th + 0.6, d));
            float edge = 1.0 - smoothstep(0.0, 1.1, abs(d));
            rc = mix(rc, mix(ink, white, 0.45 * (1.0 - z)), edge * near * endFade);
            // Glow from this ribbon lands on whatever shows above it.
            float cov = smoothstep(-0.7, 0.7, d);
            float gw = gaussian(min(p.y - y, 0.0), (2.5 + 5.0 * lk) * s + 1.0) * near * endFade * (1.0 - cov);
            glowCol += ink * gw * rem;
            glowAcc += gw * rem;
            // Front to back with antialiased coverage, so edges blend into
            // the ribbons behind instead of the empty slab.
            acc += rc * cov * rem;
            rem *= 1.0 - cov;
            if (rem < 0.003) break;
        }
        col = acc + col * rem;
        if (dark > 0.5) col += glowCol * 0.45;
        else col = mix(col, glowCol / max(glowAcc, 1e-3), min(glowAcc, 1.0) * 0.25);

        // Glossy slab surface over the scene.
        float rimW = 9.0;
        float t = clamp(1.0 + sd / rimW, 0.0, 1.0);
        vec3 n = normalize(vec3(g * 1.1 * t * t, 1.0));
        float fres = pow(1.0 - n.z, 1.7);
        col += mix(colEdge.rgb, white, 0.6) * fres * (0.18 + 0.5 * max(dot(n, L), 0.0));
        float gsd = sdRound(p - C - vec2(0.0, -HS.y * 0.5), vec2(HS.x - 14.0, HS.y * 0.32), 12.0);
        float gfade = pow(clamp(1.0 - (p.y - (C.y - HS.y + 2.0)) / (HS.y * 0.8), 0.0, 1.0), 1.6);
        col += white * (1.0 - smoothstep(-1.5, 1.5, gsd)) * gfade * mix(0.12, 0.07, dark);
        float hair = 1.0 - smoothstep(0.0, 1.0, abs(sd + 0.6));
        col = mix(col, white, hair * (0.12 + 0.45 * max(-g.y, 0.0)));
        col = mix(col, vec3(0.0), hair * 0.35 * max(g.y, 0.0) * dark);
    }

    // Grain (live film grain on glass, as on the scope; static on the
    // solid materials) and dither.
    if (F == 1) col += (hash21(p * 1.7 + fract(time * 23.0) * 91.0) - 0.5) * grain * 1.4;
    else col += (hash21(floor(p * 1.3)) - 0.5) * grain * 0.8;
    col += (hash21(gl_FragCoord.xy + 0.37) + hash21(gl_FragCoord.xy + 5.1) - 1.0) / 255.0;

    // Two shadows (a tight contact one and a soft ambient one) and the
    // speech halo, all outside the panel.
    float out1 = max(panelSd(p - vec2(0.0, 1.5)), 0.0);
    float out2 = max(panelSd(p - vec2(0.0, 6.0)) + 2.0, 0.0);
    float shadowA = (gaussian(out1, 2.6) * 0.24 + gaussian(out2, 9.0) * 0.3) * (1.0 - inside);
    shadowA *= mix(0.75, 1.0, dark);
    float outer = max(sd, 0.0);
    float haloA = gaussian(outer, 6.0) * (0.08 + 0.24 * level + 0.15 * onset) * (1.0 - inside) * (dark > 0.5 ? 1.0 : 0.5);
    vec3 outer3 = colHalo.rgb * haloA;
    float outerA = haloA + shadowA * (1.0 - haloA);

    float pa = clamp(bodyA * colBg.a * inside, 0.0, 1.0);
    vec3 prem = clamp(col, 0.0, 1.0) * pa + outer3 * (1.0 - pa);
    float alpha = pa + outerA * (1.0 - pa);
    fragColor = vec4(prem, alpha) * qt_Opacity;
}
