# 从两条随机路径到整座发光城市：HPG 2026 冠军作品的程序化城市 GI 技术复盘

作者：Haowen Guo  
ShaderToy：https://www.shadertoy.com/view/sXBGRw  
代码仓库：https://github.com/haowenGuo/SHADERTTOY-Procedural-City-Global-GI

## 摘要

这篇文章复盘我的 HPG 2026 Student Competition 冠军作品 `SHADERTTOY-程序化城市-全局GI`。

比赛主题是 **Vast Proceduralism and Global Illumination**：作品既要在 ShaderToy 中实时生成大规模程序化场景，又要展示多次反弹、间接光、阴影和颜色传播。真正困难的地方不是分别做出“程序化城市”和“路径追踪器”，而是让两者在浏览器、WebGL 和极低采样数下共同工作。

最终方案不是一个纯粹的无偏路径追踪器，而是一套混合系统：

- 用 cell hash、低频城市构图 mask 和建筑 archetype 生成大规模城市。
- 用二维 DDA 只遍历光线实际穿过的 city cell。
- 用少量真实路径追踪保留 primary visibility、太阳直射、阴影、GGX 和少量多次反弹。
- 用程序化城市自身的结构，确定性地估计 sky visibility、道路反弹、立面互反弹、窗户/霓虹色溢出和金属/玻璃反射。
- 用时间累积和稀疏深路径采样，把昂贵计算分摊到多个 frame。

最重要的经验是：

> 在低 sample count 的大规模程序化场景里，不应该只问“还能多追踪几次 bounce”，而应该问“场景生成器已经知道哪些光照信息，能不能直接利用这些知识”。

---

## 1. 为什么这个题目比 Cornell Box 难得多

在 Cornell Box 中，即使采样数很低，间接光通常仍然比较容易出现。原因是：

- 光源面积相对大。
- 有色墙面距离近。
- 墙面在采样半球中占据很大立体角。
- 一条随机 diffuse ray 很容易命中有意义的表面。

城市恰好相反：

- 发光窗户和霓虹条很小。
- 光源分布稀疏，而且经常很远。
- 大量路径进入天空、道路或无贡献方向。
- 建筑遮挡复杂，shadow ray 和 secondary ray 都很昂贵。
- 金属和玻璃需要一个有内容的环境才能显得真实。

假设每个像素每帧只有 2 个 sample，那么随机路径命中一条远处霓虹的概率非常低。盲目把最大路径深度从 2 提高到 4，增加的主要是计算时间和噪声，而不是稳定可见的 GI。

因此，这个项目最后形成了一个明确的分工：

```text
真实路径追踪
  -> 几何可见性
  -> 太阳直射与阴影
  -> GGX / diffuse 路径续传
  -> 少量真实 secondary lighting
  -> 偶然命中的 emissive

程序化城市光照场
  -> 天空可见性
  -> 道路与广场反弹
  -> 建筑立面互反弹
  -> 窗户与霓虹色溢出
  -> 金属和玻璃的城市反射
```

前者提供物理可信度，后者提供稳定性、可读性和可控性。

---

## 2. 系统整体结构

ShaderToy 使用两个 pass：

- `Buffer A`：城市生成、光线求交、路径追踪、GI、相机状态和时间累积。
- `Image`：读取 Buffer A，并隐藏用于保存状态的前四个像素。

Buffer A 的前四个像素分别保存：

- 相机位置。
- yaw、pitch 和相机是否移动。
- 鼠标状态。
- 累积 sample 数。

每个普通像素的大致流程如下：

```text
生成带 jitter 的 camera ray
        |
        v
二维 DDA 遍历 city cell
        |
        v
解析最近表面的材质
        |
        +--> shadowed direct sun
        |
        +--> deterministic diffuse city GI
        |
        +--> deterministic city reflection field
        |
        +--> stochastic BSDF continuation
        |
        v
大气衰减 + 时间累积
```

这种设计的关键不是某一个复杂算法，而是让所有模块共享相同的程序化城市描述。

---

## 3. 用 cell hash 生成可重复的大规模城市

### 3.1 城市 cell

世界坐标的 `xz` 平面按固定大小划分：

```glsl
ivec2 cell = ivec2(floor(p.xz / CITY_CELL_SIZE));
```

最终版本中：

```glsl
const float CITY_CELL_SIZE = 4.0;
```

每个 cell 的道路类型、建筑高度、建筑宽度、材质、窗户和霓虹都由 cell 坐标经过 hash 得到。因此：

- 不需要保存城市地图。
- 相同坐标始终生成相同建筑。
- primary ray、shadow ray 和 GI 查询可以独立重建同一座城市。
- 场景在逻辑上可以持续延伸。

但纯 hash 会产生一个问题：随机不等于美观。每栋楼都独立随机时，skyline 会变成均匀噪声，缺少视觉中心和城市结构。

### 3.2 用低频 mask 组织城市构图

为解决纯随机城市缺乏层次的问题，最终版本加入了两个低频 mask。

`CitySpineMask` 负责中央街谷和城市主轴：

```glsl
float CitySpineMask(vec2 p)
{
    float mainSpine = 1.0 - smoothstep(7.0, 23.0, abs(p.x));
    float crossSpine = 1.0 - smoothstep(7.0, 23.0, abs(p.y - 8.0));
    return clamp(max(mainSpine, crossSpine * 0.55), 0.0, 1.0);
}
```

`CityLandmarkMask` 则在几个预设的低频区域形成高层地标簇：

```glsl
float CityLandmarkMask(vec2 p)
{
    float centerNeedle =
        1.0 - smoothstep(0.0, 18.0, length(p - vec2(0.0, 28.0)));
    float farNeedle =
        1.0 - smoothstep(0.0, 22.0, length(p - vec2(18.0, 74.0)));
    float westNeedle =
        1.0 - smoothstep(0.0, 20.0, length(p - vec2(-30.0, 48.0)));

    return max(centerNeedle, max(farNeedle * 0.84, westNeedle * 0.72));
}
```

这些 mask 不直接生成几何，而是影响：

- 建筑高度。
- 建筑 footprint。
- 玻璃和金属使用比例。
- 窗户密度。
- 霓虹强度。
- 高楼的细长程度。

这样保留了程序化生成的丰富性，同时获得了类似人工构图的 skyline。

### 3.3 建筑 archetype

每个非道路 cell 会选择一个抽象建筑类型：

```glsl
float BuildingArchetype(in ivec2 cell)
{
    return floor(Hash12(vec2(cell) + 188.4) * 5.0);
}
```

它们大致对应：

- warm block：偏暖色的低层或中层建筑。
- stepped podium：阶梯式裙楼。
- dark slab：横向或纵向拉伸的暗色板楼。
- glass needle：细长玻璃高塔。
- brick/composite tower：砖石和复合材料塔楼。

建筑高度并不是单个随机数，而是多个层次相加：

```glsl
totalHeight =
      9.0
    + 18.0 * heightSeed * heightSeed
    + 18.0 * skylineNoise
    + 24.0 * spine
    + 48.0 * landmark
    + 30.0 * glassNeedle * (0.40 + 0.60 * district)
    + 20.0 * darkSlab * spine
    + 34.0 * rareNeedle * district;
```

这个公式体现了一个很实用的程序化建模原则：

> 高频 hash 负责差异，低频 mask 负责秩序，少量稀有事件负责惊喜。

### 3.4 程序化立面与材质

建筑求交仍然以 analytic box 为主，但命中后会在 wall-space 中生成细节：

- 窗户网格。
- 冷暖窗光。
- 砖缝和 per-brick variation。
- 污渍 FBM。
- 金属结构线。
- 玻璃幕墙。
- 木质面板。
- 霓虹 sign frame。

最终只保留三个显式材质类型：

```glsl
MAT_DIFFUSE
MAT_GGX
MAT_THIN_GLASS
```

视觉上的砖、木、金属、玻璃差异主要由以下参数组合形成：

- `albedo`
- `roughness`
- `metallic`
- `emissive`
- 程序化城市反射场

这比为每一种建筑材料增加独立 BSDF 分支更紧凑，也更适合 ShaderToy。

---

## 4. 用二维 DDA 遍历城市

如果每条 ray 都测试大量建筑，路径深度稍微增加就会失控。城市已经天然被划分为 cell，因此最合适的加速结构就是二维 DDA。

### 4.1 Primary traversal

`TraceProceduralCity` 从 ray 起点所在 cell 开始，只测试光线依次穿过的 cell：

```glsl
for (int i = 0; i < CITY_MAX_CELLS; ++i)
{
    TraceCityCell(cell, rayPos, rayDir, hitInfo);

    float nextT = min(tMaxX, tMaxZ);

    if (hitInfo.dist < nextT)
        break;

    if (nextT > CITY_MAX_TRACE_DIST)
        break;

    if (tMaxX < tMaxZ)
    {
        cell.x += stepX;
        tMaxX += tDeltaX;
    }
    else
    {
        cell.y += stepZ;
        tMaxZ += tDeltaZ;
    }
}
```

最终参数为：

```glsl
const int CITY_MAX_CELLS = 56;
const float CITY_MAX_TRACE_DIST = 190.0;
```

循环既有 cell 数上限，也有距离上限，满足 ShaderToy 对有界循环和稳定性的要求。

### 4.2 Shadow traversal 与 proxy geometry

早期版本直接复用完整场景求交做阴影，结果非常昂贵。更麻烦的是，建筑立面材质、屋顶设备、尖塔和 beacon 都会重复执行。

最终版本为阴影单独设计了较便宜的 traversal：

```glsl
const int CITY_MAX_SHADOW_CELLS = 28;
const float CITY_MAX_SHADOW_TRACE_DIST = 110.0;
```

并使用 `GetFutureBuildingShadowBounds` 为每栋楼生成简化 proxy box。

这带来一个重要经验：

> Primary ray 需要知道“看到了什么”，shadow ray 通常只需要知道“有没有挡住”。

让不同 ray 类型使用不同精度，是整个项目最有效的优化之一。

---

## 5. 路径追踪器保留了什么

### 5.1 BSDF

路径追踪部分仍然是 physically based 的：

- diffuse 使用 cosine hemisphere sampling。
- GGX 同时采样 diffuse 和 specular lobe。
- Fresnel 使用 Schlick approximation。
- microfacet distribution 使用 GGX。
- visibility term 使用 Smith geometry。

对 diffuse 表面，cosine-weighted sampling 会使：

\[
\frac{f_r \cos\theta}{p(\omega)}
\]

简化为接近 albedo 的稳定权重。

对 GGX 表面，采样器根据 metallic 在 diffuse 和 specular 之间混合，并用混合 PDF 计算 throughput。

### 5.2 Direct sun

太阳方向由一个统一函数提供，天空太阳盘、高光和 direct lighting 都使用同一个方向，避免早期“天空太阳和真实光照对不上”的问题。

直射光的核心非常简单：

```glsl
vec3 wi = GetSunDirection();
float cosSurface = max(dot(hitInfo.normal, wi), 0.0);

if (!IsVisibleToLight(shadowOrigin, wi, CITY_MAX_SHADOW_TRACE_DIST))
    return vec3(0.0);

vec3 sunRadiance = vec3(1.00, 0.84, 0.62) * 7.2;
vec3 brdf = EvalBRDF(hitInfo, wo, wi);

direct += sunRadiance * brdf * cosSurface;
```

这里没有随机采样大面积光源，而是使用一个稳定的 directional sun 和一条 shadow ray。它牺牲了真实软阴影，但保住了最重要的建筑光影关系。

### 5.3 Path loop

`GetColorForRay` 中每次 surface hit 会依次处理：

1. Sky miss。
2. Thin glass。
3. Emissive hit。
4. Shadowed direct sun。
5. Primary hit 的 deterministic GI。
6. Primary hit 的 deterministic glossy reflection。
7. BSDF continuation。

真实路径仍然可以在 secondary bounce 命中发光窗户或霓虹。非 delta 路径命中的 emissive 会乘以较克制的权重，防止少量高亮样本造成 firefly。

throughput 和最终 radiance 也设置了上限：

```glsl
throughput = min(throughput, vec3(6.0));
ret = min(ret, vec3(8.0));
```

严格来说这会引入 bias，但在低样本交互式演示中，它显著提高了稳定性。

---

## 6. 为什么纯多 bounce 路径追踪没有解决问题

我们实际尝试过增加 bounce。效果并不像预期：

- 帧时间快速增长。
- 随机噪声明显增加。
- 大部分 secondary ray 仍然命中天空、暗路面或普通墙面。
- 霓虹和小窗户依然很难被随机命中。
- 金属和玻璃没有稳定环境反射，看起来仍像“涂了颜色的表面”。

问题的本质是重要性采样不足。

在这类城市中，真正高价值的间接光源是：

- 阳光照亮的道路和广场。
- 邻近建筑的大面积立面。
- 高密度亮窗区域。
- 霓虹和轨道设施。
- 远处城市的低频亮度分布。

这些信息已经存在于程序化生成规则中。继续增加随机 ray，相当于让渲染器重新猜一遍它本来就知道的东西。

于是我们把问题改写为：

> 能否把 city cell generator 同时看作一个低频 radiance generator？

这就是程序化城市 GI 场的来源。

---

## 7. 确定性的程序化城市 GI

最终 diffuse GI 可以写成：

\[
L_{\text{indirect}}
=
\rho
\left(
E_{\text{sky}} A_{\text{GI}}
+ E_{\text{ground}}
+ E_{\text{emissive}}
+ E_{\text{facade}}
+ E_{\text{second}}
\right)
\]

代码中对应：

```glsl
vec3 indirect =
      skyFill * giAO
    + sunGroundBounce
    + cityGlow
    + facadeBounce
    + secondBounce;

return hitInfo.albedo * min(indirect, vec3(2.6));
```

### 7.1 Road openness

`EstimateRoadOpenness` 检查 hit point 周围的 `3 x 3` cell：

- 道路和广场越多，说明环境越开阔。
- 开阔区域应得到更多天空光。
- 低处墙面也更容易接收到道路反弹。

这比发射多条随机 sky ray 便宜得多，而且没有时间噪声。

### 7.2 Building occlusion

`EstimateBuildingOcclusion` 同样查询附近 cell，但使用建筑 proxy 的高度和距离估计遮蔽：

- 附近建筑比 hit point 高得越多，遮蔽越强。
- 距离越远，影响越小。
- 屋顶和高层位置自然获得更低的 occlusion。

它不是几何意义上的精确 ambient occlusion，而是一个面向街谷尺度的低频遮蔽项。

### 7.3 Sky visibility

天空可见性由法线、高度、道路开阔度和建筑遮蔽共同决定：

```glsl
float skyVisibility =
      1.0
    - 0.36 * wallMask
    - 0.22 * lowCanyonMask
    - 0.42 * buildingOcclusion
    + 0.18 * roadOpenness;

skyVisibility = clamp(skyVisibility, 0.18, 1.0);
```

它表达了几个直观规律：

- 屋顶比立面更容易看见天空。
- 低处街谷比高处更暗。
- 密集建筑之间的天空光更弱。
- 临近宽阔道路的墙面会更亮。

### 7.4 Sun-to-ground bounce

道路和广场会接收太阳，然后向附近低层墙面反射暖色能量：

```glsl
vec3 sunGroundBounce =
    vec3(1.00, 0.62, 0.28)
    * sunOnGround
    * groundReach
    * wallReceivesGround
    * canyonWarmth
    * (0.08 + 0.16 * roadOpenness);
```

这个项是画面中“阳光不只停留在第一命中”的主要来源。它让阴影里的墙面仍然保留温暖的低频反弹，而不是简单加一个常量 ambient。

### 7.5 Window 和 neon color bleeding

`EstimateNearbyEmissionField` 查询附近 cell，并根据程序化规则重建：

- 这个 cell 是道路、广场还是建筑。
- 建筑有多高。
- 窗户密度大概是多少。
- 是否存在 neon sign。
- 发光颜色是 warm、cyan 还是 magenta。

贡献根据距离、接收表面法线和建筑高度衰减。

关键点在于，这些光源不一定需要被当前 stochastic path 真正命中。只要生成器知道附近存在一组亮窗，就可以把它们作为低频 irradiance source。

### 7.6 Facade-to-facade bounce

`EstimateFacadeBounceField` 估计邻近建筑立面的平均颜色和发光能量，再根据：

- 表面朝向。
- 建筑间距离。
- 对方建筑高度。
- 当前街谷遮蔽。
- 当前 hit 的高度。

生成立面之间的颜色传播。

这部分让砖墙附近产生暖色反弹，让玻璃和冷色建筑附近出现偏蓝的间接光，构成比普通 ambient 更明显的 color bleeding。

### 7.7 Cheap second bounce

在深街谷中，真实光通常会经过不止一次反弹。我们没有再追踪一轮完整 GI，而是使用：

```glsl
float multiBounceMask =
    (0.28 + 0.44 * buildingOcclusion)
    * (0.35 + 0.65 * wallMask);

vec3 secondBounce =
    (cityGlow * vec3(0.82, 0.90, 1.08)
    + facadeBounce * 0.85)
    * multiBounceMask;
```

遮蔽越强、表面越接近立面，second bounce 越明显。

这并不是严格的能量传输积分，而是用可解释的局部特征近似多次反弹后的低频结果。

---

## 8. 金属和玻璃为什么需要另一套场

漫反射 irradiance 不能直接解决金属和玻璃。

金属表面的颜色主要来自反射环境。如果环境查询只有天空，那么城市中的金属楼会呈现单一蓝色；如果完全依赖随机 glossy ray，低 sample 下又会出现噪声和不稳定高光。

因此加入了 `EstimateCitySpecularField`。

它根据 reflection direction，在附近 cell 中寻找可能出现在反射方向上的：

- 道路灯带。
- 广场装置。
- 窗户群。
- 霓虹立面。
- 高层建筑。
- 远处城市 horizon。

每个候选项根据以下因素计算权重：

- reflection direction 与候选方向的对齐程度。
- roughness 对 lobe 宽度的影响。
- 距离衰减。
- 候选建筑高度是否覆盖当前反射高度。
- 接收面与候选方向是否处于同一半球。

GGX 表面最终使用：

```glsl
return (cityReflection + skyReflection)
       * F
       * glossyMask
       * roughDamp;
```

thin glass 则将 city field、sky reflection、Fresnel 和 sun glint 混合。

这个反射场不是真实几何反射，也不会产生精确建筑轮廓，但它提供了正确的低频语义：玻璃和金属会反射“这座城市”，而不只是反射一片天空色。

---

## 9. 时间维度上的路径预算

最终版本每帧只有：

```glsl
const int c_spp = 2;
```

但不同状态使用不同路径预算。

### 相机移动时

```glsl
maxBounces = 1;
maxNEEBounces = 1;
```

优先保证交互和 primary image 的稳定。

### 相机静止时

普通样本使用：

```glsl
sampleMaxBounces = 2;
sampleMaxNEEBounces = 1;
```

只有满足 checkerboard 条件的第一个 sample 使用更深路径：

```glsl
bool deepPathSample =
    !cameraMoved &&
    s == 0 &&
    mod(
        floor(fragCoord.x)
      + floor(fragCoord.y)
      + float(iFrame),
        4.0
    ) < 1.0;
```

也就是说，大约四分之一的像素在不同 frame 中轮流获得 3-hit path 和第二次 direct-light evaluation。

随后 Buffer A 将静止画面按 sample 数累积。

这可以理解为一种非常轻量的时间域 path-budget scheduling：

- 空间上稀疏。
- 时间上轮换。
- 累积后逐渐覆盖整张画面。

与每个像素每帧都追踪 3 hit 相比，它保留了深路径的存在，同时显著降低平均成本。

---

## 10. 几次关键失败，以及它们教会了什么

### 10.1 阴影看起来不真实

最初阴影问题并不完全来自光照公式，而来自几何查询、太阳定义和城市尺度不一致：

- 天空太阳和 direct-light sun direction 没有完全共享定义。
- 面光源位置让近似太阳产生了不合理的透视变化。
- 完整场景 trace 用于阴影时过慢。
- 简化阴影过度时又会和可见建筑不一致。

最终做法是统一 `GetSunDirection`，改为稳定 directional sun，并为 shadow ray 设计独立 proxy traversal。

经验是：阴影“真实感”首先来自方向、遮挡和尺度的一致，而不一定来自更多 sample。

### 10.2 金属和玻璃像塑料

早期只调整 roughness、metallic 和 Fresnel，但效果仍然差。

根本原因不是 BRDF 错了，而是周围没有足够可反射的 radiance。一个正确的金属 BRDF，如果输入环境只有平坦天空，仍然会显得单调。

最终通过 city specular field 给反射表面提供结构化环境。

经验是：材质表现由 `BRDF x lighting environment` 共同决定。只改材质参数，无法补偿缺失的环境信息。

### 10.3 增加 bounce 却没有明显 GI

这是整个项目最重要的一次失败。

增加 bounce 的确让算法更接近路径追踪，但画面没有按同样比例变好，因为小型 emissive 在采样域中的概率仍然太低。

最终转向“真实浅路径 + 确定性低频 GI”。

经验是：计算量应该跟随贡献，而不是跟随算法形式。

### 10.4 纯随机城市缺少冲击力

纯 cell hash 能产生无限变化，却无法自动产生好的构图。

加入 spine、landmark 和 archetype 以后，城市才开始具备：

- 主次关系。
- 远近层次。
- 可识别 skyline。
- 材质分区。
- 默认相机下的视觉中心。

经验是：程序化生成需要“随机性”和“设计意图”同时存在。

---

## 11. 性能结果

最终本地验证配置：

- Chrome / WebGL2。
- ANGLE D3D11。
- 分辨率 `640 x 360`。
- `c_spp = 2`。
- 移动时 1 hit。
- 静止普通样本 2 hits。
- 静止 checkerboard 深样本 3 hits。
- Primary DDA 最多 56 cells。
- Shadow DDA 最多 28 cells。

shader 编译完成后的实测约为：

```text
84.6 ms/frame
```

首次编译明显更慢，因为 shader 包含大量程序化分支、材质逻辑和固定上界循环。但 steady-state 渲染保持稳定，没有无界循环或动态分配。

这里最值得关注的不是绝对帧率，而是最终画面中同时存在：

- 大规模程序化城市。
- 可见太阳阴影。
- 真实 secondary path。
- 道路反弹。
- 立面 color bleeding。
- 窗户和霓虹局部照明。
- 金属和玻璃的城市反射。
- 时间累积。

---

## 12. 如何看待这套混合 GI 的物理正确性

这套方法不是无偏路径追踪。

以下机制会引入 bias：

- deterministic irradiance field。
- city specular field。
- cheap second bounce。
- throughput/radiance clamp。
- shadow proxy。
- thin glass 的风格化反射。

但它也不是简单的“加 ambient color”。每一个间接光项都和场景中的可解释变量有关：

- 表面方向。
- 表面高度。
- 道路开阔度。
- 邻近建筑高度。
- 建筑材质。
- 窗户和霓虹密度。
- 太阳方向。
- reflection direction。

因此，更准确的描述是：

> 一个由程序化场景先验引导的、physically motivated hybrid GI renderer。

它保留了真实光线传输最重要的骨架，再用场景特定的低频估计补充低采样下最难收敛的部分。

对于 ShaderToy 竞赛，这种路线比追求形式上的完全无偏更有价值，因为评委最终看到的是有限时间内的画面、技术完整性和主题表达。

---

## 13. 最终经验

### 经验一：程序化生成器也可以是光照数据结构

生成器知道建筑在哪里、楼有多高、窗户是否发光、道路是否开阔。将这些信息只用于 geometry generation 是一种浪费。

### 经验二：GI 必须被看见

在比赛画面里，间接光不能只存在于数学定义中。需要通过道路暖反弹、立面色溢出、街谷明暗和玻璃反射，让观众一眼辨认出 GI。

### 经验三：为不同 ray 选择不同精度

Primary ray、shadow ray、GI query 和 reflection query 对几何精度的需求完全不同。把它们全部交给同一个完整 trace，是最直接也最昂贵的做法。

### 经验四：时间是另一维采样预算

在静止画面里，不需要所有像素同时计算最深路径。稀疏深样本加时间累积，可以用更低平均成本保留多 bounce 信息。

### 经验五：材质问题经常其实是光照问题

金属和玻璃不真实，不一定要继续调 roughness。先检查环境里是否有足够丰富、方向正确的 radiance。

### 经验六：无限随机不等于宏大

真正的“vast”不只来自数量，还来自主轴、地标、远景、尺度变化和可识别的城市组织。

---

## 结语

这个项目最初的目标，是在 ShaderToy 中做一个拥有真实 GI 的大规模程序化城市。实际开发以后，我们发现真正的问题不是“如何把 path tracer 再加深一层”，而是“如何让有限的路径预算准确地服务于城市中最重要的光”。

最终方案让路径追踪负责可信度，让程序化城市负责提供稳定的低频光照知识，再通过 DDA、proxy geometry、稀疏深路径和时间累积控制成本。

如果要用一句话概括这次作品的技术路线，那就是：

> 我们没有让两条随机路径独自理解整座城市，而是让整座程序化城市主动参与光的传播。

