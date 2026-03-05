import SpriteKit

/// Creates SKShader instances for per-sprite hue rotation
/// Replaces SwiftUI `.hueRotation()` with a GLSL fragment shader for SpriteKit
enum HueRotationShader {
    /// GLSL fragment shader that rotates hue by `u_hueAngle` (in radians)
    private static let shaderSource = """
    void main() {
        vec4 color = texture2D(u_texture, v_tex_coord);

        // Skip fully transparent pixels
        if (color.a < 0.01) {
            gl_FragColor = color;
            return;
        }

        // Convert RGB to HSL
        float maxC = max(color.r, max(color.g, color.b));
        float minC = min(color.r, min(color.g, color.b));
        float delta = maxC - minC;

        float hue = 0.0;
        float sat = 0.0;
        float lum = (maxC + minC) / 2.0;

        if (delta > 0.001) {
            sat = lum < 0.5 ? delta / (maxC + minC) : delta / (2.0 - maxC - minC);

            if (maxC == color.r) {
                hue = (color.g - color.b) / delta + (color.g < color.b ? 6.0 : 0.0);
            } else if (maxC == color.g) {
                hue = (color.b - color.r) / delta + 2.0;
            } else {
                hue = (color.r - color.g) / delta + 4.0;
            }
            hue /= 6.0;
        }

        // Apply hue rotation
        hue = fract(hue + u_hueAngle / 6.28318530718);

        // Convert HSL back to RGB
        float c = (1.0 - abs(2.0 * lum - 1.0)) * sat;
        float x = c * (1.0 - abs(mod(hue * 6.0, 2.0) - 1.0));
        float m = lum - c / 2.0;

        vec3 rgb;
        float h6 = hue * 6.0;
        if (h6 < 1.0) rgb = vec3(c, x, 0.0);
        else if (h6 < 2.0) rgb = vec3(x, c, 0.0);
        else if (h6 < 3.0) rgb = vec3(0.0, c, x);
        else if (h6 < 4.0) rgb = vec3(0.0, x, c);
        else if (h6 < 5.0) rgb = vec3(x, 0.0, c);
        else rgb = vec3(c, 0.0, x);

        gl_FragColor = vec4(rgb + m, color.a);
    }
    """

    /// Create a shader with the given hue angle in degrees
    static func shader(hueAngleDegrees: Double) -> SKShader {
        let shader = SKShader(source: shaderSource)
        let radians = Float(hueAngleDegrees * .pi / 180.0)
        shader.uniforms = [SKUniform(name: "u_hueAngle", float: radians)]
        return shader
    }

    /// Update an existing shader's hue angle
    static func updateAngle(_ shader: SKShader, hueAngleDegrees: Double) {
        let radians = Float(hueAngleDegrees * .pi / 180.0)
        shader.uniformNamed("u_hueAngle")?.floatValue = radians
    }
}
