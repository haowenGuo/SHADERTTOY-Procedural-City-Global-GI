/*
===============================================================================
 SHADERTTOY-程序化城市-全局GI：中文教学注释版
===============================================================================

这份文件与比赛版 FutureCity_BufferA.glsl 保持相同的渲染逻辑，只增加解释性注释。
建议按下面的顺序阅读，而不是一开始就从头逐行硬啃：

  1. SRayHitInfo / TestBoxTrace：一条光线如何得到命中信息。
  2. 城市 cell / TraceProceduralCity：如何只遍历光线穿过的城市网格。
  3. EvalBRDF / SampleBSDF：命中后如何决定光的反射方向和能量。
  4. EstimateDirectLighting：太阳直射与阴影。
  5. EstimateProceduralCityGI：确定性的漫反射城市 GI。
  6. EstimateCitySpecularField：金属和玻璃看到的低频城市反射。
  7. GetColorForRay：把所有模块串成一条路径。
  8. mainImage：相机、采样预算和时间累积。

常用方向约定：

  rayDir / wi  : 从当前点指向光线传播方向。
  wo           : 从表面指回上一个路径顶点，通常等于 -rayDir。
  N            : 当前表面法线。
  H            : 微表面 half vector，normalize(wi + wo)。
  throughput   : 当前路径尚未消耗的能量权重。
  ret          : 已经累计到相机的 radiance。

重要说明：

  - 这不是完全无偏的路径追踪器。
  - Primary visibility、太阳阴影、GGX 路径续传是真实光线查询。
  - 漫反射 GI 和城市高光场使用程序化场景先验，是稳定、可控的近似。
  - 所有循环都有固定上限，以满足 ShaderToy / WebGL 的稳定性要求。
*/

// 射线命中必须大于该距离。用于排除 t=0 附近的自相交。
const float c_minimumRayHitTime = 0.001;

// “没有命中”的哨兵距离。场景中所有有效距离都应小于它。
const float c_superFar = 1000.0;

// 新射线从表面稍微移开，避免浮点误差让它立刻再次命中原表面。
const float c_rayPosNormalNudge = 0.001;
const float c_PI_NEE = 3.1415926;

// 每个像素每帧追踪两条路径。静止后依靠时间累积继续提升质量。
const int c_spp = 2;

// 三种实际仍在使用的材质。砖、木、金属等外观由 GGX 参数表达，
// 因此不需要为每一种视觉材料都建立一个独立 materialType。
const int MAT_DIFFUSE     = 0;
const int MAT_GGX         = 1;
const int MAT_THIN_GLASS  = 5;

// 城市网格与遍历预算。
const float CITY_GROUND_Y = -4.0;
const float CITY_CELL_SIZE = 4.0;

// Primary ray 最多访问 56 个 cell 或走 190 个世界单位。
const int CITY_MAX_CELLS = 56;
const float CITY_MAX_TRACE_DIST = 190.0;

// Shadow ray 只回答“是否被遮挡”，使用更低的预算和简化建筑 proxy。
const int CITY_MAX_SHADOW_CELLS = 28;
const float CITY_MAX_SHADOW_TRACE_DIST = 110.0;

/*
一次最近命中的完整描述。

求交流程只负责更新 dist、normal、hitPoint、frontFace；
命中具体建筑部件之后，再由材质函数填充 albedo、emissive 等字段。
*/
struct SRayHitInfo
{
    // 沿 rayPos + rayDir * t 的参数 t。rayDir 归一化时也就是世界距离。
    float dist;

    // 始终朝向入射射线一侧的 shading normal。
    vec3 normal;

    // 漫反射颜色；对金属也作为金属 F0 的颜色来源。
    vec3 albedo;

    // 自发光 radiance。亮窗、霓虹和 beacon 使用它。
    vec3 emissive;

    // 世界坐标命中点，避免材质阶段重复计算 rayPos + rayDir * dist。
    vec3 hitPoint;

    // true 表示光线从几何外部击中表面。
    bool frontFace;

    int materialType;
    float roughness;
    float metallic;

    // 折射率。最终版 thin glass 主要做风格化反射，但仍保留该参数。
    float ior;
};

// 每次 trace 前必须初始化，确保未命中的字段有确定值。
void InitMaterialDefaults(inout SRayHitInfo hitInfo)
{
    hitInfo.materialType = MAT_DIFFUSE;
    hitInfo.roughness = 0.5;
    hitInfo.metallic = 0.0;
    hitInfo.ior = 1.5;
    hitInfo.albedo = vec3(0.0);
    hitInfo.emissive = vec3(0.0);
}

// 统一写入材质字段，避免不同几何分支遗漏 roughness、metallic 或 emissive。
void SetHitMaterial(
    inout SRayHitInfo hitInfo,
    in int materialType,
    in vec3 albedo,
    in vec3 emissive,
    in float roughness,
    in float metallic,
    in float ior
)
{
    hitInfo.materialType = materialType;
    hitInfo.albedo = albedo;
    hitInfo.emissive = emissive;
    hitInfo.roughness = roughness;
    hitInfo.metallic = metallic;
    hitInfo.ior = ior;
}

// ============================================================
// Hash / Noise / SDF
//
// 这些函数没有外部纹理输入：
// Hash 负责“每个 cell 不同”，Noise/FBM 负责“空间上连续变化”，
// SDF 只用于二维立面图案，不参与整座城市的 ray marching。
// ============================================================

// 2D -> 1D 的确定性伪随机 hash。相同坐标永远返回相同 [0,1) 数值。
float Hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// 用两个去相关 hash 产生二维随机值，主要用于建筑位置 jitter。
vec2 Hash22(vec2 p)
{
    float n = Hash12(p);
    return vec2(n, Hash12(p + n + 19.19));
}

// Value noise：取整数格点的四个 hash，并做双线性平滑插值。
float Noise2(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);

    // Hermite smoothstep 曲线，减轻格点边界的一阶导数突变。
    f = f * f * (3.0 - 2.0 * f);

    float a = Hash12(i);
    float b = Hash12(i + vec2(1.0, 0.0));
    float c = Hash12(i + vec2(0.0, 1.0));
    float d = Hash12(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 四个 octave 的 fractal Brownian motion。
// 低频决定大块明暗，高频补充砖墙、屋顶和地面的细碎变化。
float FBM(vec2 p)
{
    float v = 0.0;
    float a = 0.5;

    for (int i = 0; i < 4; ++i)
    {
        v += Noise2(p) * a;
        p *= 2.03;
        a *= 0.5;
    }

    return v;
}

// 二维 axis-aligned box SDF。负数在盒内，0 在边界，正数在盒外。
// 用于窗户矩形和霓虹 sign frame，而不是三维几何求交。
float sdBox2D(vec2 p, vec2 b)
{
    vec2 q = abs(p) - b;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
}

// ============================================================
// Brick Material
//
// 这里只改变命中表面的颜色和粗糙度，不增加真实砖块几何。
// 好处是远处仍有丰富立面，而每条 ray 只需要命中建筑的大 box。
// ============================================================

/*
生成错缝砖墙。

p          : 立面局部坐标，单位接近世界单位。
seed       : 当前建筑的稳定随机种子。
mortar     : 输出灰缝 mask，1 表示灰缝。
brickRand  : 输出当前砖块的稳定随机值。
返回值     : brick mask，1 表示砖体。
*/
float BrickPattern(
    in vec2 p,
    in float seed,
    out float mortar,
    out float brickRand
)
{
    float brickW = 0.42;
    float brickH = 0.20;

    vec2 q = p;

    // 奇偶行水平偏移半块砖，形成 running bond。
    float row = floor(q.y / brickH);
    q.x += mod(row, 2.0) * brickW * 0.5;

    vec2 brickId = floor(vec2(q.x / brickW, q.y / brickH));
    vec2 f = fract(vec2(q.x / brickW, q.y / brickH));

    float edgeX = min(f.x, 1.0 - f.x) * brickW;
    float edgeY = min(f.y, 1.0 - f.y) * brickH;

    // 到最近砖边的距离决定灰缝。
    float edge = min(edgeX, edgeY);

    mortar = 1.0 - smoothstep(0.015, 0.035, edge);
    brickRand = Hash12(brickId + seed);

    return 1.0 - mortar;
}

/*
根据 style 选择砖墙色板，再叠加：
  - 每砖随机色差
  - 局部深色斑块
  - FBM 污渍
  - 灰缝颜色
*/
vec3 BrickColor(
    in vec2 brickP,
    in ivec2 cell,
    in int style,
    out float mortarMask
)
{
    float brickRand;

    float brickMask = BrickPattern(
        brickP,
        Hash12(vec2(cell) + float(style) * 17.3),
        mortarMask,
        brickRand
    );

    vec3 brickA;
    vec3 brickB;
    vec3 brickC;

    if (style == 0)
    {
        brickA = vec3(0.40, 0.20, 0.13);
        brickB = vec3(0.62, 0.30, 0.18);
        brickC = vec3(0.26, 0.13, 0.09);
    }
    else if (style == 1)
    {
        brickA = vec3(0.32, 0.29, 0.26);
        brickB = vec3(0.52, 0.48, 0.42);
        brickC = vec3(0.20, 0.19, 0.17);
    }
    else if (style == 2)
    {
        brickA = vec3(0.36, 0.25, 0.18);
        brickB = vec3(0.64, 0.42, 0.28);
        brickC = vec3(0.22, 0.15, 0.11);
    }
    else if (style == 3)
    {
        brickA = vec3(0.27, 0.22, 0.18);
        brickB = vec3(0.46, 0.36, 0.28);
        brickC = vec3(0.15, 0.12, 0.09);
    }
    else
    {
        brickA = vec3(0.22, 0.24, 0.27);
        brickB = vec3(0.38, 0.41, 0.44);
        brickC = vec3(0.14, 0.16, 0.19);
    }

    // 同一块砖内部保持稳定颜色，不会随像素闪烁。
    vec3 brickCol = mix(brickA, brickB, brickRand);

    brickCol = mix(
        brickCol,
        brickC,
        smoothstep(0.70, 1.0, Hash12(floor(brickP * 3.7) + 11.2))
    );

    float dirt = FBM(brickP * 0.85 + vec2(float(style) * 3.1, 4.7));
    brickCol *= mix(0.82, 1.22, dirt);

    vec3 mortarCol = vec3(0.14, 0.14, 0.13);
    vec3 col = mix(brickCol, mortarCol, mortarMask);

    col *= mix(0.92, 1.10, brickMask);

    return col;
}

// ============================================================
// Atmosphere
// ============================================================

// 对第一命中之后的最终颜色施加距离雾。
// ext 是 RGB 分通道透射率，蓝通道衰减略快，用于塑造城市纵深。
vec3 ApplySceneAtmosphere(vec3 col, float t, vec3 rd)
{
    vec3 fogCol = vec3(0.42, 0.52, 0.66) - rd.y * vec3(0.05, 0.08, 0.12);
    vec3 ext = exp2(-t * 0.0022 * vec3(1.0, 1.22, 1.65));

    return col * ext + fogCol * (1.0 - ext);
}

// ============================================================
// Geometry
//
// 城市主体使用解析式 sphere / AABB 求交，而不是 SDF ray marching。
// 对盒状建筑来说，解析求交通常更稳定且步骤数固定。
// ============================================================

// 标准二次方程球体求交。只在 beacon 等少量圆形部件中使用。
bool TestSphereTrace(in vec3 rayPos, in vec3 rayDir, inout SRayHitInfo info, in vec4 sphere)
{
    vec3 oc = rayPos - sphere.xyz;
    float a = dot(rayDir, rayDir);
    float b = 2.0 * dot(oc, rayDir);
    float c = dot(oc, oc) - sphere.w * sphere.w;

    float discriminant = b * b - 4.0 * a * c;
    if (discriminant < 0.0)
        return false;

    float sqrtD = sqrt(discriminant);
    float t1 = (-b - sqrtD) / (2.0 * a);
    float t2 = (-b + sqrtD) / (2.0 * a);

    // 优先近交点；如果 ray 从球内出发，则改用远交点。
    float t = t1;
    if (t <= c_minimumRayHitTime)
        t = t2;

    if (t > c_minimumRayHitTime && t < info.dist)
    {
        info.dist = t;

        vec3 hitPoint = rayPos + rayDir * t;
        vec3 outwardNormal = normalize(hitPoint - sphere.xyz);

        // 保存几何正反面，但 shading normal 永远翻到迎向 ray 的一侧。
        info.frontFace = dot(rayDir, outwardNormal) < 0.0;
        info.normal = info.frontFace ? outwardNormal : -outwardNormal;
        info.hitPoint = hitPoint;

        return true;
    }

    return false;
}

/*
Slab method 的 axis-aligned box 求交。

对每个轴计算 ray 进入/离开该 slab 的 t 区间：
  tNear = 三个进入时间中的最大值
  tFar  = 三个离开时间中的最小值
若 tNear <= tFar，则三个轴的区间有重叠，ray 命中盒子。
*/
bool TestBoxTrace(
    in vec3 rayPos,
    in vec3 rayDir,
    inout SRayHitInfo info,
    in vec3 bmin,
    in vec3 bmax
)
{
    if (abs(rayDir.x) < 1e-6 && (rayPos.x < bmin.x || rayPos.x > bmax.x)) return false;
    if (abs(rayDir.y) < 1e-6 && (rayPos.y < bmin.y || rayPos.y > bmax.y)) return false;
    if (abs(rayDir.z) < 1e-6 && (rayPos.z < bmin.z || rayPos.z > bmax.z)) return false;

    // 平行于某轴时不用直接除以 0，而是使用很大的逆方向值。
    vec3 invD = vec3(
        abs(rayDir.x) < 1e-6 ? 1e20 : 1.0 / rayDir.x,
        abs(rayDir.y) < 1e-6 ? 1e20 : 1.0 / rayDir.y,
        abs(rayDir.z) < 1e-6 ? 1e20 : 1.0 / rayDir.z
    );

    vec3 t0 = (bmin - rayPos) * invD;
    vec3 t1 = (bmax - rayPos) * invD;

    vec3 tsmaller = min(t0, t1);
    vec3 tbigger  = max(t0, t1);

    float tNear = max(max(tsmaller.x, tsmaller.y), tsmaller.z);
    float tFar  = min(min(tbigger.x, tbigger.y), tbigger.z);

    if (tNear > tFar)
        return false;

    float t = tNear;
    if (t <= c_minimumRayHitTime)
        t = tFar;

    if (t <= c_minimumRayHitTime || t >= info.dist)
        return false;

    vec3 p = rayPos + rayDir * t;

    // 将命中点映射到约 [-1,1] 的盒局部空间，
    // 最大绝对分量对应命中的那个面，从而恢复 axis-aligned normal。
    vec3 center = 0.5 * (bmin + bmax);
    vec3 extent = 0.5 * (bmax - bmin);
    vec3 q = (p - center) / max(extent, vec3(1e-6));
    vec3 aq = abs(q);

    vec3 outwardNormal = vec3(0.0);

    if (aq.x > aq.y && aq.x > aq.z)
        outwardNormal = vec3(sign(q.x), 0.0, 0.0);
    else if (aq.y > aq.z)
        outwardNormal = vec3(0.0, sign(q.y), 0.0);
    else
        outwardNormal = vec3(0.0, 0.0, sign(q.z));

    info.dist = t;
    info.hitPoint = p;
    info.frontFace = dot(rayDir, outwardNormal) < 0.0;
    info.normal = info.frontFace ? outwardNormal : -outwardNormal;

    return true;
}

// ============================================================
// Future City Scene
//
// 城市生成分三层：
//   1. Cell role：当前 cell 是道路、广场还是建筑。
//   2. Building massing：建筑中心、裙楼、塔楼、高度和 archetype。
//   3. Surface appearance：命中后再生成窗户、砖、金属、玻璃和霓虹。
//
// 几何与材质都由 cell 坐标的 hash 决定，因此任何 ray 都能重建同一结果。
// ============================================================

// 统一的赛博城市强调色，在 cyan 与 magenta 之间插值。
vec3 FutureAccentColor(float t)
{
    return mix(
        vec3(0.08, 0.70, 1.00),
        vec3(1.00, 0.12, 0.82),
        smoothstep(0.0, 1.0, t)
    );
}

// 每 8 个 cell 出现一条主路。x 或 z 任一方向满足即为道路。
bool IsMainRoadCell(ivec2 cell)
{
    return abs(mod(float(cell.x), 8.0)) < 1.0 ||
           abs(mod(float(cell.y), 8.0)) < 1.0;
}

// 每 4 个 cell 出现一条带偏移的次级道路，打破主路网格过于稀疏的问题。
bool IsSecondaryRoadCell(ivec2 cell)
{
    return abs(mod(float(cell.x + 3), 4.0)) < 1.0 ||
           abs(mod(float(cell.y + 3), 4.0)) < 1.0;
}

// 道路 cell 不生成普通建筑，但可以生成高架轨道等基础设施。
bool IsRoadCell(ivec2 cell)
{
    return IsMainRoadCell(cell) || IsSecondaryRoadCell(cell);
}

// 广场只出现在非道路 cell。原点附近固定形成核心广场，其余极少量随机出现。
bool IsPlazaCell(ivec2 cell)
{
    if (IsRoadCell(cell))
        return false;

    vec2 c = vec2(cell);

    if (length(c) < 2.3)
        return true;

    return Hash12(c + 71.3) > 0.987;
}

/*
城市主轴低频 mask。

mainSpine 形成沿 z 方向延伸的中央走廊；
crossSpine 形成较弱的横向轴。
返回值越接近 1，建筑越倾向于高、细、玻璃化和高发光密度。
*/
float CitySpineMask(vec2 p)
{
    float mainSpine = 1.0 - smoothstep(7.0, 23.0, abs(p.x));
    float crossSpine = 1.0 - smoothstep(7.0, 23.0, abs(p.y - 8.0));
    return clamp(max(mainSpine, crossSpine * 0.55), 0.0, 1.0);
}

/*
地标簇 mask。

三个平滑径向场负责组织 skyline，而不是逐 cell 完全随机决定高楼。
中心位置和权重同时决定默认相机能够看到的前、中、远景层次。
*/
float CityLandmarkMask(vec2 p)
{
    float centerNeedle = 1.0 - smoothstep(0.0, 18.0, length(p - vec2(0.0, 28.0)));
    float farNeedle = 1.0 - smoothstep(0.0, 22.0, length(p - vec2(18.0, 74.0)));
    float westNeedle = 1.0 - smoothstep(0.0, 20.0, length(p - vec2(-30.0, 48.0)));
    return max(centerNeedle, max(farNeedle * 0.84, westNeedle * 0.72));
}

// 将稳定 hash 离散为 0..4 五种建筑 archetype。
float BuildingArchetype(in ivec2 cell)
{
    vec2 cf = vec2(cell);
    return floor(Hash12(cf + 188.4) * 5.0);
}

/*
生成可见建筑的两级体块：

  podiumMin/Max : 贴近地面的裙楼。
  towerMin/Max  : 裙楼之上的主塔。
  style         : 立面色板与材质倾向。
  totalHeight   : 从地面计算的总高度。

注意：这里没有把几何写入数组，只是根据 cell 临时算出 bounds。
*/
void GetFutureBuildingBounds(
    in ivec2 cell,
    out vec3 podiumMin,
    out vec3 podiumMax,
    out vec3 towerMin,
    out vec3 towerMax,
    out int style,
    out float totalHeight
)
{
    vec2 cf = vec2(cell);

    vec2 blockCenter = (cf + vec2(0.5)) * CITY_CELL_SIZE;
    float spine = CitySpineMask(blockCenter);
    float landmark = CityLandmarkMask(blockCenter);
    // district 将“城市主轴”和“地标区”统一为一个强度。
    float district = max(spine, landmark);
    float archetype = BuildingArchetype(cell);
    // 用 step 把连续 float archetype 转成互斥/近似互斥的类型 mask，
    // 避免在 GLSL 中引入更多复杂结构。
    float glassNeedle = step(3.5, archetype);
    float darkSlab = step(2.5, archetype) * (1.0 - step(3.5, archetype));
    float steppedPodium = step(1.5, archetype) * (1.0 - step(2.5, archetype));
    float warmBlock = step(0.5, archetype) * (1.0 - step(1.5, archetype));

    // 普通街区允许更大位置扰动；主轴区域更整齐，保持街谷边缘清晰。
    vec2 jitter = (Hash22(cf + 13.7) - 0.5) * CITY_CELL_SIZE * mix(0.18, 0.08, spine);
    vec2 center = blockCenter + jitter;

    landmark = max(landmark, CityLandmarkMask(center));
    district = max(spine, landmark);
    float skylineNoise = Hash12(cf * 0.31 + vec2(11.0, 3.7));
    float rareNeedle = smoothstep(0.90, 1.0, Hash12(cf + 41.2));
    float heightSeed = Hash12(cf + 1.3);

    // 高度 = 基础高度 + 局部随机 + 低频 skyline + 区域/类型偏置。
    // 这种“高频差异 + 低频秩序”的组合比单一随机高度更像城市。
    totalHeight =
          9.0
        + 18.0 * heightSeed * heightSeed
        + 18.0 * skylineNoise
        + 24.0 * spine
        + 48.0 * landmark
        + 30.0 * glassNeedle * (0.40 + 0.60 * district)
        + 20.0 * darkSlab * spine
        + 34.0 * rareNeedle * district;

    float podiumH = 2.6 + 4.0 * Hash12(cf + 7.3) + 3.2 * district + 2.2 * steppedPodium;

    float podW = CITY_CELL_SIZE * mix(0.64, 0.94, Hash12(cf + 11.1));
    float podD = CITY_CELL_SIZE * mix(0.64, 0.94, Hash12(cf + 17.9));
    podW *= mix(1.0, 1.10, steppedPodium + warmBlock * 0.45);
    podD *= mix(1.0, 1.10, steppedPodium + warmBlock * 0.45);

    float towerScaleX = mix(0.42, 0.72, Hash12(cf + 5.6));
    float towerScaleZ = mix(0.42, 0.72, Hash12(cf + 8.4));

    towerScaleX *= mix(1.0, 0.80, district);
    towerScaleZ *= mix(1.0, 0.80, district);

    // slenderAxis 决定在 x 或 z 方向压缩，让高塔朝向不完全一致。
    float slenderAxis = step(0.5, Hash12(cf + 64.2));
    towerScaleX *= mix(1.0, mix(0.48, 0.72, slenderAxis), glassNeedle);
    towerScaleZ *= mix(1.0, mix(0.72, 0.48, slenderAxis), glassNeedle);
    towerScaleX *= mix(1.0, mix(1.18, 0.62, slenderAxis), darkSlab);
    towerScaleZ *= mix(1.0, mix(0.62, 1.18, slenderAxis), darkSlab);
    towerScaleX *= mix(1.0, 0.86, steppedPodium);
    towerScaleZ *= mix(1.0, 0.86, steppedPodium);

    podiumMin = vec3(center.x - podW * 0.5, CITY_GROUND_Y, center.y - podD * 0.5);
    podiumMax = vec3(center.x + podW * 0.5, CITY_GROUND_Y + podiumH, center.y + podD * 0.5);

    float towerW = podW * towerScaleX;
    float towerD = podD * towerScaleZ;

    towerMin = vec3(center.x - towerW * 0.5, podiumMax.y, center.y - towerD * 0.5);
    towerMax = vec3(center.x + towerW * 0.5, CITY_GROUND_Y + totalHeight, center.y + towerD * 0.5);

    style = int(floor(Hash12(cf + 99.0) * 5.0));
    if (glassNeedle > 0.5 || landmark > 0.68)
        style = 4;
    else if (darkSlab > 0.5)
        style = 1;
    else if (steppedPodium > 0.5)
        style = 2;
}

/*
生成阴影、AO、GI 查询使用的简化建筑 proxy。

它有意忽略：
  - 裙楼/塔楼的精确分层
  - 窗户和立面材质
  - 屋顶设备、spire、beacon

这些查询通常只需要低频体积和大致高度。用 proxy 可以减少重复 hash、
分支和 box test；代价是阴影边缘可能和可见细节有轻微不一致。
*/
void GetFutureBuildingShadowBounds(
    in ivec2 cell,
    out vec3 bmin,
    out vec3 bmax
)
{
    vec2 cf = vec2(cell);
    vec2 blockCenter = (cf + vec2(0.5)) * CITY_CELL_SIZE;
    float spine = CitySpineMask(blockCenter);
    float landmark = CityLandmarkMask(blockCenter);
    float district = max(spine, landmark);

    float rareNeedle = smoothstep(0.90, 1.0, Hash12(cf + 41.2));
    float heightSeed = Hash12(cf + 1.3);
    float h =
          12.0
        + 24.0 * heightSeed * heightSeed
        + 18.0 * spine
        + 34.0 * landmark
        + 22.0 * rareNeedle * district;

    float w = CITY_CELL_SIZE * mix(0.56, 0.88, Hash12(cf + 11.1));
    float d = CITY_CELL_SIZE * mix(0.56, 0.88, Hash12(cf + 17.9));
    float slender = smoothstep(0.72, 1.0, Hash12(cf + 188.4)) * district;
    float axis = step(0.5, Hash12(cf + 64.2));

    w *= mix(1.0, mix(0.64, 1.08, axis), slender);
    d *= mix(1.0, mix(1.08, 0.64, axis), slender);

    bmin = vec3(blockCenter.x - w * 0.5, CITY_GROUND_Y, blockCenter.y - d * 0.5);
    bmax = vec3(blockCenter.x + w * 0.5, CITY_GROUND_Y + h, blockCenter.y + d * 0.5);
}

/*
根据命中位置生成建筑表面材质。

步骤：
  1. 根据命中法线选择水平坐标 localU。
  2. 用 localY / h 得到竖直归一化坐标 v。
  3. 先处理屋顶，再判断是否落入窗户。
  4. 非窗户区域叠加砖、结构线、金属、木和幕墙。
  5. 最后写入统一的 SRayHitInfo 材质字段。

这是一种 shading-time detail：几何仍是简单 box，但命中后看起来有复杂立面。
*/
void SetFutureFacadeMaterial(
    inout SRayHitInfo hitInfo,
    in ivec2 cell,
    in vec3 bmin,
    in vec3 bmax,
    in int style,
    in bool towerPart
)
{
    vec3 p = hitInfo.hitPoint;
    vec3 n = hitInfo.normal;

    float h = max(bmax.y - bmin.y, 0.001);
    // AABB normal 是轴对齐的，|n.y| > 0.5 即可稳定识别水平面。
    bool roof = abs(n.y) > 0.5;

    float localU;
    float wallWidth;

    // 对 x-facing wall，沿 z 轴作为水平立面坐标；反之沿 x 轴。
    if (abs(n.x) > 0.5)
    {
        localU = (p.z - bmin.z) / max(bmax.z - bmin.z, 1e-4);
        wallWidth = bmax.z - bmin.z;
    }
    else
    {
        localU = (p.x - bmin.x) / max(bmax.x - bmin.x, 1e-4);
        wallWidth = bmax.x - bmin.x;
    }

    float localY = p.y - bmin.y;
    float v = localY / h;
    vec2 cellCenter2 = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;
    float spineMask = CitySpineMask(cellCenter2);
    float landmarkMask = CityLandmarkMask(cellCenter2);
    float heightMask = smoothstep(22.0, 78.0, bmax.y - CITY_GROUND_Y);
    // signatureMask 表示“标志性建筑”程度，统一提高幕墙、窗光和霓虹倾向。
    float signatureMask = clamp(max(spineMask * 0.78, landmarkMask) + heightMask * 0.26, 0.0, 1.0);

    // 屋顶不生成窗户，使用较粗糙、略带噪声的 GGX 材质。
    if (roof)
    {
        float roofNoise = FBM(p.xz * 0.35 + vec2(float(style) * 2.1, 0.0));

        vec3 roofColor = vec3(0.20, 0.19, 0.18) * mix(0.82, 1.22, roofNoise);

        SetHitMaterial(
            hitInfo,
            MAT_GGX,
            roofColor,
            vec3(0.0),
            0.50,
            0.0,
            1.5
        );

        return;
    }

    float windowCols = towerPart ? mix(9.0, 13.0, signatureMask) : mix(6.0, 8.0, spineMask);
    float windowRows = towerPart ? mix(22.0, 34.0, signatureMask) : mix(8.0, 12.0, spineMask);

    // 将 [0,1] 立面 UV 放大成窗口网格；floor 得到窗口 ID，
    // fract 得到当前窗口内部的局部坐标。
    vec2 windowGrid = vec2(localU * windowCols, v * windowRows);
    vec2 windowCell = floor(windowGrid);
    vec2 windowUV = fract(windowGrid) - 0.5;

    float windowSDF = sdBox2D(windowUV, vec2(0.25, 0.32));

    // 用一个较小矩形留出窗框；顶部、底部和一层以下不生成普通窗户。
    bool isWindow =
        windowSDF < 0.0 &&
        v > 0.04 &&
        v < 0.96 &&
        localY > 1.0;

    if (isWindow)
    {
        float glassRand = Hash12(windowCell + vec2(cell) * 19.17);

        vec3 glassTint = mix(
            vec3(0.58, 0.78, 1.00),
            vec3(0.20, 0.38, 0.68),
            glassRand
        );

        float litThreshold = towerPart ? 0.78 : 0.86;
        litThreshold -= 0.14 * spineMask + 0.10 * heightMask + 0.08 * landmarkMask;

        // 高层、主轴和地标建筑降低点亮阈值，因此夜景密度更集中。
        bool litWindow =
            Hash12(windowCell + vec2(cell) * 31.37) >
            clamp(litThreshold, 0.46, 0.88);

        vec3 windowEmission = vec3(0.0);

        if (litWindow)
        {
            float warmCold = Hash12(windowCell + vec2(6.1, 17.3));

            windowEmission = mix(
                vec3(1.00, 0.58, 0.20),
                vec3(0.35, 0.70, 1.00),
                warmCold
            ) * (towerPart ? 0.80 : 0.45) * (1.0 + 0.75 * signatureMask);
        }

        // 窗户使用风格化 thin glass：不继续折射穿过建筑内部，
        // 而是直接计算天空/城市反射和自身 emission。
        SetHitMaterial(
            hitInfo,
            MAT_THIN_GLASS,
            glassTint,
            windowEmission,
            0.03,
            0.0,
            1.45
        );

        return;
    }

    // 砖纹理使用近似世界尺度坐标，因此不同尺寸建筑的砖块大小接近。
    vec2 brickP = vec2(localU * wallWidth, localY);

    float mortarMask;
    vec3 brickCol = BrickColor(
        brickP,
        cell,
        style,
        mortarMask
    );

    float verticalStructure =
        smoothstep(
            0.020,
            0.0,
            abs(fract(localU * (towerPart ? 5.0 : 3.0)) - 0.5)
        );

    float horizontalStructure =
        smoothstep(
            0.015,
            0.0,
            abs(fract(localY * 0.28) - 0.5)
        );

    // 结构线用于模拟立柱、层间梁，并成为金属面板的重要来源。
    float structureMask = max(verticalStructure, horizontalStructure);
    brickCol *= mix(1.0, 0.72, structureMask * 0.22);

    float grime = FBM(p.xz * 0.12 + vec2(float(style) * 4.3, 7.1));
    brickCol *= mix(0.88, 1.18, grime);

    float facadeSeed = Hash12(vec2(cell) + float(style) * 31.7);
    // panelGrid 与 windowGrid 分开，使“窗户分格”和“幕墙/金属板分格”
    // 不必完全重合，减少程序化重复感。
    vec2 panelGrid = vec2(localU * (towerPart ? 7.0 : 4.0), localY * (towerPart ? 0.42 : 0.32));
    vec2 panelCell = floor(panelGrid);
    vec2 panelUV = fract(panelGrid);
    float panelRand = Hash12(panelCell + vec2(cell) * 5.17 + float(style) * 13.1);

    float panelGap =
        max(
            1.0 - smoothstep(0.012, 0.030, min(panelUV.x, 1.0 - panelUV.x)),
            1.0 - smoothstep(0.010, 0.026, min(panelUV.y, 1.0 - panelUV.y))
        );

    float curtainPreference = smoothstep(0.36, 0.86, facadeSeed) * (towerPart ? 1.0 : 0.45);
    curtainPreference = clamp(curtainPreference + signatureMask * (towerPart ? 0.32 : 0.10), 0.0, 1.0);
    // curtainGlass 是连续 mask，不是简单 bool，用于平滑混合颜色和粗糙度。
    float curtainGlass = curtainPreference *
                         smoothstep(0.30, 0.86, panelRand) *
                         (1.0 - mortarMask) *
                         smoothstep(0.06, 0.18, v) *
                         (1.0 - smoothstep(0.93, 1.0, v));

    float metalPreference = smoothstep(0.18, 0.75, Hash12(vec2(cell) + 55.2));
    metalPreference = clamp(metalPreference + signatureMask * 0.18, 0.0, 1.0);
    float metalPanel = max(structureMask * 0.75, panelGap * 0.90) *
                       metalPreference *
                       (towerPart ? 1.0 : 0.65);

    float woodPreference = (towerPart ? 0.42 : 1.0) *
                           smoothstep(0.20, 0.78, Hash12(vec2(cell) + 144.6)) *
                           ((style == 2 || style == 3) ? 1.0 : 0.38);
    float woodPanel = woodPreference *
                      smoothstep(0.08, 0.36, panelUV.y) *
                      (1.0 - smoothstep(0.68, 0.94, panelUV.y)) *
                      step(0.52, panelRand);

    vec3 emissive = vec3(0.0);

    vec2 signUV = vec2(
        fract(localU * 2.0) - 0.5,
        fract(v * (towerPart ? 6.0 : 3.0)) - 0.5
    );

    float signFrame = abs(sdBox2D(signUV, vec2(0.42, 0.16)));
    float neonSeed = Hash12(vec2(cell) + 23.4);
    // neonSign 只在 sign frame 的窄边缘发光，并集中在 signature building。
    bool neonSign =
        signFrame < 0.015 &&
        v > 0.12 &&
        v < 0.82 &&
        neonSeed > mix(0.62, 0.38, signatureMask);

    if (neonSign)
    {
        emissive = FutureAccentColor(Hash12(vec2(cell) + 91.2)) * (towerPart ? 3.6 : 2.4) * (1.0 + 1.10 * signatureMask);
        brickCol *= 0.62;
    }

    float roughness = mix(0.76, 0.90, mortarMask);
    float metallic = 0.0;
    int materialType = MAT_GGX;

    vec3 glassPanelColor = mix(
        vec3(0.08, 0.14, 0.22),
        vec3(0.22, 0.42, 0.62),
        Hash12(vec2(cell) + panelCell + 88.8)
    );
    glassPanelColor += FutureAccentColor(Hash12(vec2(cell) + 91.2)) * curtainGlass * 0.12;

    vec3 metalColor = mix(
        vec3(0.20, 0.22, 0.24),
        vec3(0.58, 0.56, 0.50),
        Hash12(vec2(cell) + 203.3)
    );

    vec3 woodColor = mix(
        vec3(0.34, 0.20, 0.12),
        vec3(0.62, 0.42, 0.24),
        Hash12(panelCell + vec2(cell) + 18.6)
    );
    woodColor *= mix(0.84, 1.18, FBM(vec2(localU * wallWidth, localY * 1.7) + vec2(float(style), 9.1)));

    // 混合顺序体现覆盖关系：基础砖 -> 木 -> 金属 -> 玻璃。
    brickCol = mix(brickCol, woodColor, clamp(woodPanel, 0.0, 0.65));
    roughness = mix(roughness, 0.58, clamp(woodPanel, 0.0, 0.80));

    brickCol = mix(brickCol, metalColor, clamp(metalPanel, 0.0, 0.82));
    roughness = mix(roughness, 0.24, clamp(metalPanel, 0.0, 0.85));
    metallic = mix(metallic, 0.62, clamp(metalPanel, 0.0, 0.85));

    brickCol = mix(brickCol, glassPanelColor, clamp(curtainGlass, 0.0, 0.88));
    roughness = mix(roughness, 0.07, clamp(curtainGlass, 0.0, 0.90));
    metallic = mix(metallic, 0.0, clamp(curtainGlass, 0.0, 0.90));

    // 只有高度确定的连续幕墙区域才升级为 MAT_THIN_GLASS；
    // 其余玻璃倾向仍作为低 roughness GGX，避免过多特殊分支。
    if (curtainGlass > 0.82 && panelGap < 0.25 && Hash12(panelCell + vec2(cell) * 8.3) > 0.70)
    {
        materialType = MAT_THIN_GLASS;
        roughness = 0.025;
    }

    SetHitMaterial(
        hitInfo,
        materialType,
        brickCol,
        emissive,
        roughness,
        metallic,
        1.5
    );
}

// 广场 cell：低矮基座 + 可选发光 monolith，为城市提供开放空间和局部光源。
void TracePlazaCell(
    in ivec2 cell,
    in vec3 rayPos,
    in vec3 rayDir,
    inout SRayHitInfo hitInfo
)
{
    vec2 center2 = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;

    vec3 baseMin = vec3(center2.x - 1.45, CITY_GROUND_Y,       center2.y - 1.45);
    vec3 baseMax = vec3(center2.x + 1.45, CITY_GROUND_Y + 0.35, center2.y + 1.45);

    if (TestBoxTrace(rayPos, rayDir, hitInfo, baseMin, baseMax))
    {
        SetHitMaterial(
            hitInfo,
            MAT_GGX,
            vec3(0.28, 0.30, 0.34),
            vec3(0.0),
            0.24,
            0.0,
            1.5
        );
    }

    if (Hash12(vec2(cell) + 8.8) > 0.28)
    {
        vec3 monoMin = vec3(center2.x - 0.22, CITY_GROUND_Y + 0.35, center2.y - 0.22);
        vec3 monoMax = vec3(center2.x + 0.22, CITY_GROUND_Y + 3.80, center2.y + 0.22);

        if (TestBoxTrace(rayPos, rayDir, hitInfo, monoMin, monoMax))
        {
            vec3 emissive = vec3(0.0);

            if (abs(hitInfo.normal.x) > 0.5 || abs(hitInfo.normal.z) > 0.5)
            {
                float edge = smoothstep(
                    0.045,
                    0.0,
                    abs(fract((hitInfo.hitPoint.y - monoMin.y) * 2.8) - 0.5)
                );

                emissive = FutureAccentColor(Hash12(vec2(cell) + 77.0)) * edge * 3.2;
            }

            SetHitMaterial(
                hitInfo,
                MAT_GGX,
                vec3(0.10, 0.12, 0.16),
                emissive,
                0.08,
                0.0,
                1.5
            );
        }
    }
}

// 主路上的高架轨道梁柱。次级道路保持空旷，不增加这类几何。
void TraceRoadInfrastructureCell(
    in ivec2 cell,
    in vec3 rayPos,
    in vec3 rayDir,
    inout SRayHitInfo hitInfo
)
{
    if (!IsMainRoadCell(cell))
        return;

    vec2 cellBase = vec2(cell) * CITY_CELL_SIZE;
    vec2 center = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;

    bool horizontalLine = abs(mod(float(cell.y), 8.0)) < 1.0;
    bool verticalLine   = abs(mod(float(cell.x), 8.0)) < 1.0;

    float railY0 = CITY_GROUND_Y + 4.0;
    float railY1 = CITY_GROUND_Y + 4.45;

    if (horizontalLine)
    {
        vec3 beamMin = vec3(cellBase.x, railY0, center.y - 0.24);
        vec3 beamMax = vec3(cellBase.x + CITY_CELL_SIZE, railY1, center.y + 0.24);

        if (TestBoxTrace(rayPos, rayDir, hitInfo, beamMin, beamMax))
        {
            SetHitMaterial(
                hitInfo,
                MAT_GGX,
                vec3(0.16, 0.18, 0.22),
                vec3(0.0),
                0.18,
                0.05,
                1.5
            );
        }

        vec3 colMin = vec3(center.x - 0.14, CITY_GROUND_Y, center.y - 0.14);
        vec3 colMax = vec3(center.x + 0.14, railY0,        center.y + 0.14);

        if (TestBoxTrace(rayPos, rayDir, hitInfo, colMin, colMax))
        {
            SetHitMaterial(
                hitInfo,
                MAT_GGX,
                vec3(0.20, 0.21, 0.24),
                vec3(0.0),
                0.28,
                0.0,
                1.5
            );
        }
    }

    if (verticalLine)
    {
        vec3 beamMin = vec3(center.x - 0.24, railY0, cellBase.y);
        vec3 beamMax = vec3(center.x + 0.24, railY1, cellBase.y + CITY_CELL_SIZE);

        if (TestBoxTrace(rayPos, rayDir, hitInfo, beamMin, beamMax))
        {
            SetHitMaterial(
                hitInfo,
                MAT_GGX,
                vec3(0.16, 0.18, 0.22),
                vec3(0.0),
                0.18,
                0.05,
                1.5
            );
        }

        vec3 colMin = vec3(center.x - 0.14, CITY_GROUND_Y, center.y - 0.14);
        vec3 colMax = vec3(center.x + 0.14, railY0,        center.y + 0.14);

        if (TestBoxTrace(rayPos, rayDir, hitInfo, colMin, colMax))
        {
            SetHitMaterial(
                hitInfo,
                MAT_GGX,
                vec3(0.20, 0.21, 0.24),
                vec3(0.0),
                0.28,
                0.0,
                1.5
            );
        }
    }

}

/*
当前 cell 的几何分发入口。

顺序很重要：
  road  -> 只测试道路基础设施
  plaza -> 只测试广场
  else  -> 测试普通建筑、屋顶设备、spire、beacon

所有测试共享 hitInfo；TestBoxTrace 只在 t 更小时覆盖，因此最终留下最近命中。
*/
void TraceCityCell(
    in ivec2 cell,
    in vec3 rayPos,
    in vec3 rayDir,
    inout SRayHitInfo hitInfo
)
{
    if (IsRoadCell(cell))
    {
        TraceRoadInfrastructureCell(cell, rayPos, rayDir, hitInfo);
        return;
    }

    if (IsPlazaCell(cell))
    {
        TracePlazaCell(cell, rayPos, rayDir, hitInfo);
        return;
    }

    vec3 podiumMin, podiumMax;
    vec3 towerMin, towerMax;
    int style;
    float totalHeight;

    GetFutureBuildingBounds(cell, podiumMin, podiumMax, towerMin, towerMax, style, totalHeight);

    if (TestBoxTrace(rayPos, rayDir, hitInfo, podiumMin, podiumMax))
    {
        SetFutureFacadeMaterial(hitInfo, cell, podiumMin, podiumMax, style, false);
    }

    if (TestBoxTrace(rayPos, rayDir, hitInfo, towerMin, towerMax))
    {
        SetFutureFacadeMaterial(hitInfo, cell, towerMin, towerMax, style, true);
    }

    if (totalHeight > 16.0)
    {
        vec3 center = 0.5 * (towerMin + towerMax);
        vec3 size = towerMax - towerMin;

        vec3 roofMin = vec3(
            center.x - size.x * 0.16,
            towerMax.y,
            center.z - size.z * 0.16
        );

        vec3 roofMax = vec3(
            center.x + size.x * 0.16,
            towerMax.y + mix(0.7, 2.2, Hash12(vec2(cell) + 31.1)),
            center.z + size.z * 0.16
        );

        if (TestBoxTrace(rayPos, rayDir, hitInfo, roofMin, roofMax))
        {
            SetHitMaterial(
                hitInfo,
                MAT_GGX,
                vec3(0.22, 0.24, 0.28),
                vec3(0.0),
                0.28,
                0.0,
                1.5
            );
        }
    }

    if (totalHeight > 30.0 && Hash12(vec2(cell) + 77.5) > 0.62)
    {
        vec3 center = 0.5 * (towerMin + towerMax);

        vec3 spireMin = vec3(center.x - 0.08, towerMax.y, center.z - 0.08);
        vec3 spireMax = vec3(center.x + 0.08, towerMax.y + 6.0, center.z + 0.08);

        if (TestBoxTrace(rayPos, rayDir, hitInfo, spireMin, spireMax))
        {
            SetHitMaterial(
                hitInfo,
                MAT_GGX,
                vec3(0.64, 0.66, 0.72),
                vec3(0.0),
                0.14,
                0.15,
                1.5
            );
        }

        vec3 beaconCenter = vec3(center.x, towerMax.y + 6.3, center.z);

        if (TestSphereTrace(rayPos, rayDir, hitInfo, vec4(beaconCenter, 0.16)))
        {
            SetHitMaterial(
                hitInfo,
                MAT_DIFFUSE,
                vec3(0.02),
                FutureAccentColor(Hash12(vec2(cell) + 5.7)) * 5.0,
                0.2,
                0.0,
                1.5
            );
        }
    }

}

// 与地面平面做解析求交，并按 cell role 生成道路、广场或普通地面材质。
void TestCityGround(
    in vec3 rayPos,
    in vec3 rayDir,
    inout SRayHitInfo hitInfo
)
{
    if (abs(rayDir.y) < 1e-6)
        return;

    float t = (CITY_GROUND_Y - rayPos.y) / rayDir.y;

    if (t <= c_minimumRayHitTime || t >= hitInfo.dist)
        return;

    vec3 p = rayPos + rayDir * t;
    ivec2 cell = ivec2(floor(p.xz / CITY_CELL_SIZE));

    // 地面材质和上方 cell role 使用相同规则，避免道路和建筑错位。
    bool mainRoad = IsMainRoadCell(cell);
    bool road = IsRoadCell(cell);
    bool plaza = IsPlazaCell(cell);

    vec3 color = vec3(0.2);
    float roughness = 0.75;
    float metallic = 0.0;
    float ior = 1.5;
    int matType = MAT_GGX;

    if (road)
    {
        float n = FBM(p.xz * 0.38);

        if (mainRoad)
        {
            color = vec3(0.060, 0.066, 0.078) * mix(0.90, 1.25, n);
            roughness = 0.22;
        }
        else
        {
            color = vec3(0.095, 0.100, 0.116) * mix(0.90, 1.20, n);
            roughness = 0.30;
        }

        float lineX = smoothstep(0.045, 0.0, abs(fract(p.x * 0.25) - 0.5));
        float lineZ = smoothstep(0.045, 0.0, abs(fract(p.z * 0.25) - 0.5));
        // 道路线是纯 shading pattern，不增加几何。
        float lane = max(lineX, lineZ);

        color = mix(color, vec3(0.92, 0.85, 0.45), lane * 0.18);
    }
    else if (plaza)
    {
        float tile = FBM(p.xz * 0.55);
        color = vec3(0.28, 0.30, 0.34) * mix(0.90, 1.16, tile);
        roughness = 0.22;
    }
    else
    {
        float n = FBM(p.xz * 0.72);
        color = vec3(0.20, 0.21, 0.23) * mix(0.90, 1.18, n);
        roughness = 0.38;
    }

    hitInfo.dist = t;
    hitInfo.hitPoint = p;
    hitInfo.frontFace = rayDir.y < 0.0;
    hitInfo.normal = hitInfo.frontFace ? vec3(0.0, 1.0, 0.0) : vec3(0.0, -1.0, 0.0);

    SetHitMaterial(
        hitInfo,
        matType,
        color,
        vec3(0.0),
        roughness,
        metallic,
        ior
    );
}

/*
Primary ray 的二维 DDA traversal。

将三维问题投影到城市的 xz 网格：
  cell    : 当前 ray 所在网格。
  stepX/Z : ray 每跨过一条边界后，cell index 增加还是减少。
  tMaxX/Z : 从 ray 起点到“下一条 x/z 网格边界”的参数 t。
  tDelta  : 此后每跨过一个完整 cell，tMax 需要增加多少。

每轮只测试当前 cell。若最近命中发生在下一条 cell 边界之前，
后续 cell 不可能更近，可以安全提前终止。
*/
void TraceProceduralCity(
    in vec3 rayPos,
    in vec3 rayDir,
    inout SRayHitInfo hitInfo
)
{
    TestCityGround(rayPos, rayDir, hitInfo);

    ivec2 cell = ivec2(floor(rayPos.xz / CITY_CELL_SIZE));

    int stepX = rayDir.x >= 0.0 ? 1 : -1;
    int stepZ = rayDir.z >= 0.0 ? 1 : -1;

    // 根据行进方向选择当前 cell 的右/左边界和上/下边界。
    float nextBoundaryX = (rayDir.x >= 0.0 ? float(cell.x + 1) : float(cell.x)) * CITY_CELL_SIZE;
    float nextBoundaryZ = (rayDir.z >= 0.0 ? float(cell.y + 1) : float(cell.y)) * CITY_CELL_SIZE;

    float tMaxX = abs(rayDir.x) < 1e-6 ? 1e20 : (nextBoundaryX - rayPos.x) / rayDir.x;
    float tMaxZ = abs(rayDir.z) < 1e-6 ? 1e20 : (nextBoundaryZ - rayPos.z) / rayDir.z;

    // ray 越接近平行某轴，跨过该轴方向一个 cell 所需的 t 越大。
    float tDeltaX = abs(rayDir.x) < 1e-6 ? 1e20 : abs(CITY_CELL_SIZE / rayDir.x);
    float tDeltaZ = abs(rayDir.z) < 1e-6 ? 1e20 : abs(CITY_CELL_SIZE / rayDir.z);

    for (int i = 0; i < CITY_MAX_CELLS; ++i)
    {
        TraceCityCell(cell, rayPos, rayDir, hitInfo);

        float nextT = min(tMaxX, tMaxZ);

        // 命中在当前 cell 的出口之前，最近结果已经确定。
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
}

// 场景统一入口。保留这一层封装，方便未来加入其他场景类型。
void TestSceneTrace(in vec3 rayPos, in vec3 rayDir, inout SRayHitInfo hitInfo)
{
    TraceProceduralCity(rayPos, rayDir, hitInfo);
}

/*
只判断 AABB 是否在 [minimumHitTime, maxDist) 内遮挡 ray。

与 TestBoxTrace 的区别：
  - 不计算 hitPoint、normal 和材质。
  - 不需要维护最近 SRayHitInfo。
  - 一旦命中即可返回 true。
*/
bool TestBoxOcclusion(
    in vec3 rayPos,
    in vec3 rayDir,
    in float maxDist,
    in vec3 bmin,
    in vec3 bmax
)
{
    if (abs(rayDir.x) < 1e-6 && (rayPos.x < bmin.x || rayPos.x > bmax.x)) return false;
    if (abs(rayDir.y) < 1e-6 && (rayPos.y < bmin.y || rayPos.y > bmax.y)) return false;
    if (abs(rayDir.z) < 1e-6 && (rayPos.z < bmin.z || rayPos.z > bmax.z)) return false;

    vec3 invD = vec3(
        abs(rayDir.x) < 1e-6 ? 1e20 : 1.0 / rayDir.x,
        abs(rayDir.y) < 1e-6 ? 1e20 : 1.0 / rayDir.y,
        abs(rayDir.z) < 1e-6 ? 1e20 : 1.0 / rayDir.z
    );

    vec3 t0 = (bmin - rayPos) * invD;
    vec3 t1 = (bmax - rayPos) * invD;

    vec3 tsmaller = min(t0, t1);
    vec3 tbigger  = max(t0, t1);

    float tNear = max(max(tsmaller.x, tsmaller.y), tsmaller.z);
    float tFar  = min(min(tbigger.x, tbigger.y), tbigger.z);

    if (tNear > tFar)
        return false;

    float t = tNear;
    if (t <= c_minimumRayHitTime)
        t = tFar;

    return t > c_minimumRayHitTime && t < maxDist;
}

// 地面是否在 shadow ray 的有效距离内。朝向地面的光线会被地面挡住。
bool TestCityGroundOcclusion(in vec3 rayPos, in vec3 rayDir, in float maxDist)
{
    if (abs(rayDir.y) < 1e-6)
        return false;

    float t = (CITY_GROUND_Y - rayPos.y) / rayDir.y;
    return t > c_minimumRayHitTime && t < maxDist;
}

// 广场的遮挡简化版，只测试基座和 monolith。
bool TracePlazaCellOcclusion(
    in ivec2 cell,
    in vec3 rayPos,
    in vec3 rayDir,
    in float maxDist
)
{
    vec2 center2 = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;

    vec3 baseMin = vec3(center2.x - 1.45, CITY_GROUND_Y,        center2.y - 1.45);
    vec3 baseMax = vec3(center2.x + 1.45, CITY_GROUND_Y + 0.35, center2.y + 1.45);
    if (TestBoxOcclusion(rayPos, rayDir, maxDist, baseMin, baseMax))
        return true;

    if (Hash12(vec2(cell) + 8.8) > 0.28)
    {
        vec3 monoMin = vec3(center2.x - 0.22, CITY_GROUND_Y + 0.35, center2.y - 0.22);
        vec3 monoMax = vec3(center2.x + 0.22, CITY_GROUND_Y + 3.80, center2.y + 0.22);
        if (TestBoxOcclusion(rayPos, rayDir, maxDist, monoMin, monoMax))
            return true;
    }

    return false;
}

// 道路基础设施的遮挡简化版，只测试主路高架梁柱。
bool TraceRoadInfrastructureCellOcclusion(
    in ivec2 cell,
    in vec3 rayPos,
    in vec3 rayDir,
    in float maxDist
)
{
    if (!IsMainRoadCell(cell))
        return false;

    vec2 cellBase = vec2(cell) * CITY_CELL_SIZE;
    vec2 center = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;

    bool horizontalLine = abs(mod(float(cell.y), 8.0)) < 1.0;
    bool verticalLine   = abs(mod(float(cell.x), 8.0)) < 1.0;

    float railY0 = CITY_GROUND_Y + 4.0;
    float railY1 = CITY_GROUND_Y + 4.45;

    if (horizontalLine)
    {
        vec3 beamMin = vec3(cellBase.x, railY0, center.y - 0.24);
        vec3 beamMax = vec3(cellBase.x + CITY_CELL_SIZE, railY1, center.y + 0.24);
        if (TestBoxOcclusion(rayPos, rayDir, maxDist, beamMin, beamMax))
            return true;

        vec3 colMin = vec3(center.x - 0.14, CITY_GROUND_Y, center.y - 0.14);
        vec3 colMax = vec3(center.x + 0.14, railY0,        center.y + 0.14);
        if (TestBoxOcclusion(rayPos, rayDir, maxDist, colMin, colMax))
            return true;
    }

    if (verticalLine)
    {
        vec3 beamMin = vec3(center.x - 0.24, railY0, cellBase.y);
        vec3 beamMax = vec3(center.x + 0.24, railY1, cellBase.y + CITY_CELL_SIZE);
        if (TestBoxOcclusion(rayPos, rayDir, maxDist, beamMin, beamMax))
            return true;

        vec3 colMin = vec3(center.x - 0.14, CITY_GROUND_Y, center.y - 0.14);
        vec3 colMax = vec3(center.x + 0.14, railY0,        center.y + 0.14);
        if (TestBoxOcclusion(rayPos, rayDir, maxDist, colMin, colMax))
            return true;
    }

    return false;
}

// Shadow cell 分发。普通建筑只测试 GetFutureBuildingShadowBounds 的单一 proxy。
bool TraceCityCellOcclusion(
    in ivec2 cell,
    in vec3 rayPos,
    in vec3 rayDir,
    in float maxDist
)
{
    if (IsRoadCell(cell))
        return TraceRoadInfrastructureCellOcclusion(cell, rayPos, rayDir, maxDist);

    if (IsPlazaCell(cell))
        return TracePlazaCellOcclusion(cell, rayPos, rayDir, maxDist);

    vec3 shadowMin, shadowMax;
    GetFutureBuildingShadowBounds(cell, shadowMin, shadowMax);

    return TestBoxOcclusion(rayPos, rayDir, maxDist, shadowMin, shadowMax);
}

/*
Shadow ray 的短程 DDA。

它复用了 primary DDA 的网格步进方式，但：
  - 最大 cell 数从 56 降到 28。
  - 最大距离从 190 降到 110。
  - 普通建筑只做一个 proxy box test。
  - 任意遮挡都立刻返回 true。

这是“按 ray 类型分配精度”的核心优化。
*/
bool TraceProceduralCityOcclusion(in vec3 rayPos, in vec3 rayDir, in float maxDist)
{
    // 调用者可能给出更远距离，但城市太阳阴影只检查固定范围。
    float shadowMaxDist = min(maxDist, CITY_MAX_SHADOW_TRACE_DIST);

    if (TestCityGroundOcclusion(rayPos, rayDir, shadowMaxDist))
        return true;

    ivec2 cell = ivec2(floor(rayPos.xz / CITY_CELL_SIZE));

    int stepX = rayDir.x >= 0.0 ? 1 : -1;
    int stepZ = rayDir.z >= 0.0 ? 1 : -1;

    float nextBoundaryX = (rayDir.x >= 0.0 ? float(cell.x + 1) : float(cell.x)) * CITY_CELL_SIZE;
    float nextBoundaryZ = (rayDir.z >= 0.0 ? float(cell.y + 1) : float(cell.y)) * CITY_CELL_SIZE;

    float tMaxX = abs(rayDir.x) < 1e-6 ? 1e20 : (nextBoundaryX - rayPos.x) / rayDir.x;
    float tMaxZ = abs(rayDir.z) < 1e-6 ? 1e20 : (nextBoundaryZ - rayPos.z) / rayDir.z;

    float tDeltaX = abs(rayDir.x) < 1e-6 ? 1e20 : abs(CITY_CELL_SIZE / rayDir.x);
    float tDeltaZ = abs(rayDir.z) < 1e-6 ? 1e20 : abs(CITY_CELL_SIZE / rayDir.z);

    for (int i = 0; i < CITY_MAX_SHADOW_CELLS; ++i)
    {
        if (TraceCityCellOcclusion(cell, rayPos, rayDir, shadowMaxDist))
            return true;

        float nextT = min(tMaxX, tMaxZ);
        if (nextT > shadowMaxDist || nextT > CITY_MAX_SHADOW_TRACE_DIST)
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

    return false;
}

// ============================================================
// RNG
//
// 随机状态由 pixel、frame 和 sample index 初始化。
// 所有 BSDF/jitter sample 都显式传递并更新同一个 uint state。
// ============================================================

// Wang hash：原地推进 seed，并返回 32-bit 伪随机整数。
uint wang_hash(inout uint seed)
{
    seed = uint(seed ^ uint(61)) ^ uint(seed >> uint(16));
    seed *= uint(9);
    seed = seed ^ (seed >> 4);
    seed *= uint(0x27d4eb2d);
    seed = seed ^ (seed >> 15);
    return seed;
}

// 将 uint 映射到 [0,1)。除以 2^32 而不是 UINT_MAX，避免返回 1。
float RandomFloat01(inout uint state)
{
    return float(wang_hash(state)) / 4294967296.0;
}

// 两次独立 RNG 调用，用于像素 jitter 或二维采样参数。
vec2 RandomInUnitSquare(inout uint state)
{
    return vec2(RandomFloat01(state), RandomFloat01(state));
}

// ============================================================
// Sky / Light
// ============================================================

// 太阳的唯一方向来源。天空太阳盘、direct sun 和玻璃 sun glint 都调用它，
// 保证视觉太阳与真正的照明方向一致。
vec3 GetSunDirection()
{
    return normalize(vec3(-0.32, 0.62, 0.42));
}

/*
解析天空：
  - 根据 rayDir.y 混合 horizon 与 zenith。
  - 高次幂 sun lobe 形成太阳盘。
  - 低次幂 sun lobe 形成暖色光晕。
  - horizon haze 加强接近地平线的空气散射感。
*/
vec3 GetSkyColor(vec3 rayDir)
{
    float t = clamp(rayDir.y * 0.5 + 0.5, 0.0, 1.0);

    vec3 horizon = vec3(0.68, 0.78, 0.94);
    vec3 zenith  = vec3(0.18, 0.32, 0.58);

    vec3 sky = mix(horizon, zenith, pow(t, 0.72));

    vec3 sunDir = GetSunDirection();
    float sun = max(dot(rayDir, sunDir), 0.0);

    sky += vec3(1.00, 0.78, 0.48) * pow(sun, 160.0) * 14.0;
    sky += vec3(0.95, 0.58, 0.28) * pow(sun, 10.0) * 0.75;

    float haze = pow(max(0.0, 1.0 - abs(rayDir.y)), 2.5);
    sky += vec3(0.30, 0.40, 0.55) * haze * 0.55;

    return sky * 1.15;
}

// 太阳可见性。true 表示到给定方向和距离没有城市遮挡。
bool IsVisibleToLight(in vec3 rayPos, in vec3 rayDir, in float maxDist)
{
    return !TraceProceduralCityOcclusion(rayPos, rayDir, maxDist);
}

// ============================================================
// Sampling / BRDF / BSDF
//
// BRDF：给定 wo 和 wi，回答该方向组合反射多少 radiance。
// BSDF sampling：随机选择下一条 wi，并返回 throughput 应乘的权重。
//
// Monte Carlo 路径权重的基本形式：
//     weight = BRDF(wo, wi) * max(dot(N, wi), 0) / PDF(wi)
// ============================================================

// 根据法线 N 构造正交基 (tangent, bitangent, normal)。
// 选择不接近 N 的辅助轴，可避免 cross 接近零向量。
void MakeONB(in vec3 n, out vec3 t, out vec3 b)
{
    vec3 up = abs(n.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}

// 将以 N 为局部 z 轴的方向转换到世界空间。
vec3 ToWorld(in vec3 localDir, in vec3 n)
{
    vec3 t, b;
    MakeONB(n, t, b);
    return normalize(t * localDir.x + b * localDir.y + n * localDir.z);
}

/*
Cosine-weighted hemisphere sampling。

它让靠近法线的方向被更频繁采样，恰好匹配 Lambert BRDF 的 cos(theta) 项，
因此 diffuse 路径的方差远低于均匀半球采样。
*/
vec3 SampleCosineHemisphere(in vec3 n, inout uint rngState)
{
    float u1 = RandomFloat01(rngState);
    float u2 = RandomFloat01(rngState);

    // 将均匀二维随机数映射到单位圆盘，再抬到半球。
    float r = sqrt(u1);
    float phi = 2.0 * c_PI_NEE * u2;

    vec3 localDir = vec3(
        r * cos(phi),
        r * sin(phi),
        sqrt(max(0.0, 1.0 - u1))
    );

    return ToWorld(localDir, n);
}

// Cosine hemisphere 对应 PDF。背面方向概率为 0。
float CosineHemispherePdf(in vec3 n, in vec3 wi)
{
    return max(dot(n, wi), 0.0) / c_PI_NEE;
}

/*
Schlick Fresnel：
  cosTheta 越小（越接近掠射），反射率越接近 1。
  F0 是垂直入射反射率：非金属约 0.04，金属使用有色 albedo。
*/
vec3 FresnelSchlick(in float cosTheta, in vec3 F0)
{
    float f = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    return F0 + (1.0 - F0) * f;
}

// 标量版本，thin glass 只需要一个无色 Fresnel 系数。
float FresnelSchlickScalar(in float cosTheta, in float F0)
{
    float f = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    return F0 + (1.0 - F0) * f;
}

// 前向声明：thin glass shading 在实现位置之前需要调用城市反射场。
vec3 EstimateCitySpecularField(in SRayHitInfo hitInfo, in vec3 viewDir, in vec3 reflectionDir);

/*
风格化 thin glass。

这里没有真正穿过建筑内部做折射，因为建筑只是封闭 box，内部也没有房间几何。
因此把窗户视为薄反射层：
  baseTint       : 玻璃本身的透色感。
  skyReflection  : 天空环境。
  cityReflection : 程序化城市低频反射。
  sunReflection  : 很尖锐的太阳 glint。
  emissive       : 窗内灯光。
*/
vec3 ShadeThinGlass(
    in SRayHitInfo hitInfo,
    in vec3 rayDir
)
{
    vec3 N = hitInfo.normal;
    vec3 V = normalize(-rayDir);

    float NoV = max(dot(N, V), 0.0);
    float fresnel = FresnelSchlickScalar(NoV, 0.04);

    // rayDir 指向表面，因此 reflect(rayDir, N) 得到离开表面的反射方向。
    vec3 R = normalize(reflect(rayDir, N));

    vec3 skyReflection = GetSkyColor(R);
    vec3 cityReflection = EstimateCitySpecularField(hitInfo, V, R);

    float skyFacing = smoothstep(-0.15, 0.75, R.y);

    vec3 baseTint =
        hitInfo.albedo *
        mix(0.08, 0.22, skyFacing);

    vec3 reflected =
        skyReflection * mix(0.22, 0.95, fresnel) +
        cityReflection * mix(0.75, 1.65, fresnel);

    float sunGlint = pow(
        max(dot(R, GetSunDirection()), 0.0),
        180.0
    );

    vec3 sunReflection =
        vec3(1.00, 0.78, 0.48) *
        sunGlint *
        5.0;

    vec3 col =
        baseTint +
        reflected +
        sunReflection +
        hitInfo.emissive;

    return col;
}

/*
GGX / Trowbridge-Reitz 法线分布 D。

roughness 先平方得到 alpha，再平方得到 alpha^2。
roughness 越小，微表面法线越集中，高光越尖。
*/
float DistributionGGX(in vec3 N, in vec3 H, in float roughness)
{
    float a = max(roughness, 0.02);
    a = a * a;
    float a2 = a * a;

    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;

    float denom = NdotH2 * (a2 - 1.0) + 1.0;
    return a2 / max(c_PI_NEE * denom * denom, 1e-6);
}

// Schlick-GGX 的单方向 masking/shadowing 近似。
float GeometrySchlickGGX(in float NdotV, in float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / max(NdotV * (1.0 - k) + k, 1e-6);
}

// Smith geometry term = view masking * light masking。
float GeometrySmith(in vec3 N, in vec3 V, in vec3 L, in float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

/*
评估当前材质的 BRDF，不包含外部的 cos(theta)。

MAT_DIFFUSE：
    f = albedo / PI

MAT_GGX：
    specular = D * G * F / (4 NoV NoL)
    diffuse  = (1-F) * (1-metallic) * albedo / PI

金属没有 diffuse 项，能量主要进入有色 specular。
*/
vec3 EvalBRDF(in SRayHitInfo hitInfo, in vec3 wo, in vec3 wi)
{
    vec3 N = hitInfo.normal;

    float NdotL = max(dot(N, wi), 0.0);
    float NdotV = max(dot(N, wo), 0.0);

    if (NdotL <= 0.0 || NdotV <= 0.0)
        return vec3(0.0);

    if (hitInfo.materialType == MAT_DIFFUSE)
    {
        return hitInfo.albedo / c_PI_NEE;
    }

    if (hitInfo.materialType == MAT_GGX)
    {
        vec3 H = normalize(wi + wo);
        float VdotH = max(dot(wo, H), 0.0);

        // metallic=0 使用无色介质 F0；metallic=1 使用有色金属反射率。
        vec3 F0 = mix(vec3(0.04), hitInfo.albedo, hitInfo.metallic);
        vec3 F = FresnelSchlick(VdotH, F0);

        float D = DistributionGGX(N, H, hitInfo.roughness);
        float G = GeometrySmith(N, wo, wi, hitInfo.roughness);

        vec3 specular = D * G * F / max(4.0 * NdotV * NdotL, 1e-6);

        // Fresnel 已反射出去的能量不能再进入 diffuse；金属也不产生 diffuse。
        vec3 kD = (vec3(1.0) - F) * (1.0 - hitInfo.metallic);
        vec3 diffuse = kD * hitInfo.albedo / c_PI_NEE;

        return diffuse + specular;
    }

    return vec3(0.0);
}

// 将采样 half vector H 的 PDF 转换为反射方向 wi 的 PDF。
// Jacobian 为 1 / (4 * dot(wo,H))。
float GGXPdf(in SRayHitInfo hitInfo, in vec3 wo, in vec3 wi)
{
    vec3 N = hitInfo.normal;

    if (dot(N, wi) <= 0.0 || dot(N, wo) <= 0.0)
        return 0.0;

    vec3 H = normalize(wo + wi);
    float NdotH = max(dot(N, H), 0.0);
    float VdotH = max(dot(wo, H), 1e-6);
    float D = DistributionGGX(N, H, hitInfo.roughness);

    return D * NdotH / max(4.0 * VdotH, 1e-6);
}

/*
从 GGX NDF 采样微表面 half vector H，再把入射方向 -wo 关于 H 反射。

这是 NDF sampling，不是更高级的 visible-normal sampling；实现更短，
在当前低 bounce、低 spp 场景中足够使用。
*/
vec3 SampleGGXDirection(in SRayHitInfo hitInfo, in vec3 wo, inout uint rngState)
{
    float u1 = RandomFloat01(rngState);
    float u2 = RandomFloat01(rngState);

    float rough = max(hitInfo.roughness, 0.02);
    float a = rough * rough;
    float a2 = a * a;

    float phi = 2.0 * c_PI_NEE * u1;
    float cosTheta = sqrt((1.0 - u2) / max(1.0 + (a2 - 1.0) * u2, 1e-6));
    float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));

    vec3 Hlocal = vec3(
        sinTheta * cos(phi),
        sinTheta * sin(phi),
        cosTheta
    );

    vec3 H = ToWorld(Hlocal, hitInfo.normal);

    if (dot(H, wo) < 0.0)
        H = -H;

    return normalize(reflect(-wo, H));
}

/*
为路径选择下一方向，并计算无偏 Monte Carlo 权重（clamp 除外）。

输出：
  wi      : 下一条世界空间 ray direction。
  weight  : throughput 要乘的 BRDF*cos/PDF。
  isDelta : 当前版本没有实际 delta 材质分支，保留字段便于 emissive 规则扩展。

GGX 使用 diffuse/specular mixture sampling：
  pDiffuse 由 metallic 决定；
  最终 PDF 必须同时包含两个 proposal 的概率加权和。
*/
bool SampleBSDF(
    in SRayHitInfo hitInfo,
    in vec3 wo,
    inout uint rngState,
    out vec3 wi,
    out vec3 weight,
    out bool isDelta
)
{
    isDelta = false;
    weight = vec3(0.0);

    if (hitInfo.materialType == MAT_DIFFUSE)
    {
        wi = SampleCosineHemisphere(hitInfo.normal, rngState);

        float pdf = CosineHemispherePdf(hitInfo.normal, wi);
        if (pdf <= 1e-6)
            return false;

        vec3 brdf = EvalBRDF(hitInfo, wo, wi);
        float cosTheta = max(dot(hitInfo.normal, wi), 0.0);

        weight = brdf * cosTheta / pdf;
        return true;
    }

    if (hitInfo.materialType == MAT_GGX)
    {
        // 非金属给 diffuse 一半采样预算；金属逐渐转向纯 specular。
        float pDiffuse = (1.0 - hitInfo.metallic) * 0.5;
        float pSpecular = 1.0 - pDiffuse;

        if (RandomFloat01(rngState) < pDiffuse)
            wi = SampleCosineHemisphere(hitInfo.normal, rngState);
        else
            wi = SampleGGXDirection(hitInfo, wo, rngState);

        float cosTheta = max(dot(hitInfo.normal, wi), 0.0);
        if (cosTheta <= 0.0)
            return false;

        float pdfDiffuse = CosineHemispherePdf(hitInfo.normal, wi);
        float pdfSpecular = GGXPdf(hitInfo, wo, wi);

        // 即使本次从某一个 proposal 采样，也必须使用完整 mixture PDF。
        float pdf = pDiffuse * pdfDiffuse + pSpecular * pdfSpecular;
        if (pdf <= 1e-6)
            return false;

        vec3 brdf = EvalBRDF(hitInfo, wo, wi);
        weight = brdf * cosTheta / pdf;
        return true;
    }

    return false;
}

/*
估计 hit 附近的“城市开阔度”。

检查 3x3 cell，road/plaza 视为可见天空和地面反弹的开放区域。
中心 cell 权重略高，结果归一化到约 [0,1]。

它替代了多条随机 sky visibility ray，是稳定但低频的几何先验。
*/
float EstimateRoadOpenness(in ivec2 baseCell)
{
    float openness = 0.0;
    float weightSum = 0.0;

    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            ivec2 cell = baseCell + ivec2(x, y);
            float w = (x == 0 && y == 0) ? 1.5 : 1.0;
            openness += (IsRoadCell(cell) || IsPlazaCell(cell)) ? w : 0.0;
            weightSum += w;
        }
    }

    return openness / max(weightSum, 1e-4);
}

/*
估计街谷尺度的建筑遮蔽。

对附近 3x3 非道路 cell：
  - 使用便宜 shadow proxy。
  - 建筑顶比当前点高得越多，遮蔽越强。
  - 水平距离越远，权重越低。

这不是严格 AO 积分，而是为 sky GI / multi-bounce 提供低频 canyon occlusion。
*/
float EstimateBuildingOcclusion(in vec3 p, in ivec2 baseCell)
{
    float occlusion = 0.0;

    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            ivec2 cell = baseCell + ivec2(x, y);
            if (IsRoadCell(cell) || IsPlazaCell(cell))
                continue;

            vec3 shadowMin, shadowMax;
            GetFutureBuildingShadowBounds(cell, shadowMin, shadowMax);

            vec2 center = 0.5 * (shadowMin.xz + shadowMax.xz);
            vec2 toCell = center - p.xz;
            float dist2 = dot(toCell, toCell);
            float tallerThanPoint = smoothstep(p.y + 2.0, p.y + 30.0, shadowMax.y);
            // 有理函数衰减比 exp 更便宜，也不会在近距离产生奇异值。
            float nearWeight = 1.0 / (1.0 + 0.055 * dist2);

            occlusion += tallerThanPoint * nearWeight;
        }
    }

    return clamp(occlusion * 0.28, 0.0, 0.78);
}

/*
只根据 cell 和 style 估计该建筑“平均立面颜色”。

GI 查询不会重新执行完整的逐像素 SetFutureFacadeMaterial；
这里用同一组 hash 近似砖、木、金属和玻璃的低频混合色。
这样 facade bounce 与真正看见的建筑风格相关，但成本显著更低。
*/
vec3 EstimateCellFacadeColor(in ivec2 cell, in int style)
{
    float seed = Hash12(vec2(cell) + float(style) * 19.7);
    vec2 cellCenter = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;
    float spineMask = CitySpineMask(cellCenter);
    float landmarkMask = CityLandmarkMask(cellCenter);

    vec3 brickA;
    vec3 brickB;

    if (style == 0)
    {
        brickA = vec3(0.42, 0.20, 0.12);
        brickB = vec3(0.64, 0.30, 0.18);
    }
    else if (style == 1)
    {
        brickA = vec3(0.30, 0.29, 0.27);
        brickB = vec3(0.52, 0.48, 0.42);
    }
    else if (style == 2)
    {
        brickA = vec3(0.38, 0.25, 0.17);
        brickB = vec3(0.66, 0.42, 0.26);
    }
    else if (style == 3)
    {
        brickA = vec3(0.30, 0.23, 0.18);
        brickB = vec3(0.54, 0.38, 0.25);
    }
    else
    {
        brickA = vec3(0.20, 0.23, 0.27);
        brickB = vec3(0.42, 0.45, 0.48);
    }

    vec3 baseColor = mix(brickA, brickB, seed);
    vec3 metalTint = mix(vec3(0.20, 0.22, 0.24), vec3(0.56, 0.55, 0.50), Hash12(vec2(cell) + 203.3));
    vec3 glassTint = mix(vec3(0.08, 0.16, 0.24), vec3(0.20, 0.38, 0.58), Hash12(vec2(cell) + 88.8));
    vec3 woodTint = mix(vec3(0.34, 0.20, 0.12), vec3(0.60, 0.40, 0.22), Hash12(vec2(cell) + 144.6));

    float glassMask = smoothstep(0.42, 0.90, Hash12(vec2(cell) + float(style) * 31.7));
    float metalMask = smoothstep(0.18, 0.75, Hash12(vec2(cell) + 55.2));
    float woodMask = smoothstep(0.20, 0.78, Hash12(vec2(cell) + 144.6)) * ((style == 2 || style == 3) ? 0.55 : 0.20);
    glassMask = clamp(glassMask + 0.32 * spineMask + 0.36 * landmarkMask, 0.0, 1.0);
    metalMask = clamp(metalMask + 0.16 * spineMask + 0.12 * landmarkMask, 0.0, 1.0);

    baseColor = mix(baseColor, woodTint, woodMask);
    baseColor = mix(baseColor, metalTint, metalMask * 0.35);
    baseColor = mix(baseColor, glassTint, glassMask * 0.45);

    return baseColor;
}

/*
估计整个 cell 的平均发光颜色。

不是逐个窗口积分，而是把 window density、neon probability、tower height
和 signature district 压缩成一个低频 RGB radiance proxy。
*/
vec3 EstimateCellEmissionColor(in ivec2 cell, in float totalHeight)
{
    float towerWeight = smoothstep(12.0, 70.0, totalHeight);
    vec2 cellCenter = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;
    float spineMask = CitySpineMask(cellCenter);
    float landmarkMask = CityLandmarkMask(cellCenter);
    float signatureMask = clamp(max(spineMask * 0.78, landmarkMask) + towerWeight * 0.18, 0.0, 1.0);

    vec3 windowColor = mix(
        vec3(1.00, 0.58, 0.20),
        vec3(0.35, 0.70, 1.00),
        Hash12(vec2(cell) + 6.1)
    );

    float windowDensity = mix(0.10, 0.28, Hash12(vec2(cell) + 31.37)) * (1.0 + 1.05 * signatureMask);
    float neonMask = smoothstep(mix(0.62, 0.42, signatureMask), 1.0, Hash12(vec2(cell) + 23.4));
    vec3 neonColor = FutureAccentColor(Hash12(vec2(cell) + 91.2));

    return windowColor * windowDensity * (0.12 + 0.24 * towerWeight + 0.08 * signatureMask) +
           neonColor * neonMask * (0.20 + 0.24 * towerWeight + 0.18 * signatureMask);
}

/*
局部 GI AO 修正。

低处、面向侧面的墙、附近有高楼且道路不开放时更暗；
朝上的屋顶略微恢复亮度。输出下限 0.54，避免深街谷完全死黑。
*/
float EstimateLocalGIAO(
    in vec3 n,
    in float heightAboveGround,
    in float roadOpenness,
    in float buildingOcclusion
)
{
    float wallMask = 1.0 - smoothstep(0.25, 0.85, abs(n.y));
    float roofMask = smoothstep(0.55, 0.95, n.y);
    float lowCanyonMask = 1.0 - smoothstep(2.0, 18.0, heightAboveGround);
    float cornerMask = wallMask * buildingOcclusion * (1.0 - 0.55 * roadOpenness);

    float ao = 1.0 - 0.30 * cornerMask - 0.18 * lowCanyonMask * (1.0 - roadOpenness);
    ao += 0.10 * roofMask;

    return clamp(ao, 0.54, 1.05);
}

/*
邻近立面到当前表面的低频 diffuse bounce。

遍历附近 3x3 cell（跳过当前 cell）：
  road/plaza -> 贡献天空/阳光/城市强调色混合后的地面反弹。
  building   -> 贡献平均 facade color 和平均 emission color。

facing         : 当前法线是否朝向邻居。
atten          : 水平距离衰减。
heightReach    : 对方建筑是否足够高，能与当前 hit 高度产生耦合。
canyonCoupling : 街谷中的立面互相“看见”的近似。
*/
vec3 EstimateFacadeBounceField(
    in SRayHitInfo hitInfo,
    in ivec2 baseCell,
    in float buildingOcclusion,
    in float roadOpenness
)
{
    vec3 p = hitInfo.hitPoint;
    vec3 n = hitInfo.normal;
    float wallMask = 1.0 - smoothstep(0.25, 0.85, abs(n.y));
    float roofMask = smoothstep(0.55, 0.95, n.y);
    float heightAboveGround = max(p.y - CITY_GROUND_Y, 0.0);
    float lowReceiver = 1.0 - smoothstep(7.0, 42.0, heightAboveGround);

    vec3 bounce = vec3(0.0);

    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            if (x == 0 && y == 0)
                continue;

            ivec2 cell = baseCell + ivec2(x, y);
            vec2 cellCenter = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;
            vec2 toCell2 = cellCenter - p.xz;
            float dist2 = dot(toCell2, toCell2);
            // 只考虑水平方向关系，因为这是城市立面之间的低频耦合。
            vec3 toCell = normalize(vec3(toCell2.x, 0.0, toCell2.y) + vec3(1e-4, 0.0, 0.0));
            // 墙面强依赖朝向；屋顶保留较弱、近似各向同性的接收。
            float facing = mix(0.22 + 0.12 * roofMask, max(dot(n, toCell), 0.0), wallMask);
            float atten = 1.0 / (1.0 + 0.075 * dist2);

            if (IsRoadCell(cell) || IsPlazaCell(cell))
            {
                float mainRoad = IsMainRoadCell(cell) ? 1.0 : 0.55;
                vec3 asphaltBounce = mix(vec3(0.12, 0.18, 0.26), vec3(0.95, 0.54, 0.22), max(GetSunDirection().y, 0.0));
                vec3 roadTint = mix(asphaltBounce, FutureAccentColor(Hash12(vec2(cell) + 42.7)), IsPlazaCell(cell) ? 0.22 : 0.08);

                bounce += roadTint * facing * atten * lowReceiver * mainRoad * (0.055 + 0.055 * roadOpenness);
                continue;
            }

            vec3 shadowMin, shadowMax;
            GetFutureBuildingShadowBounds(cell, shadowMin, shadowMax);

            int style = int(floor(Hash12(vec2(cell) + 99.0) * 5.0));
            float totalHeight = shadowMax.y - CITY_GROUND_Y;
            float heightReach = smoothstep(p.y - 10.0, p.y + 32.0, shadowMax.y);
            float towerWeight = smoothstep(12.0, 70.0, totalHeight);
            vec3 facadeColor = EstimateCellFacadeColor(cell, style);
            vec3 emissionColor = EstimateCellEmissionColor(cell, totalHeight);

            float canyonCoupling = wallMask * facing * heightReach * atten * (0.45 + 0.55 * towerWeight);
            float diffuseBounce = 0.055 + 0.105 * buildingOcclusion;
            float emissiveBounce = 0.20 + 0.22 * (1.0 - roadOpenness);

            bounce += facadeColor * canyonCoupling * diffuseBounce;
            bounce += emissionColor * canyonCoupling * emissiveBounce;
        }
    }

    return bounce;
}

/*
附近窗户、霓虹、道路和广场形成的 emissive irradiance field。

与真实 emissive path hit 的区别：
  - 真实路径需要随机 ray 恰好命中很小的发光表面。
  - 这里直接根据 cell 的发光统计估计低频贡献，因此没有时间噪声。

它是有偏估计，但解决了低 spp 下小光源几乎永远采不到的问题。
*/
vec3 EstimateNearbyEmissionField(in SRayHitInfo hitInfo, in ivec2 baseCell)
{
    vec3 p = hitInfo.hitPoint;
    vec3 n = hitInfo.normal;
    float wallMask = 1.0 - smoothstep(0.25, 0.85, abs(n.y));
    float roofMask = smoothstep(0.55, 0.95, n.y);

    vec3 glow = vec3(0.0);

    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            ivec2 cell = baseCell + ivec2(x, y);
            vec2 cellCenter = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;
            vec2 toCell2 = cellCenter - p.xz;
            float dist2 = dot(toCell2, toCell2);
            float atten = 1.0 / (1.0 + 0.030 * dist2);

            vec3 toCell = normalize(vec3(toCell2.x, 0.0, toCell2.y) + vec3(1e-4, 0.0, 0.0));
            float facing = mix(0.35 + 0.15 * roofMask, max(dot(n, toCell), 0.0), wallMask);

            if (IsRoadCell(cell))
            {
                float mainRoad = IsMainRoadCell(cell) ? 1.0 : 0.45;
                vec3 roadGlow = mix(vec3(0.20, 0.55, 1.00), vec3(1.00, 0.25, 0.78), Hash12(vec2(cell) + 42.7));
                glow += roadGlow * atten * facing * mainRoad * 0.070;
                continue;
            }

            if (IsPlazaCell(cell))
            {
                vec3 plazaGlow = FutureAccentColor(Hash12(vec2(cell) + 77.0));
                glow += plazaGlow * atten * facing * 0.14;
                continue;
            }

            vec3 shadowMin, shadowMax;
            GetFutureBuildingShadowBounds(cell, shadowMin, shadowMax);

            float totalHeight = shadowMax.y - CITY_GROUND_Y;
            float heightReach = smoothstep(p.y - 8.0, p.y + 38.0, shadowMax.y);
            float towerWeight = smoothstep(12.0, 70.0, totalHeight);

            vec3 windowColor = mix(
                vec3(1.00, 0.58, 0.20),
                vec3(0.35, 0.70, 1.00),
                Hash12(vec2(cell) + 6.1)
            );

            float windowDensity = mix(0.10, 0.28, Hash12(vec2(cell) + 31.37));
            float neonMask = smoothstep(0.62, 1.0, Hash12(vec2(cell) + 23.4));
            vec3 neonColor = FutureAccentColor(Hash12(vec2(cell) + 91.2));

            glow += windowColor * atten * facing * heightReach * (0.16 + 0.28 * towerWeight) * windowDensity;
            glow += neonColor * atten * facing * heightReach * neonMask * (0.28 + 0.28 * towerWeight);
        }
    }

    return glow;
}

/*
确定性的城市 specular/reflection field。

输入 reflectionDir，不发射真实 glossy ray，而是在附近 3x3 cell 中构造
可能被该方向“看见”的低频 radiance proxy：
  - 道路灯带
  - 广场装置
  - 窗户群
  - 霓虹立面
  - 远处城市 horizon

roughness 控制方向 lobe：
  光滑表面 -> lobePower 大，只接收与 R 高度对齐的候选。
  粗糙表面 -> lobePower 小，反射更宽、更模糊。

这不会反射出精确建筑轮廓，但会让金属/玻璃反射“城市语义”，
而不是只有单调天空或随机噪声。
*/
vec3 EstimateCitySpecularField(in SRayHitInfo hitInfo, in vec3 viewDir, in vec3 reflectionDir)
{
    vec3 p = hitInfo.hitPoint;
    vec3 n = hitInfo.normal;
    vec3 R = normalize(reflectionDir);
    float roughness = clamp(hitInfo.roughness, 0.02, 0.95);
    ivec2 baseCell = ivec2(floor(p.xz / CITY_CELL_SIZE));

    float lobePower = mix(46.0, 5.0, roughness);
    float broadPower = max(2.0, lobePower * 0.28);
    float roughBoost = mix(0.72, 1.35, roughness);

    vec3 field = vec3(0.0);

    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            ivec2 cell = baseCell + ivec2(x, y);
            vec2 cellCenter = (vec2(cell) + vec2(0.5)) * CITY_CELL_SIZE;
            vec2 toCell2 = cellCenter - p.xz;
            float dist2 = dot(toCell2, toCell2);
            float atten = 1.0 / (1.0 + 0.018 * dist2);

            // 道路候选放在接近地面的高度，主要出现在向下的反射方向中。
            if (IsRoadCell(cell))
            {
                vec3 lightPos = vec3(cellCenter.x, CITY_GROUND_Y + 0.08, cellCenter.y);
                vec3 L = normalize(lightPos - p);
                float align = pow(max(dot(R, L), 0.0), broadPower);
                float downward = smoothstep(0.32, -0.22, R.y);
                float mainRoad = IsMainRoadCell(cell) ? 1.0 : 0.45;
                vec3 roadGlow = mix(vec3(0.16, 0.46, 1.00), vec3(1.00, 0.18, 0.76), Hash12(vec2(cell) + 42.7));

                field += roadGlow * align * atten * downward * mainRoad * 0.95 * roughBoost;
                continue;
            }

            if (IsPlazaCell(cell))
            {
                vec3 lightPos = vec3(cellCenter.x, CITY_GROUND_Y + 2.0, cellCenter.y);
                vec3 L = normalize(lightPos - p);
                float align = pow(max(dot(R, L), 0.0), broadPower);
                vec3 plazaGlow = FutureAccentColor(Hash12(vec2(cell) + 77.0));

                field += plazaGlow * align * atten * 0.80 * roughBoost;
                continue;
            }

            vec3 shadowMin, shadowMax;
            GetFutureBuildingShadowBounds(cell, shadowMin, shadowMax);

            float totalHeight = shadowMax.y - CITY_GROUND_Y;
            float towerWeight = smoothstep(10.0, 70.0, totalHeight);
            // 用反射方向和稳定 hash 在建筑竖直范围内选一个代表性高度，
            // 避免所有建筑光源都集中在 cell center 的地面位置。
            float sampleY = clamp(
                p.y + R.y * 18.0 + mix(3.0, 20.0, Hash12(vec2(cell) + 8.1)),
                CITY_GROUND_Y + 1.5,
                max(shadowMax.y - 0.5, CITY_GROUND_Y + 2.0)
            );

            float heightReach = smoothstep(p.y - 16.0, p.y + 48.0, shadowMax.y);
            vec3 lightPos = vec3(cellCenter.x, sampleY, cellCenter.y);
            vec3 L = normalize(lightPos - p);

            // sharp lobe 用于清晰高光，wide lobe 在 rough surface 上补充模糊反射。
            float sharpAlign = pow(max(dot(R, L), 0.0), lobePower);
            float wideAlign = pow(max(dot(R, L), 0.0), broadPower) * roughness;
            float align = sharpAlign + wideAlign * 0.45;
            float sameHemisphere = smoothstep(-0.10, 0.35, dot(n, L));

            vec3 windowColor = mix(
                vec3(1.00, 0.54, 0.18),
                vec3(0.26, 0.66, 1.00),
                Hash12(vec2(cell) + 6.1)
            );

            float windowDensity = mix(0.20, 0.72, Hash12(vec2(cell) + 31.37));
            float neonMask = smoothstep(0.55, 1.0, Hash12(vec2(cell) + 23.4));
            vec3 neonColor = FutureAccentColor(Hash12(vec2(cell) + 91.2));

            float facadeEnergy = heightReach * sameHemisphere * atten * (0.35 + 0.65 * towerWeight);
            field += windowColor * align * facadeEnergy * windowDensity * 1.25;
            field += neonColor * align * facadeEnergy * neonMask * 2.25;
        }
    }

    // 向上反射由真实 sky field 负责；接近地平线/向下时补一个远城颜色。
    float skyCut = smoothstep(-0.20, 0.50, R.y);
    vec3 farCityHorizon = mix(vec3(0.10, 0.26, 0.52), vec3(0.65, 0.16, 0.56), Hash12(floor(p.xz * 0.045) + 17.0));
    field += farCityHorizon * (1.0 - skyCut) * 0.18;

    return min(field, vec3(4.0));
}

/*
Primary hit 的确定性 diffuse GI 汇总。

indirect =
    skyFill * giAO
  + sunGroundBounce
  + cityGlow
  + facadeBounce
  + secondBounce

最后乘 albedo，表示接收表面的 diffuse reflectance。
MAT_THIN_GLASS 不走此函数，因为它由 ShadeThinGlass 单独处理。
*/
vec3 EstimateProceduralCityGI(in SRayHitInfo hitInfo)
{
    if (hitInfo.materialType == MAT_THIN_GLASS)
    {
        return vec3(0.0);
    }

    vec3 n = hitInfo.normal;
    vec3 p = hitInfo.hitPoint;
    vec3 sunDir = GetSunDirection();
    ivec2 baseCell = ivec2(floor(p.xz / CITY_CELL_SIZE));

    float roadOpenness = EstimateRoadOpenness(baseCell);
    float buildingOcclusion = EstimateBuildingOcclusion(p, baseCell);

    float heightAboveGround = max(p.y - CITY_GROUND_Y, 0.0);
    // wallMask≈1 表示竖直立面；lowCanyonMask≈1 表示靠近地面。
    float wallMask = 1.0 - smoothstep(0.25, 0.85, abs(n.y));
    float lowCanyonMask = 1.0 - smoothstep(2.0, 22.0, heightAboveGround);
    // 屋顶/开放道路增加 sky visibility，低处墙面/附近高楼减少它。
    float skyVisibility = 1.0 - 0.36 * wallMask - 0.22 * lowCanyonMask - 0.42 * buildingOcclusion + 0.18 * roadOpenness;
    skyVisibility = clamp(skyVisibility, 0.18, 1.0);
    float giAO = EstimateLocalGIAO(n, heightAboveGround, roadOpenness, buildingOcclusion);

    float upLight = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
    float sideLight = 0.35 + 0.65 * upLight;

    vec3 skyFill = vec3(0.42, 0.55, 0.75) * 0.38 * sideLight * skyVisibility;

    float sunOnGround = max(sunDir.y, 0.0);
    float groundReach = (1.0 - smoothstep(8.0, 45.0, heightAboveGround));
    float wallReceivesGround = wallMask * (0.45 + 0.55 * max(dot(n, normalize(vec3(sunDir.x, 0.0, sunDir.z))), 0.0));
    float canyonWarmth = 0.55 + 0.45 * buildingOcclusion;
    // 阳光先照亮道路/广场，再给低处墙面一层暖色反弹。
    vec3 sunGroundBounce = vec3(1.00, 0.62, 0.28) * sunOnGround * groundReach * wallReceivesGround * canyonWarmth * (0.08 + 0.16 * roadOpenness);

    vec3 cityGlow = EstimateNearbyEmissionField(hitInfo, baseCell);
    vec3 facadeBounce = EstimateFacadeBounceField(hitInfo, baseCell, buildingOcclusion, roadOpenness);

    // 深街谷与竖直墙面更需要二次反弹补偿。
    float multiBounceMask = (0.28 + 0.44 * buildingOcclusion) * (0.35 + 0.65 * wallMask);
    vec3 secondBounce = (cityGlow * vec3(0.82, 0.90, 1.08) + facadeBounce * 0.85) * multiBounceMask;

    vec3 indirect = skyFill * giAO + sunGroundBounce + cityGlow + facadeBounce + secondBounce;

    // clamp 防止多个经验项叠加后产生不稳定超亮结果。
    return hitInfo.albedo * min(indirect, vec3(2.6));
}

/*
把 city specular field 应用到实际 GGX 表面。

F           : Fresnel 颜色与视角响应。
glossyMask  : 金属或低 roughness 表面才需要明显环境反射。
roughDamp   : 粗糙表面降低最终峰值能量。
*/
vec3 EstimateGlossyCityReflection(in SRayHitInfo hitInfo, in vec3 rayDir)
{
    if (hitInfo.materialType != MAT_GGX)
        return vec3(0.0);

    vec3 N = hitInfo.normal;
    vec3 V = normalize(-rayDir);
    vec3 R = normalize(reflect(rayDir, N));

    float NoV = max(dot(N, V), 0.0);
    vec3 F0 = mix(vec3(0.04), hitInfo.albedo, hitInfo.metallic);
    vec3 F = FresnelSchlick(NoV, F0);

    float smoothGloss = 1.0 - smoothstep(0.18, 0.86, hitInfo.roughness);
    float metalGloss = smoothstep(0.08, 0.65, hitInfo.metallic);
    float glossyMask = max(metalGloss, smoothGloss * 0.35);

    if (glossyMask <= 0.08)
        return vec3(0.0);

    vec3 cityReflection = EstimateCitySpecularField(hitInfo, V, R);
    vec3 skyReflection = GetSkyColor(R) * smoothstep(-0.18, 0.82, R.y) * 0.24;
    float roughDamp = mix(1.0, 0.42, clamp(hitInfo.roughness, 0.0, 1.0));

    return (cityReflection + skyReflection) * F * glossyMask * roughDamp;
}

/*
确定性太阳直接光（Next Event Estimation 的简化形式）。

由于太阳使用固定方向，不需要随机 sample 或 area-light PDF：
  L_direct = visibility * sunRadiance * BRDF(wo,wi) * max(N·wi,0)

当前点沿 normal nudge 后发射一条短程 shadow ray。
*/
vec3 EstimateDirectLighting(in SRayHitInfo hitInfo, in vec3 wo, inout uint rngState)
{
    vec3 direct = vec3(0.0);

    if (hitInfo.materialType == MAT_THIN_GLASS)
    {
        return direct;
    }

    vec3 wi = GetSunDirection();
    float cosSurface = max(dot(hitInfo.normal, wi), 0.0);

    if (cosSurface <= 0.0)
        return direct;

    vec3 shadowOrigin = hitInfo.hitPoint + hitInfo.normal * c_rayPosNormalNudge;

    if (!IsVisibleToLight(shadowOrigin, wi, CITY_MAX_SHADOW_TRACE_DIST))
        return direct;

    vec3 sunRadiance = vec3(1.00, 0.84, 0.62) * 7.2;
    vec3 brdf = EvalBRDF(hitInfo, wo, wi);

    direct += sunRadiance * brdf * cosSurface;

    return direct;
}

// ============================================================
// Path Tracing
// ============================================================

/*
追踪一条 camera sample path，并返回线性 HDR radiance。

路径状态：
  rayPos/rayDir : 当前 ray。
  throughput    : 从相机到当前路径顶点的累计 BSDF 权重。
  ret           : 路径已经收集到的 radiance。

maxBounces 的含义是“最多处理多少个 surface hit”：
  1 -> 只处理 primary surface。
  2 -> primary + 一个 secondary surface。
  3 -> primary + 两个 secondary surfaces。

混合 GI 的接入位置：
  - 每个允许的 bounce 都可以计算真实 shadowed direct sun。
  - 只有 primary hit 计算 deterministic diffuse/specular city field，
    避免在每个 secondary vertex 重复昂贵的 3x3 邻域查询。
*/
vec3 GetColorForRay(
    in vec3 startRayPos,
    in vec3 startRayDir,
    inout uint rngState,
    in int maxBounces,
    in int maxNEEBounces
)
{
    vec3 ret = vec3(0.0);
    vec3 throughput = vec3(1.0);

    vec3 rayPos = startRayPos;
    vec3 rayDir = normalize(startRayDir);

    float firstHitDist = -1.0;
    vec3 firstRayDir = rayDir;

    // 相机直接看到 emissive，或 delta path 命中 emissive 时应保留完整能量。
    // 当前精简版没有实际 delta 分支，但该状态保留了通用路径追踪结构。
    bool lastBounceDelta = true;

    // 编译期固定上限 10，运行时再由 maxBounces 提前 break。
    // 这种写法对 WebGL shader 编译器通常比动态 loop upper bound 更稳。
    for (int bounceIndex = 0; bounceIndex < 10; ++bounceIndex)
    {
        if (bounceIndex >= maxBounces)
            break;

        SRayHitInfo hitInfo;
        hitInfo.dist = c_superFar;
        InitMaterialDefaults(hitInfo);

        TestSceneTrace(rayPos, rayDir, hitInfo);

        // Miss：路径逃逸到环境，累加 sky radiance 后结束。
        if (hitInfo.dist == c_superFar)
        {
            ret += throughput * GetSkyColor(rayDir);
            break;
        }

        // 只记录 primary distance，用于最后的大气透射。
        if (bounceIndex == 0)
        {
            firstHitDist = hitInfo.dist;
        }

        // Thin glass 使用封闭式近似，不再继续追踪建筑内部。
        if (hitInfo.materialType == MAT_THIN_GLASS)
        {
            ret += throughput * ShadeThinGlass(hitInfo, rayDir);
            break;
        }

        // 命中发光表面即收集 emission 并结束。
        // 非 delta secondary hit 降权，是抑制 rare bright hit / firefly 的经验处理。
        if (length(hitInfo.emissive) > 0.0)
        {
            float emissiveHitWeight = (bounceIndex == 0 || lastBounceDelta) ? 1.0 : 0.45;
            if (bounceIndex == 0 || lastBounceDelta)
                ret += throughput * hitInfo.emissive;
            else
                ret += throughput * hitInfo.emissive * emissiveHitWeight;

            break;
        }

        vec3 wo = normalize(-rayDir);

        // NEE budget 与路径深度分开控制。
        // 深路径可以继续，但不一定每个顶点都付出一条 shadow ray。
        if (bounceIndex < maxNEEBounces)
        {
            ret += throughput * EstimateDirectLighting(hitInfo, wo, rngState);
        }

        // 程序化 GI 场只在 primary hit 计算一次。
        if (bounceIndex == 0)
        {
            ret += throughput * EstimateProceduralCityGI(hitInfo);
            ret += throughput * EstimateGlossyCityReflection(hitInfo, rayDir);
        }

        vec3 wi;
        vec3 bsdfWeight;
        bool isDelta;

        if (!SampleBSDF(hitInfo, wo, rngState, wi, bsdfWeight, isDelta))
            break;

        // 把当前反射事件的 BRDF*cos/PDF 乘入路径能量。
        throughput *= bsdfWeight;

        // 有偏 clamp：低 spp 下防止极端 PDF/BRDF 组合产生长时间亮点。
        throughput = min(throughput, vec3(6.0));

        rayDir = normalize(wi);
        // 沿下一条 rayDir 移开，而不是固定沿 normal；对反射方向更直接。
        rayPos = hitInfo.hitPoint + rayDir * c_rayPosNormalNudge;

        lastBounceDelta = isDelta;

        // 第三个 surface 之后才启用 Russian roulette。
        // 当前实际最大深度为 3，因此它主要保留通用扩展能力。
        if (bounceIndex > 1)
        {
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05, 0.95);

            if (RandomFloat01(rngState) > p)
                break;

            throughput /= p;
        }
    }

    // 最终 HDR clamp，与 throughput clamp 一样是稳定性优先的有偏策略。
    ret = min(ret, vec3(8.0));

    if (firstHitDist > 0.0 && firstHitDist < c_superFar)
    {
        // 只按相机到 primary hit 的距离做一次大气衰减，
        // 不对每个 bounce 单独积体积散射。
        ret = ApplySceneAtmosphere(ret, firstHitDist, firstRayDir);
    }

    return ret;
}

// ============================================================
// Camera Controls
// ============================================================

// ShaderToy keyboard texture：第一行第 keyCode 个 texel 表示该键是否按下。
float KeyDown(int keyCode)
{
    return texelFetch(iChannel1, ivec2(keyCode, 0), 0).x;
}

/*
由 yaw/pitch 构造相机正交基。

forward 的水平投影由 yaw 决定，y 分量由 pitch 决定；
right = worldUp × forward；
up    = forward × right。
*/
void GetCameraBasis(
    in float yaw,
    in float pitch,
    out vec3 forward,
    out vec3 right,
    out vec3 up
)
{
    pitch = clamp(pitch, -1.5, 1.5);

    forward = normalize(vec3(
        sin(yaw) * cos(pitch),
        sin(pitch),
        cos(yaw) * cos(pitch)
    ));

    vec3 worldUp = vec3(0.0, 1.0, 0.0);

    right = normalize(cross(worldUp, forward));
    up = normalize(cross(forward, right));
}

/*
把 fragCoord 映射到 perspective camera ray。

screen 先变换到 [-1,1]，再按 aspect 修正 y；
cameraDistance = 1/tan(FOV/2) 相当于虚拟成像平面的焦距。
*/
vec3 GetCameraRayDir(
    in vec2 fragCoord,
    in vec3 forward,
    in vec3 right,
    in vec3 up,
    in float fovDegrees
)
{
    vec2 screen = fragCoord / iResolution.xy;
    screen = screen * 2.0 - 1.0;

    float aspectRatio = iResolution.x / iResolution.y;
    screen.y /= aspectRatio;

    float cameraDistance = 1.0 / tan(fovDegrees * 0.5 * c_PI_NEE / 180.0);

    return normalize(
        forward * cameraDistance +
        right * screen.x +
        up * screen.y
    );
}

/*
从 Buffer A 的状态像素恢复并更新相机。

iFrame==0 使用默认相机；
之后读取上一帧：
  (0,0) camera position
  (1,0) yaw/pitch
  (2,0) previous mouse

只要鼠标或键盘造成变化，就设置 cameraMoved=true，
mainImage 会降低路径预算并重置累积权重。
*/
void ComputeCameraState(
    out vec3 cameraPos,
    out float cameraYaw,
    out float cameraPitch,
    out bool cameraMoved
)
{
    vec3 defaultPos = vec3(5.2, 4.6, -28.0);
    float defaultYaw = 0.16;
    float defaultPitch = 0.02;

    if (iFrame == 0)
    {
        cameraPos = defaultPos;
        cameraYaw = defaultYaw;
        cameraPitch = defaultPitch;
        cameraMoved = true;
        return;
    }

    cameraPos = texelFetch(iChannel0, ivec2(0, 0), 0).xyz;

    vec4 rotState = texelFetch(iChannel0, ivec2(1, 0), 0);
    cameraYaw = rotState.x;
    cameraPitch = rotState.y;

    vec4 prevMouseState = texelFetch(iChannel0, ivec2(2, 0), 0);
    vec2 prevMouse = prevMouseState.xy;
    bool prevMouseDown = prevMouseState.z > 0.5;

    bool mouseDown = iMouse.z > 0.0;
    vec2 mouse = iMouse.xy;

    cameraMoved = false;

    // 只有连续两帧都按住鼠标才计算 delta，避免刚按下时产生大跳变。
    if (mouseDown && prevMouseDown)
    {
        vec2 mouseDelta = mouse - prevMouse;

        float mouseSensitivity = 0.003;

        cameraYaw += mouseDelta.x * mouseSensitivity;
        cameraPitch += mouseDelta.y * mouseSensitivity;
        cameraPitch = clamp(cameraPitch, -1.5, 1.5);

        if (dot(mouseDelta, mouseDelta) > 0.0)
            cameraMoved = true;
    }

    vec3 forward, right, up;
    GetCameraBasis(cameraYaw, cameraPitch, forward, right, up);

    // ASCII key codes：W=87, S=83, D=68, A=65, E=69, Q=81。
    float moveForward = KeyDown(87) - KeyDown(83);
    float moveRight   = KeyDown(68) - KeyDown(65);
    float moveUp      = KeyDown(69) - KeyDown(81);

    vec3 moveDir = forward * moveForward + right * moveRight + up * moveUp;

    if (length(moveDir) > 0.0)
    {
        moveDir = normalize(moveDir);

        float speed = 8.0;
        // 限制 dt，浏览器卡顿后不会让相机突然跨过很大距离。
        float dt = clamp(iTimeDelta, 0.0, 0.05);

        float shift = KeyDown(16);
        speed *= mix(1.0, 3.0, shift);

        cameraPos += moveDir * speed * dt;
        cameraMoved = true;
    }

    if (KeyDown(82) > 0.5)
    {
        cameraPos = defaultPos;
        cameraYaw = defaultYaw;
        cameraPitch = defaultPitch;
        cameraMoved = true;
    }
}

// ============================================================
// Main
// State pixels:
// (0,0): camera position
// (1,0): yaw, pitch, moved
// (2,0): mouse x, mouse y, mouse down
// (3,0): accumulated sample count
//
// 这四个像素不保存画面，而是把 Buffer A 当作一个极小的持久状态存储。
// Image pass 会把它们从最终可见区域移走。
// ============================================================

/*
每像素入口。

执行顺序：
  1. 恢复/更新相机。
  2. 若当前像素属于状态区，写状态并 return。
  3. 为普通像素生成 camera basis 和 per-sample RNG。
  4. 根据 cameraMoved / checkerboard 选择 path budget。
  5. 追踪 c_spp 条路径。
  6. 相机移动时弱混合历史；静止时按 sample count 做无偏均值累积。
*/
void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec3 cameraPos;
    float cameraYaw;
    float cameraPitch;
    bool cameraMoved;

    ComputeCameraState(cameraPos, cameraYaw, cameraPitch, cameraMoved);

    ivec2 ip = ivec2(fragCoord);

    // 状态像素必须在所有昂贵渲染之前 early return。
    if (ip.x == 0 && ip.y == 0)
    {
        fragColor = vec4(cameraPos, 1.0);
        return;
    }

    if (ip.x == 1 && ip.y == 0)
    {
        fragColor = vec4(cameraYaw, cameraPitch, cameraMoved ? 1.0 : 0.0, 1.0);
        return;
    }

    if (ip.x == 2 && ip.y == 0)
    {
        bool mouseDown = iMouse.z > 0.0;
        fragColor = vec4(iMouse.xy, mouseDown ? 1.0 : 0.0, 1.0);
        return;
    }

    if (ip.x == 3 && ip.y == 0)
    {
        float prevCount = 0.0;

        // 相机移动后丢弃旧 sample count；静止时继续累计。
        if (iFrame > 0 && !cameraMoved)
        {
            prevCount = texelFetch(iChannel0, ivec2(3, 0), 0).x;
        }

        float newCount = prevCount + float(c_spp);
        fragColor = vec4(newCount, 0.0, 0.0, 1.0);
        return;
    }

    vec3 forward, right, up;
    GetCameraBasis(cameraYaw, cameraPitch, forward, right, up);

    float c_FOVDegrees = 85.0;
    vec3 rayPosition = cameraPos;

    // 移动时只处理 primary surface；静止深样本最多处理 3 个 surface。
    int maxBounces = cameraMoved ? 1 : 3;
    int maxNEEBounces = cameraMoved ? 1 : 2;

    vec3 currentColor = vec3(0.0);

    for (int s = 0; s < c_spp; ++s)
    {
        // pixel + frame + sample 的组合使相邻像素、相邻帧和同帧样本去相关。
        uint rngState =
            uint(uint(fragCoord.x) * 1973u +
                 uint(fragCoord.y) * 9277u +
                 uint(iFrame)      * 26699u +
                 uint(s)           * 7919u) | 1u;

        // 在像素 footprint 内 jitter，时间累积后形成抗锯齿。
        vec2 jitter = RandomInUnitSquare(rngState) - 0.5;
        vec2 sampleFragCoord = fragCoord + jitter;

        vec3 rayDir = GetCameraRayDir(
            sampleFragCoord,
            forward,
            right,
            up,
            c_FOVDegrees
        );

        int sampleMaxBounces = maxBounces;
        int sampleMaxNEEBounces = maxNEEBounces;
        /*
        稀疏深路径调度：
          - 只在相机静止时启用。
          - 每像素两个 sample 中只有 s==0 有资格。
          - (x+y+frame) mod 4 让约 1/4 像素每帧轮换获得深路径。

        因此深路径在空间上稀疏、时间上覆盖，平均成本远低于全屏 3-hit。
        */
        bool deepPathSample =
            !cameraMoved &&
            s == 0 &&
            mod(floor(fragCoord.x) + floor(fragCoord.y) + float(iFrame), 4.0) < 1.0;

        // 普通静止样本只走 2 hits + 1 次 direct-light shadow query。
        if (!deepPathSample)
        {
            sampleMaxBounces = cameraMoved ? 1 : 2;
            sampleMaxNEEBounces = 1;
        }

        currentColor += GetColorForRay(
            rayPosition,
            rayDir,
            rngState,
            sampleMaxBounces,
            sampleMaxNEEBounces
        );
    }

    currentColor /= float(c_spp);

    if (iFrame == 0)
    {
        fragColor = vec4(currentColor, 1.0);
    }
    else if (cameraMoved)
    {
        vec2 uv = fragCoord / iResolution.xy;
        vec3 prevColor = texture(iChannel0, uv).rgb;

        // 移动时不做严格累积，只保留少量上一帧以减轻闪烁。
        float history = 0.12;
        vec3 mixedColor = mix(currentColor, prevColor, history);

        fragColor = vec4(mixedColor, 1.0);
    }
    else
    {
        vec2 uv = fragCoord / iResolution.xy;
        vec3 prevColor = texture(iChannel0, uv).rgb;

        float prevCount = texelFetch(iChannel0, ivec2(3, 0), 0).x;
        float currCount = float(c_spp);
        float newCount = prevCount + currCount;

        // 静止时按历史 sample 数做在线均值：
        // newMean = (oldMean*oldCount + batchMean*batchCount) / newCount
        vec3 accumulatedColor =
            (prevColor * prevCount + currentColor * currCount) / newCount;

        fragColor = vec4(accumulatedColor, 1.0);
    }
}
