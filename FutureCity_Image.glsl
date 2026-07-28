void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = fragCoord / iResolution.xy;

    if (fragCoord.y < 1.0 && fragCoord.x < 4.0)
    {
        uv = (fragCoord + vec2(4.0, 0.0)) / iResolution.xy;
    }

    fragColor = texture(iChannel0, uv);
}
