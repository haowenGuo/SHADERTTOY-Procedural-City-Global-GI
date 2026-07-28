const float c_minimumRayHitTime = 0.001;
const float c_superFar = 1000.0;
const float c_rayPosNormalNudge = 0.001;
const float c_PI_NEE = 3.1415926;

const int c_spp = 2;

const int MAT_DIFFUSE     = 0;
const int MAT_GGX         = 1;
const int MAT_THIN_GLASS  = 5;

const float CITY_GROUND_Y = -4.0;
const float CITY_CELL_SIZE = 4.0;
const int CITY_MAX_CELLS = 56;
const float CITY_MAX_TRACE_DIST = 190.0;
const int CITY_MAX_SHADOW_CELLS = 28;
const float CITY_MAX_SHADOW_TRACE_DIST = 110.0;

struct SRayHitInfo
{
    float dist;
    vec3 normal;
    vec3 albedo;
    vec3 emissive;
    vec3 hitPoint;
    bool frontFace;

    int materialType;
    float roughness;
    float metallic;
    float ior;
};

void InitMaterialDefaults(inout SRayHitInfo hitInfo)
{
    hitInfo.materialType = MAT_DIFFUSE;
    hitInfo.roughness = 0.5;
    hitInfo.metallic = 0.0;
    hitInfo.ior = 1.5;
    hitInfo.albedo = vec3(0.0);
    hitInfo.emissive = vec3(0.0);
}

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
// ============================================================

float Hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 Hash22(vec2 p)
{
    float n = Hash12(p);
    return vec2(n, Hash12(p + n + 19.19));
}

float Noise2(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);

    f = f * f * (3.0 - 2.0 * f);

    float a = Hash12(i);
    float b = Hash12(i + vec2(1.0, 0.0));
    float c = Hash12(i + vec2(0.0, 1.0));
    float d = Hash12(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

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

float sdBox2D(vec2 p, vec2 b)
{
    vec2 q = abs(p) - b;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
}

// ============================================================
// Brick Material
// ============================================================

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

    float row = floor(q.y / brickH);
    q.x += mod(row, 2.0) * brickW * 0.5;

    vec2 brickId = floor(vec2(q.x / brickW, q.y / brickH));
    vec2 f = fract(vec2(q.x / brickW, q.y / brickH));

    float edgeX = min(f.x, 1.0 - f.x) * brickW;
    float edgeY = min(f.y, 1.0 - f.y) * brickH;

    float edge = min(edgeX, edgeY);

    mortar = 1.0 - smoothstep(0.015, 0.035, edge);
    brickRand = Hash12(brickId + seed);

    return 1.0 - mortar;
}

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

vec3 ApplySceneAtmosphere(vec3 col, float t, vec3 rd)
{
    vec3 fogCol = vec3(0.42, 0.52, 0.66) - rd.y * vec3(0.05, 0.08, 0.12);
    vec3 ext = exp2(-t * 0.0022 * vec3(1.0, 1.22, 1.65));

    return col * ext + fogCol * (1.0 - ext);
}

// ============================================================
// Geometry
// ============================================================

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

    float t = t1;
    if (t <= c_minimumRayHitTime)
        t = t2;

    if (t > c_minimumRayHitTime && t < info.dist)
    {
        info.dist = t;

        vec3 hitPoint = rayPos + rayDir * t;
        vec3 outwardNormal = normalize(hitPoint - sphere.xyz);

        info.frontFace = dot(rayDir, outwardNormal) < 0.0;
        info.normal = info.frontFace ? outwardNormal : -outwardNormal;
        info.hitPoint = hitPoint;

        return true;
    }

    return false;
}

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
// ============================================================

vec3 FutureAccentColor(float t)
{
    return mix(
        vec3(0.08, 0.70, 1.00),
        vec3(1.00, 0.12, 0.82),
        smoothstep(0.0, 1.0, t)
    );
}

bool IsMainRoadCell(ivec2 cell)
{
    return abs(mod(float(cell.x), 8.0)) < 1.0 ||
           abs(mod(float(cell.y), 8.0)) < 1.0;
}

bool IsSecondaryRoadCell(ivec2 cell)
{
    return abs(mod(float(cell.x + 3), 4.0)) < 1.0 ||
           abs(mod(float(cell.y + 3), 4.0)) < 1.0;
}

bool IsRoadCell(ivec2 cell)
{
    return IsMainRoadCell(cell) || IsSecondaryRoadCell(cell);
}

bool IsPlazaCell(ivec2 cell)
{
    if (IsRoadCell(cell))
        return false;

    vec2 c = vec2(cell);

    if (length(c) < 2.3)
        return true;

    return Hash12(c + 71.3) > 0.987;
}

float CitySpineMask(vec2 p)
{
    float mainSpine = 1.0 - smoothstep(7.0, 23.0, abs(p.x));
    float crossSpine = 1.0 - smoothstep(7.0, 23.0, abs(p.y - 8.0));
    return clamp(max(mainSpine, crossSpine * 0.55), 0.0, 1.0);
}

float CityLandmarkMask(vec2 p)
{
    float centerNeedle = 1.0 - smoothstep(0.0, 18.0, length(p - vec2(0.0, 28.0)));
    float farNeedle = 1.0 - smoothstep(0.0, 22.0, length(p - vec2(18.0, 74.0)));
    float westNeedle = 1.0 - smoothstep(0.0, 20.0, length(p - vec2(-30.0, 48.0)));
    return max(centerNeedle, max(farNeedle * 0.84, westNeedle * 0.72));
}

float BuildingArchetype(in ivec2 cell)
{
    vec2 cf = vec2(cell);
    return floor(Hash12(cf + 188.4) * 5.0);
}

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
    float district = max(spine, landmark);
    float archetype = BuildingArchetype(cell);
    float glassNeedle = step(3.5, archetype);
    float darkSlab = step(2.5, archetype) * (1.0 - step(3.5, archetype));
    float steppedPodium = step(1.5, archetype) * (1.0 - step(2.5, archetype));
    float warmBlock = step(0.5, archetype) * (1.0 - step(1.5, archetype));

    vec2 jitter = (Hash22(cf + 13.7) - 0.5) * CITY_CELL_SIZE * mix(0.18, 0.08, spine);
    vec2 center = blockCenter + jitter;

    landmark = max(landmark, CityLandmarkMask(center));
    district = max(spine, landmark);
    float skylineNoise = Hash12(cf * 0.31 + vec2(11.0, 3.7));
    float rareNeedle = smoothstep(0.90, 1.0, Hash12(cf + 41.2));
    float heightSeed = Hash12(cf + 1.3);

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
    bool roof = abs(n.y) > 0.5;

    float localU;
    float wallWidth;

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
    float signatureMask = clamp(max(spineMask * 0.78, landmarkMask) + heightMask * 0.26, 0.0, 1.0);

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

    vec2 windowGrid = vec2(localU * windowCols, v * windowRows);
    vec2 windowCell = floor(windowGrid);
    vec2 windowUV = fract(windowGrid) - 0.5;

    float windowSDF = sdBox2D(windowUV, vec2(0.25, 0.32));

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

    float structureMask = max(verticalStructure, horizontalStructure);
    brickCol *= mix(1.0, 0.72, structureMask * 0.22);

    float grime = FBM(p.xz * 0.12 + vec2(float(style) * 4.3, 7.1));
    brickCol *= mix(0.88, 1.18, grime);

    float facadeSeed = Hash12(vec2(cell) + float(style) * 31.7);
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

    brickCol = mix(brickCol, woodColor, clamp(woodPanel, 0.0, 0.65));
    roughness = mix(roughness, 0.58, clamp(woodPanel, 0.0, 0.80));

    brickCol = mix(brickCol, metalColor, clamp(metalPanel, 0.0, 0.82));
    roughness = mix(roughness, 0.24, clamp(metalPanel, 0.0, 0.85));
    metallic = mix(metallic, 0.62, clamp(metalPanel, 0.0, 0.85));

    brickCol = mix(brickCol, glassPanelColor, clamp(curtainGlass, 0.0, 0.88));
    roughness = mix(roughness, 0.07, clamp(curtainGlass, 0.0, 0.90));
    metallic = mix(metallic, 0.0, clamp(curtainGlass, 0.0, 0.90));

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

    float nextBoundaryX = (rayDir.x >= 0.0 ? float(cell.x + 1) : float(cell.x)) * CITY_CELL_SIZE;
    float nextBoundaryZ = (rayDir.z >= 0.0 ? float(cell.y + 1) : float(cell.y)) * CITY_CELL_SIZE;

    float tMaxX = abs(rayDir.x) < 1e-6 ? 1e20 : (nextBoundaryX - rayPos.x) / rayDir.x;
    float tMaxZ = abs(rayDir.z) < 1e-6 ? 1e20 : (nextBoundaryZ - rayPos.z) / rayDir.z;

    float tDeltaX = abs(rayDir.x) < 1e-6 ? 1e20 : abs(CITY_CELL_SIZE / rayDir.x);
    float tDeltaZ = abs(rayDir.z) < 1e-6 ? 1e20 : abs(CITY_CELL_SIZE / rayDir.z);

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
}

void TestSceneTrace(in vec3 rayPos, in vec3 rayDir, inout SRayHitInfo hitInfo)
{
    TraceProceduralCity(rayPos, rayDir, hitInfo);
}

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

bool TestCityGroundOcclusion(in vec3 rayPos, in vec3 rayDir, in float maxDist)
{
    if (abs(rayDir.y) < 1e-6)
        return false;

    float t = (CITY_GROUND_Y - rayPos.y) / rayDir.y;
    return t > c_minimumRayHitTime && t < maxDist;
}

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

bool TraceProceduralCityOcclusion(in vec3 rayPos, in vec3 rayDir, in float maxDist)
{
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
// ============================================================

uint wang_hash(inout uint seed)
{
    seed = uint(seed ^ uint(61)) ^ uint(seed >> uint(16));
    seed *= uint(9);
    seed = seed ^ (seed >> 4);
    seed *= uint(0x27d4eb2d);
    seed = seed ^ (seed >> 15);
    return seed;
}

float RandomFloat01(inout uint state)
{
    return float(wang_hash(state)) / 4294967296.0;
}

vec2 RandomInUnitSquare(inout uint state)
{
    return vec2(RandomFloat01(state), RandomFloat01(state));
}

// ============================================================
// Sky / Light
// ============================================================

vec3 GetSunDirection()
{
    return normalize(vec3(-0.32, 0.62, 0.42));
}

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

bool IsVisibleToLight(in vec3 rayPos, in vec3 rayDir, in float maxDist)
{
    return !TraceProceduralCityOcclusion(rayPos, rayDir, maxDist);
}

// ============================================================
// Sampling / BRDF / BSDF
// ============================================================

void MakeONB(in vec3 n, out vec3 t, out vec3 b)
{
    vec3 up = abs(n.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}

vec3 ToWorld(in vec3 localDir, in vec3 n)
{
    vec3 t, b;
    MakeONB(n, t, b);
    return normalize(t * localDir.x + b * localDir.y + n * localDir.z);
}

vec3 SampleCosineHemisphere(in vec3 n, inout uint rngState)
{
    float u1 = RandomFloat01(rngState);
    float u2 = RandomFloat01(rngState);

    float r = sqrt(u1);
    float phi = 2.0 * c_PI_NEE * u2;

    vec3 localDir = vec3(
        r * cos(phi),
        r * sin(phi),
        sqrt(max(0.0, 1.0 - u1))
    );

    return ToWorld(localDir, n);
}

float CosineHemispherePdf(in vec3 n, in vec3 wi)
{
    return max(dot(n, wi), 0.0) / c_PI_NEE;
}

vec3 FresnelSchlick(in float cosTheta, in vec3 F0)
{
    float f = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    return F0 + (1.0 - F0) * f;
}

float FresnelSchlickScalar(in float cosTheta, in float F0)
{
    float f = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    return F0 + (1.0 - F0) * f;
}

vec3 EstimateCitySpecularField(in SRayHitInfo hitInfo, in vec3 viewDir, in vec3 reflectionDir);

vec3 ShadeThinGlass(
    in SRayHitInfo hitInfo,
    in vec3 rayDir
)
{
    vec3 N = hitInfo.normal;
    vec3 V = normalize(-rayDir);

    float NoV = max(dot(N, V), 0.0);
    float fresnel = FresnelSchlickScalar(NoV, 0.04);

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

float GeometrySchlickGGX(in float NdotV, in float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / max(NdotV * (1.0 - k) + k, 1e-6);
}

float GeometrySmith(in vec3 N, in vec3 V, in vec3 L, in float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

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

        vec3 F0 = mix(vec3(0.04), hitInfo.albedo, hitInfo.metallic);
        vec3 F = FresnelSchlick(VdotH, F0);

        float D = DistributionGGX(N, H, hitInfo.roughness);
        float G = GeometrySmith(N, wo, wi, hitInfo.roughness);

        vec3 specular = D * G * F / max(4.0 * NdotV * NdotL, 1e-6);

        vec3 kD = (vec3(1.0) - F) * (1.0 - hitInfo.metallic);
        vec3 diffuse = kD * hitInfo.albedo / c_PI_NEE;

        return diffuse + specular;
    }

    return vec3(0.0);
}

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

        float pdf = pDiffuse * pdfDiffuse + pSpecular * pdfSpecular;
        if (pdf <= 1e-6)
            return false;

        vec3 brdf = EvalBRDF(hitInfo, wo, wi);
        weight = brdf * cosTheta / pdf;
        return true;
    }

    return false;
}

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
            float nearWeight = 1.0 / (1.0 + 0.055 * dist2);

            occlusion += tallerThanPoint * nearWeight;
        }
    }

    return clamp(occlusion * 0.28, 0.0, 0.78);
}

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
            vec3 toCell = normalize(vec3(toCell2.x, 0.0, toCell2.y) + vec3(1e-4, 0.0, 0.0));
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
            float sampleY = clamp(
                p.y + R.y * 18.0 + mix(3.0, 20.0, Hash12(vec2(cell) + 8.1)),
                CITY_GROUND_Y + 1.5,
                max(shadowMax.y - 0.5, CITY_GROUND_Y + 2.0)
            );

            float heightReach = smoothstep(p.y - 16.0, p.y + 48.0, shadowMax.y);
            vec3 lightPos = vec3(cellCenter.x, sampleY, cellCenter.y);
            vec3 L = normalize(lightPos - p);

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

    float skyCut = smoothstep(-0.20, 0.50, R.y);
    vec3 farCityHorizon = mix(vec3(0.10, 0.26, 0.52), vec3(0.65, 0.16, 0.56), Hash12(floor(p.xz * 0.045) + 17.0));
    field += farCityHorizon * (1.0 - skyCut) * 0.18;

    return min(field, vec3(4.0));
}

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
    float wallMask = 1.0 - smoothstep(0.25, 0.85, abs(n.y));
    float lowCanyonMask = 1.0 - smoothstep(2.0, 22.0, heightAboveGround);
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
    vec3 sunGroundBounce = vec3(1.00, 0.62, 0.28) * sunOnGround * groundReach * wallReceivesGround * canyonWarmth * (0.08 + 0.16 * roadOpenness);

    vec3 cityGlow = EstimateNearbyEmissionField(hitInfo, baseCell);
    vec3 facadeBounce = EstimateFacadeBounceField(hitInfo, baseCell, buildingOcclusion, roadOpenness);

    float multiBounceMask = (0.28 + 0.44 * buildingOcclusion) * (0.35 + 0.65 * wallMask);
    vec3 secondBounce = (cityGlow * vec3(0.82, 0.90, 1.08) + facadeBounce * 0.85) * multiBounceMask;

    vec3 indirect = skyFill * giAO + sunGroundBounce + cityGlow + facadeBounce + secondBounce;

    return hitInfo.albedo * min(indirect, vec3(2.6));
}

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

    bool lastBounceDelta = true;

    for (int bounceIndex = 0; bounceIndex < 10; ++bounceIndex)
    {
        if (bounceIndex >= maxBounces)
            break;

        SRayHitInfo hitInfo;
        hitInfo.dist = c_superFar;
        InitMaterialDefaults(hitInfo);

        TestSceneTrace(rayPos, rayDir, hitInfo);

        if (hitInfo.dist == c_superFar)
        {
            ret += throughput * GetSkyColor(rayDir);
            break;
        }

        if (bounceIndex == 0)
        {
            firstHitDist = hitInfo.dist;
        }

        if (hitInfo.materialType == MAT_THIN_GLASS)
        {
            ret += throughput * ShadeThinGlass(hitInfo, rayDir);
            break;
        }

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

        if (bounceIndex < maxNEEBounces)
        {
            ret += throughput * EstimateDirectLighting(hitInfo, wo, rngState);
        }

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

        throughput *= bsdfWeight;
        throughput = min(throughput, vec3(6.0));

        rayDir = normalize(wi);
        rayPos = hitInfo.hitPoint + rayDir * c_rayPosNormalNudge;

        lastBounceDelta = isDelta;

        if (bounceIndex > 1)
        {
            float p = max(throughput.r, max(throughput.g, throughput.b));
            p = clamp(p, 0.05, 0.95);

            if (RandomFloat01(rngState) > p)
                break;

            throughput /= p;
        }
    }

    ret = min(ret, vec3(8.0));

    if (firstHitDist > 0.0 && firstHitDist < c_superFar)
    {
        ret = ApplySceneAtmosphere(ret, firstHitDist, firstRayDir);
    }

    return ret;
}

// ============================================================
// Camera Controls
// ============================================================

float KeyDown(int keyCode)
{
    return texelFetch(iChannel1, ivec2(keyCode, 0), 0).x;
}

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

    float moveForward = KeyDown(87) - KeyDown(83);
    float moveRight   = KeyDown(68) - KeyDown(65);
    float moveUp      = KeyDown(69) - KeyDown(81);

    vec3 moveDir = forward * moveForward + right * moveRight + up * moveUp;

    if (length(moveDir) > 0.0)
    {
        moveDir = normalize(moveDir);

        float speed = 8.0;
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
// ============================================================

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec3 cameraPos;
    float cameraYaw;
    float cameraPitch;
    bool cameraMoved;

    ComputeCameraState(cameraPos, cameraYaw, cameraPitch, cameraMoved);

    ivec2 ip = ivec2(fragCoord);

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

    int maxBounces = cameraMoved ? 1 : 3;
    int maxNEEBounces = cameraMoved ? 1 : 2;

    vec3 currentColor = vec3(0.0);

    for (int s = 0; s < c_spp; ++s)
    {
        uint rngState =
            uint(uint(fragCoord.x) * 1973u +
                 uint(fragCoord.y) * 9277u +
                 uint(iFrame)      * 26699u +
                 uint(s)           * 7919u) | 1u;

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
        bool deepPathSample =
            !cameraMoved &&
            s == 0 &&
            mod(floor(fragCoord.x) + floor(fragCoord.y) + float(iFrame), 4.0) < 1.0;

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

        vec3 accumulatedColor =
            (prevColor * prevCount + currentColor * currCount) / newCount;

        fragColor = vec4(accumulatedColor, 1.0);
    }
}
