#version 440
// omavoice recording overlay. One pass, analytic shapes, no textures.
// A row of mirrored elliptical lobes along a thin centerline (the glowing
// waveform reference) plus thin tapered spark rays from the center on speech
// onsets (the light burst reference), inside a rounded pill with a thin
// neon rim. Every color is a uniform derived from the current Omarchy theme
// (OverlayModel.paletteFrom); how the glow composites follows the theme's
// background lightness continuously rather than a light/dark preset. A film
// grain and a triangular dither finish it, so gradients never band.
// Compile with shaders/build.sh (qsb). Edges are antialiased with fwidth.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // item size in logical pixels
    float time;       // seconds, free running
    float flow;       // phase driven by cadence and intensity
    float level;      // smoothed speech level 0..1
    float activity;   // speech gate, smoothed 0..1
    float onset;      // onset energy 0..1
    float processing; // 0..1 while Voxtype transcribes
    float bgLum;      // OKLab lightness of the theme background 0..1
    float grain;      // film grain strength, about 0.04
    float margin;     // transparent space around the pill for its shadow
    vec4 amps;        // levels for lobe pairs 0 (center) .. 3 (outer)
    vec4 colBg;
    vec4 colEdge;
    vec4 colCore;
    vec4 colMid;
    vec4 colRim;
    vec4 colSpark;
    vec4 colLine;
    vec4 colHalo;
};

const float PI = 3.14159265;

float hash11(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.5453); }
float hash21(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

float sdRoundBox(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + vec2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float ampFor(int k) {
    int a = k < 0 ? -k : k;
    if (a == 0) return amps.x;
    if (a == 1) return amps.y;
    if (a == 2) return amps.z;
    return amps.w;
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    vec2 c = size * 0.5;
    vec2 d = p - c;

    // 1 on dark backgrounds, 0 on light, smooth in between.
    float dark = 1.0 - smoothstep(0.5, 0.72, bgLum);

    vec2 pillHalf = size * 0.5 - vec2(margin);
    float radius = pillHalf.y;
    float sd = sdRoundBox(d, pillHalf, radius);
    float aa = max(fwidth(sd), 1e-4);
    float inside = clamp(0.5 - sd / aa, 0.0, 1.0);

    // Waveform space: x in -1..1 across the pill (minus the rounded ends),
    // y in pixels from the centerline.
    float halfW = pillHalf.x - radius * 0.55;
    float x = d.x / halfW;
    float y = d.y;
    float hMax = pillHalf.y - 3.0;

    // Processing: lobes settle into a slow outward ripple.
    float thinking = processing * (0.08 + 0.06 * sin(time * 3.2 - abs(x) * 7.0));

    // One continuous envelope: a smooth max of Gaussian lobes, so loud
    // neighbors neck into each other like a fluid waveform instead of
    // reading as separate beads. Each lobe also carries a warmth (warm in
    // the middle, cool at the ends) and a hollow weight, blended by how much
    // it contributes at this x.
    const float spacing = 2.0 / 7.0;
    float env3 = 0.0;
    float wsum = 0.0;
    float warm = 0.0;
    float hollowX = 0.0;
    for (int k = -3; k <= 3; k++) {
        float fk = float(k);
        int ak = k < 0 ? -k : k;
        float taper = 1.0 - 0.14 * float(ak);
        float wobble = 0.84 + 0.16 * sin(flow * 2.3 + fk * 1.9);
        float breathe = 0.05 + 0.02 * sin(time * 1.6 + fk * 1.3);
        float a = max(pow(ampFor(k), 1.15) * taper * wobble * 1.5, breathe * (1.0 - processing));
        a = max(a, thinking);
        float xk = fk * spacing + 0.024 * sin(flow * 1.1 + fk * 2.4);
        // Louder lobes swell sideways a little too.
        float w = spacing * (0.42 + 0.14 * clamp(a * 1.6, 0.0, 1.0));
        float dx = (x - xk) / w;
        float g = exp(-dx * dx);
        float c = clamp(a, 0.0, 1.0) * g;
        env3 += c * c * c;
        wsum += c;
        warm += c * (1.0 - 0.3 * float(ak));
        hollowX += c * exp(-dx * dx * 6.0);
    }
    float envH = pow(env3, 1.0 / 3.0);
    warm /= max(wsum, 1e-4);
    hollowX /= max(wsum, 1e-4);
    float ends = smoothstep(1.16, 0.82, abs(x));
    float hk = envH * ends * hMax + 0.75;
    float q = abs(y) / hk;
    float qw = max(fwidth(q), 1e-4);
    // Feathered edge: soft light, not an outline. Thin shapes stay crisp.
    float feather = mix(0.05, 0.5, clamp(hk / 10.0, 0.0, 1.0));
    float body = 1.0 - smoothstep(1.0 - feather - qw, 1.0 + qw, q);
    // Slightly soft, raw optics: red and blue edges sit a fraction of a
    // pixel apart, more when the voice is loud.
    float fringe = 0.08 + 0.16 * level;
    float bodyR = 1.0 - smoothstep(1.0 - feather - qw, 1.0 + qw, abs(y + fringe) / hk);
    float bodyB = 1.0 - smoothstep(1.0 - feather - qw, 1.0 + qw, abs(y - fringe) / hk);

    // Hot core, a middle band, and the rim role (usually the theme accent)
    // over most of the body, so each theme's own hue carries the shape.
    // Cooler outer lobes reach the rim color sooner.
    float cool = 1.0 - warm;
    vec3 col = mix(colCore.rgb, colMid.rgb, smoothstep(0.05, 0.4 - cool * 0.2, q));
    col = mix(col, colRim.rgb, smoothstep(0.42 - cool * 0.25, 0.85, q));
    // Tall lobes open a dim hollow down their middle, like the reference.
    float hollow = 1.0 - 0.5 * smoothstep(0.55, 0.95, envH) * hollowX * (1.0 - smoothstep(0.55, 0.95, q));
    float lift = 0.5 + 0.5 * clamp(envH * 2.2, 0.0, 1.0);
    float strength = body * 0.7 * hollow * lift;
    vec3 strength3 = vec3(bodyR, body, bodyB) * 0.7 * hollow * lift;
    float haloMax = exp(-max(q - 1.0, 0.0) * 4.0) * (1.0 - body) * clamp(envH * 2.5, 0.0, 1.0) * ends;
    vec3 fx = col * strength3 + colRim.rgb * haloMax * 0.18 * dark;
    float cover = max(strength * 1.25, haloMax * 0.2);

    // Centerline: hairline core plus a faint halo, hot near the middle.
    float lineAa = max(fwidth(y), 1e-4);
    float lineCore = clamp(0.8 - abs(y) / lineAa * 0.8, 0.0, 1.0);
    float lineHalo = exp(-abs(y) / 2.5) * 0.35;
    float along = smoothstep(1.12, 0.6, abs(x));
    float hot = exp(-x * x / 0.02) * (0.2 + 0.6 * level);
    float sweepPos = sin(time * 2.1) * 0.85;
    float sweep = exp(-pow((x - sweepPos) / 0.12, 2.0)) * processing;
    float lineI = (lineCore + lineHalo * dark) * along * (0.55 + 0.45 * activity) + (lineCore + lineHalo) * (hot * along + sweep * 1.4);
    vec3 lineCol = mix(colLine.rgb, colSpark.rgb, clamp(hot * 0.6 + sweep, 0.0, 1.0));
    fx += lineCol * lineI;
    cover = max(cover, clamp(lineI, 0.0, 1.0));

    // Spark: thin tapered rays from the center, driven by onsets and loudness.
    float burst = clamp(onset * 3.2 + level * 0.18, 0.0, 1.0) * (1.0 - processing);
    if (burst > 0.001) {
        float r = length(d);
        float ang = atan(d.y, d.x);
        const float SECTORS = 44.0;
        float u = (ang / (2.0 * PI) + 0.5) * SECTORS;
        float sector = floor(u);
        float jitter = floor(time * 9.0);
        float h1 = hash11(sector + jitter * 13.0);
        float h2 = hash11(sector * 3.7 + 1.3);
        float live = step(0.7, h1);
        float center = (sector + 0.25 + 0.5 * h2) / SECTORS;
        float rayAng = (center - 0.5) * 2.0 * PI;
        float dAng = ang - rayAng;
        dAng = mod(dAng + PI, 2.0 * PI) - PI;
        float perp = abs(sin(dAng)) * r;
        float len = (10.0 + 70.0 * hash11(sector + 7.0 + jitter)) * burst;
        float t = clamp(r / max(len, 1.0), 0.0, 1.0);
        float width = mix(0.75, 0.06, t);
        float ray = clamp((width - perp) / max(fwidth(perp), 1e-3) + 0.5, 0.0, 1.0);
        ray *= (1.0 - t) * (1.0 - t) * step(0.0, cos(dAng)) * live * smoothstep(1.5, 4.0, r);
        float coreGlow = exp(-r / (2.5 + 7.0 * level)) * burst;
        fx += colSpark.rgb * (ray * 0.75 * burst + coreGlow * 0.4);
        cover = max(cover, clamp(ray * burst + coreGlow * 0.5, 0.0, 1.0));
    }

    // Compose onto the pill. Dark backgrounds add light; light ones lay
    // ink. Both are computed and blended by the background lightness.
    fx *= inside;
    cover *= inside;
    vec3 glowRgb = vec3(1.0) - exp(-fx * 1.1);
    float bgA = colBg.a * inside;
    vec3 bgPremul = colBg.rgb * bgA;

    vec3 rgbDark = bgPremul + glowRgb * inside;
    float alphaDark = bgA;
    vec3 ink = clamp(fx / max(cover, 1e-3), 0.0, 1.0);
    float inkA = clamp(cover, 0.0, 1.0) * 0.95;
    vec3 rgbLight = ink * inkA + bgPremul * (1.0 - inkA);
    float alphaLight = inkA + bgA * (1.0 - inkA);
    vec3 rgb = mix(rgbLight, rgbDark, dark);
    float alpha = mix(alphaLight, alphaDark, dark);

    // Neon rim: a thin tube just inside the edge and a soft glow outside it,
    // in the theme's halo color. It idles dim, brightens with the voice, and
    // a highlight travels round it while transcribing.
    float ang = atan(d.y, d.x);
    float travel = 0.5 + 0.5 * sin(ang * 2.0 - time * 3.4);
    float neon = 0.32 + 0.6 * activity * (0.35 + level) + 0.45 * processing * travel;
    float tube = exp(-abs(sd + 0.9) / 0.85) * neon;
    float outside = clamp(sd / aa + 0.5, 0.0, 1.0);
    float glowOut = exp(-max(sd, 0.0) / mix(3.5, 5.0, dark)) * outside * neon * mix(0.5, 0.7, dark);

    float edgeBand = clamp(1.0 - abs(sd + 0.5) / aa, 0.0, 1.0);
    vec3 edgeCol = mix(colEdge.rgb, colHalo.rgb, clamp(neon * 0.9, 0.0, 1.0));
    float edgeA = max(colEdge.a, clamp(neon, 0.0, 1.0)) * edgeBand;
    rgb = rgb * (1.0 - edgeA) + edgeCol * edgeA;
    alpha = max(alpha, edgeA);
    // The tube adds light on dark themes and deepens the color on light ones.
    rgb += colHalo.rgb * tube * inside * mix(0.35, 0.8, dark);

    // Soft shadow under the pill, then the outer neon glow.
    float shadow = exp(-max(sd, 0.0) / 6.0) * outside * mix(0.22, 0.10, dark);
    alpha = alpha + shadow * (1.0 - alpha);
    rgb += colHalo.rgb * glowOut;
    alpha = alpha + glowOut * (1.0 - alpha);

    // Film grain: monochrome, 24 fps, strongest in the midtones, only where
    // something is drawn. Then a triangular dither of one 8-bit step.
    vec2 px = gl_FragCoord.xy;
    float frameN = floor(time * 24.0);
    float g = hash21(px + frameN * vec2(37.0, 17.0)) + hash21(px * 1.7 + frameN * vec2(11.0, 53.0)) - 1.0;
    float lum = dot(rgb, vec3(0.2126, 0.7152, 0.0722)) / max(alpha, 1e-3);
    float mids = 0.45 + 2.2 * lum * (1.0 - lum);
    rgb += g * grain * mids * alpha;
    float dither = (hash21(px + 0.5 + frameN) + hash21(px.yx + 7.3 + frameN) - 1.0) / 255.0;
    rgb += vec3(dither) * alpha;
    rgb = clamp(rgb, vec3(0.0), vec3(alpha));

    fragColor = vec4(rgb, alpha) * qt_Opacity;
}
