#include <CoreImage/CoreImage.h>
using namespace metal;

namespace {
    // Middle grey in scene-linear light.
    constant float kMidGrey = 0.18;
    // Pivot of the sigmoid, in stops from middle grey; puts grey near 46% display value.
    constant float kPivot = 0.2;
    // Scene exposure, in stops over middle grey, that maps to display white.
    constant float kWhiteStops = 5.0;
    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

    float3 srgbToLinear(float3 v) {
        return select(pow((v + 0.055) / 1.055, 2.4), v / 12.92, v <= 0.04045);
    }

    float3 linearToSrgb(float3 v) {
        return select(1.055 * pow(v, 1.0 / 2.4) - 0.055, v * 12.92, v <= 0.0031308);
    }

    // Logistic curve in log exposure. The slope eases from `low` (toe and
    // mid-tones) to `high` (shoulder) so highlights roll off gently.
    float3 characteristic(float3 stops, float low, float high) {
        float3 k = mix(float3(low), float3(high), smoothstep(-1.5, 1.5, stops - kPivot));
        return 1.0 / (1.0 + exp(-k * (stops - kPivot)));
    }
}

extern "C" {
namespace coreimage {

/// Film tone curve and print character. Input and output are linear light;
/// the curve itself is evaluated per channel, which is what makes saturated
/// highlights shift and desaturate the way film does.
float4 filmTone(sample_t s,
                float contrast,
                float rolloff,
                float fade,
                float saturation,
                float3 shadowTint,
                float3 highlightTint) {
    float low = 0.8 * contrast;
    float high = low * (1.0 - 0.6 * rolloff);

    float3 stops = log2(max(s.rgb, 1e-5) / kMidGrey);
    float3 white = characteristic(float3(kWhiteStops), low, high);
    float3 d = saturate(characteristic(stops, low, high) / white);

    // Faded print: lifted blacks, slightly dimmer whites.
    d = fade + (1.0 - 1.3 * fade) * d;

    float l = dot(d, kLuma);
    d += shadowTint * (1.0 - l) * (1.0 - l) + highlightTint * l * l;
    d = mix(float3(dot(d, kLuma)), d, saturation);

    return float4(srgbToLinear(saturate(d)), s.a);
}

/// Adds grain in display space. `fine` and `coarse` hold zero-centred grain in
/// .r; grain is strongest in the mid-tones, like a negative.
float4 filmGrain(sample_t s, sample_t fine, sample_t coarse, float amount) {
    float3 d = linearToSrgb(saturate(s.rgb));
    float l = dot(d, kLuma);
    float weight = 0.15 + 3.4 * l * (1.0 - l);
    float n = fine.r + 0.5 * coarse.r;
    d += amount * weight * n;
    return float4(srgbToLinear(saturate(d)), s.a);
}

/// The light a pixel scatters (halation, bloom): `amount` of its luminance,
/// tinted. Where every channel clipped, the scene was brighter than the RAW
/// could record, so that light counts `clipGain` times over. A single clipped
/// channel (a bright warm wall) doesn't count: it isn't a light source.
float4 scatterSource(sample_t s, float3 tint, float amount, float clipGain) {
    float l = max(dot(s.rgb, kLuma), 0.0);
    float clipped = smoothstep(0.95, 0.99, min(min(s.r, s.g), s.b));
    return float4(tint * amount * l * (1.0 + clipGain * clipped), 1.0);
}

/// Adds only the light that `blurred` spreads beyond `source`: a glow from
/// bright into darker areas, leaving flat areas and the inside of a large
/// bright area unchanged.
float4 addHalo(sample_t s, sample_t blurred, sample_t source) {
    return float4(s.rgb + max(blurred.rgb - source.rgb, 0.0), s.a);
}

}
}
