import Foundation

/// Metal shader source, compiled at runtime so the app ships as a pure
/// SwiftPM executable with no metallib build step.
enum ShaderSource {
    static let library = """
    #include <metal_stdlib>
    using namespace metal;

    // MARK: - Particles (instanced quads, soft-disc fragment)

    struct ParticleIn {
        float2 position;   // scene units (points)
        float2 velocity;   // used for motion-stretch
        float4 color;      // linear RGBA
        float  size;       // radius in points
        float  glow;       // 0..1 extra emission
        float  shape;      // 0 = disc, 1 = square, 2 = streak
        float  _pad;
    };

    struct SceneUniforms {
        float2 viewport;       // points
        float  globalAlpha;
        float  time;
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
        // Two-triangle quad from vertex id.
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(-1,1),
            float2(1,-1),  float2(1,1),  float2(-1,1)
        };
        ParticleIn p = particles[iid];
        float2 corner = corners[vid];

        float2 axisX = float2(1, 0);
        float2 axisY = float2(0, 1);
        float2 halfSize = float2(p.size, p.size);
        if (p.shape > 1.5) {
            // Streak: stretch along velocity.
            float speed = length(p.velocity);
            float2 dir = speed > 0.001 ? p.velocity / speed : float2(1, 0);
            axisX = dir;
            axisY = float2(-dir.y, dir.x);
            halfSize = float2(p.size * (1.0 + min(speed * 0.02, 4.0)), p.size * 0.6);
        }
        float2 world = p.position + axisX * corner.x * halfSize.x
                                  + axisY * corner.y * halfSize.y;
        float2 ndc = world / u.viewport * 2.0 - 1.0;

        VOut out;
        out.position = float4(ndc.x, ndc.y, 0, 1);
        out.uv = corner;
        out.color = p.color;
        out.color.a *= u.globalAlpha;
        out.glow = p.glow;
        out.shape = p.shape;
        return out;
    }

    fragment float4 particle_fragment(VOut in [[stage_in]]) {
        float r = length(in.uv);
        float mask;
        if (in.shape > 0.5 && in.shape < 1.5) {
            // Rounded square (memory modules, machines, packets).
            float2 d = abs(in.uv) - 0.75;
            float dist = length(max(d, 0.0)) - 0.15;
            mask = 1.0 - smoothstep(-0.08, 0.08, dist);
        } else {
            // Soft disc with a bright core.
            float core = 1.0 - smoothstep(0.0, 0.35, r);
            float halo = 1.0 - smoothstep(0.2, 1.0, r);
            mask = halo * (0.35 + in.glow * 0.4) + core * (0.8 + in.glow * 0.6);
        }
        float4 c = in.color;
        c.rgb *= (1.0 + in.glow * 1.5);
        c.a *= mask;
        c.rgb *= c.a;   // premultiply for additive-friendly blending
        return c;
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

    // Bright-pass threshold for bloom.
    fragment float4 threshold_fragment(FSOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       constant float &threshold [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 c = tex.sample(s, in.uv);
        float luma = dot(c.rgb, float3(0.299, 0.587, 0.114));
        float k = smoothstep(threshold, threshold + 0.3, luma);
        return float4(c.rgb * k, c.a * k);
    }

    // Composite: scene + bloom, straight alpha out for the transparent layer.
    fragment float4 composite_fragment(FSOut in [[stage_in]],
                                       texture2d<float> scene [[texture(0)]],
                                       texture2d<float> bloom [[texture(1)]],
                                       constant float &bloomStrength [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 base = scene.sample(s, in.uv);
        float4 glow = bloom.sample(s, in.uv);
        float4 c = base + glow * bloomStrength;
        return clamp(c, 0.0, 1.0);
    }
    """
}
