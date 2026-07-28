/*
最终显示 pass。

Buffer A 的第一行前四个像素被用作持久状态：
  (0,0) camera position
  (1,0) yaw / pitch / cameraMoved
  (2,0) mouse state
  (3,0) accumulated sample count

如果直接显示 Buffer A，这四个像素会出现在画面左下角。
因此 Image pass 对这四个位置改为读取右侧第 4 个像素之后的正常画面，
其他位置则原样显示 Buffer A。
*/
void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    // ShaderToy texture 使用归一化 UV。
    vec2 uv = fragCoord / iResolution.xy;

    // 只处理第一行的前四个状态像素。
    if (fragCoord.y < 1.0 && fragCoord.x < 4.0)
    {
        // 向右偏移四个像素，避免把相机/累积状态当作颜色显示。
        uv = (fragCoord + vec2(4.0, 0.0)) / iResolution.xy;
    }

    // iChannel0 必须绑定 Buffer A。
    fragColor = texture(iChannel0, uv);
}

