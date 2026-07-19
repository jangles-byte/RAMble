import Foundation

/// Metal shader source, compiled at runtime so the app ships as a pure
/// SwiftPM executable with no metallib build step.
///
/// The pipeline is HDR: particles render emissive light into an rgba16Float
/// accumulation buffer (bright cores exceed 1.0), a multi-scale bloom chain
/// spreads that overflow, and the composite pass tone-maps the result with a
/// filmic (ACES) curve plus a cinematic post-grade (vignette + subtle
/// chromatic aberration) before writing straight to the transparent drawable.
enum ShaderSource {
    /// Preamble prepended to every `FullscreenShaderPlugin`'s fragment source.
    /// Provides the shared uniform layout, a fullscreen-triangle vertex stage
    /// (`sp_vertex`), and value-noise / fbm helpers so shader plugins stay
    /// short. A plugin only writes `fragment float4 <entry>(SPOut in [[stage_in]],
    /// constant SPUniforms &u [[buffer(0)]]) { ... }`.
    static let fullscreenPreamble = """
    #include <metal_stdlib>
    using namespace metal;

    struct SPUniforms {
        float2 resolution;
        float time, ram, cpu, gpu, swap, pressure, stress, tokens, inference, intensity;
        float pad0, pad1, pad2;
    };
    struct SPOut { float4 position [[position]]; float2 uv; };

    vertex SPOut sp_vertex(uint vid [[vertex_id]]) {
        const float2 pos[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        SPOut o;
        o.position = float4(pos[vid], 0, 1);
        o.uv = pos[vid] * 0.5 + 0.5;
        o.uv.y = 1.0 - o.uv.y;
        return o;
    }

    static inline float sp_hash21(float2 p) {
        p = fract(p * float2(123.34, 345.45));
        p += dot(p, p + 34.345);
        return fract(p.x * p.y);
    }
    static inline float sp_vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = sp_hash21(i), b = sp_hash21(i + float2(1, 0));
        float c = sp_hash21(i + float2(0, 1)), d = sp_hash21(i + float2(1, 1));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    static inline float sp_fbm(float2 p) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { s += a * sp_vnoise(p); p = p * 2.02 + float2(3.1, 1.7); a *= 0.5; }
        return s;
    }
    static inline float3 sp_hue(float3 base, float3 warn, float t) {
        return mix(base, warn, clamp(t, 0.0, 1.0));
    }
    """

    static let library = """
    #include <metal_stdlib>
    using namespace metal;

    // MARK: - Particles (instanced quads, HDR emissive sprite)

    struct ParticleIn {
        float2 position;   // scene units (points)
        float2 velocity;   // used for motion-stretch
        float4 color;      // linear RGBA
        float  size;       // radius in points
        float  glow;       // 0..1 extra emission
        float  shape;      // 0 = disc, 1 = square, 2 = streak
        float  depth;      // -1 (near) … +1 (far); 0 = screen plane
    };

    struct SceneUniforms {
        float2 viewport;       // points
        float  globalAlpha;
        float  time;
        float  sceneScale;     // applied in NDC space → scales from center
        float2 camOffset;      // slow orbital camera sway (unit vector-ish)
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float  glow;
        float  shape;
    };

    vertex VOut particle_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device ParticleIn *particles [[buffer(0)]],
                                constant SceneUniforms &u [[buffer(1)]]) {
        // Two-triangle quad from vertex id. Padded a little past the radius so
        // the soft exponential falloff has room to fade instead of clipping.
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(-1,1),
            float2(1,-1),  float2(1,1),  float2(-1,1)
        };
        ParticleIn p = particles[iid];
        float2 corner = corners[vid];
        const float pad = 1.5;   // quad is 1.5× the radius

        float2 axisX = float2(1, 0);
        float2 axisY = float2(0, 1);
        float2 halfSize = float2(p.size, p.size) * pad;
        if (p.shape > 1.5) {
            // Streak: stretch along velocity for motion-blurred trails.
            float speed = length(p.velocity);
            float2 dir = speed > 0.001 ? p.velocity / speed : float2(1, 0);
            axisX = dir;
            axisY = float2(-dir.y, dir.x);
            halfSize = float2(p.size * pad * (1.0 + min(speed * 0.015, 3.0)),
                              p.size * pad * 0.5);
        }
        // Pseudo-3D: perspective scale around the screen center, distance fog,
        // and parallax from the drifting camera. Near objects are bigger,
        // brighter, and sway more; far ones recede and dim.
        float d = clamp(p.depth, -1.0, 1.0);
        float t01 = (d + 1.0) * 0.5;             // 0 = near … 1 = far
        float persp = mix(1.30, 0.62, t01);
        float2 center = u.viewport * 0.5;
        float2 basePos = center + (p.position - center) * persp
                       - u.camOffset * d * 22.0;  // parallax
        halfSize *= persp;

        float2 world = basePos + axisX * corner.x * halfSize.x
                               + axisY * corner.y * halfSize.y;
        float2 ndc = world / u.viewport * 2.0 - 1.0;
        // NDC origin is the screen center, so scaling here grows/shrinks the
        // whole scene evenly toward all four corners.
        ndc *= u.sceneScale;

        VOut out;
        out.position = float4(ndc.x, ndc.y, 0, 1);
        out.uv = corner * pad;     // uv now spans ±pad; radius 1.0 = particle edge
        out.color = p.color;
        out.color.a *= u.globalAlpha * mix(1.0, 0.55, t01);   // depth fog
        out.color.rgb *= mix(1.05, 0.72, t01);
        out.glow = p.glow;
        out.shape = p.shape;
        return out;
    }

    fragment float4 particle_fragment(VOut in [[stage_in]]) {
        float r = length(in.uv);
        float3 baseColor = in.color.rgb;
        float energy;   // may exceed 1.0 → HDR core that blooms

        if (in.shape > 0.5 && in.shape < 1.5) {
            // Rounded square (memory modules, machines, packets) with a lit core.
            float2 d = abs(in.uv) - 0.66;
            float dist = length(max(d, 0.0)) - 0.14;
            float body = 1.0 - smoothstep(-0.06, 0.06, dist);
            float core = 1.0 - smoothstep(0.0, 0.5, length(in.uv));
            energy = body * (0.7 + in.glow * 0.7) + core * (0.6 + in.glow * 1.8);
        } else {
            // Emissive point light: a tight incandescent core inside a soft,
            // wide halo. Exponential falloff reads far softer than smoothstep.
            float core = exp(-r * r * 9.0);
            float halo = exp(-r * r * 2.2);
            energy = halo * (0.32 + in.glow * 0.42) + core * (0.85 + in.glow * 1.5);
        }

        float alpha = saturate(energy) * in.color.a;
        // Emissive HDR: brightness scales with energy so hot cores overshoot
        // 1.0 and drive the bloom. Premultiplied for additive accumulation.
        float3 rgb = baseColor * (1.0 + in.glow * 1.25) * energy * in.color.a;
        return float4(rgb, alpha);
    }

    // MARK: - Fullscreen passes

    struct FSOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex FSOut fullscreen_vertex(uint vid [[vertex_id]]) {
        const float2 pos[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        FSOut out;
        out.position = float4(pos[vid], 0, 1);
        out.uv = pos[vid] * 0.5 + 0.5;
        out.uv.y = 1.0 - out.uv.y;
        return out;
    }

    // Fade pass: the pipeline blends dst * blendColor (source factor is zero),
    // so the fragment output value is irrelevant — trails fade via blend state.
    fragment float4 fade_fragment(FSOut in [[stage_in]]) {
        return float4(0.0);
    }

    // Bright-pass: extract the HDR overflow with a soft knee. Cores above the
    // threshold pass through at full (unclamped) intensity to feed the bloom.
    fragment float4 threshold_fragment(FSOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       constant float &threshold [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 c = tex.sample(s, in.uv);
        float luma = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
        float knee = smoothstep(threshold, threshold + 0.5, luma);
        return float4(c.rgb * knee, c.a * knee);
    }

    // Linear-sampled copy → used to downsample bright into the mip chain.
    fragment float4 copy_fragment(FSOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        return tex.sample(s, in.uv);
    }

    // MARK: - Composite (multi-scale bloom + ACES tone map + post-grade)

    struct CompositeUniforms {
        float bloomStrength;
        float exposure;
        float vignette;      // 0 = none, 1 = strong
        float aberration;    // chromatic aberration amount
    };

    // ACES filmic tone-mapping curve (Narkowicz approximation).
    static inline float3 aces(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    fragment float4 composite_fragment(FSOut in [[stage_in]],
                                       texture2d<float> scene  [[texture(0)]],
                                       texture2d<float> bloomA [[texture(1)]],
                                       texture2d<float> bloomB [[texture(2)]],
                                       texture2d<float> bloomC [[texture(3)]],
                                       constant CompositeUniforms &u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = in.uv;

        float4 base = scene.sample(s, uv);

        // Multi-scale bloom: three progressively wider, softer octaves summed
        // with falling weight — the layered, cinematic glow. A tiny radial
        // chromatic offset on the widest octave adds a lens-like fringe.
        float2 dir = uv - 0.5;
        float2 ca = dir * u.aberration;
        float3 wide = float3(
            bloomC.sample(s, uv + ca).r,
            bloomC.sample(s, uv).g,
            bloomC.sample(s, uv - ca).b);
        float3 bloom = bloomA.sample(s, uv).rgb * 0.55
                     + bloomB.sample(s, uv).rgb * 0.45
                     + wide * 0.38;
        float bloomA_a = bloomA.sample(s, uv).a + bloomB.sample(s, uv).a
                       + bloomC.sample(s, uv).a;

        float3 hdr = base.rgb + bloom * u.bloomStrength;
        float3 mapped = aces(hdr * u.exposure);

        // Vignette: gently darken the far corners for a lensed, focused feel.
        float vig = 1.0 - u.vignette * smoothstep(0.35, 0.95, length(dir) * 1.35);
        mapped *= vig;

        // Straight-alpha coverage for the transparent overlay: bright light and
        // its bloom halo both contribute opacity over the desktop.
        float coverage = base.a + bloomA_a * u.bloomStrength;
        float alpha = saturate(max(coverage, dot(mapped, float3(0.34))));
        return float4(mapped, alpha);
    }
    """
}
