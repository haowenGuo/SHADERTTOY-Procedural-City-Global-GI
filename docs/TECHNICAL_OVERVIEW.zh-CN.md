# 技术说明

本文从程序化城市生成、路径追踪、全局光照和性能优化四个角度说明最终版 `FutureCity_BufferA.glsl`。

## 代码地图

主要函数和结构如下：

- 常量、材质 ID、hit record：文件开头
- hash、noise、FBM：`Hash12`、`Hash22`、`Noise2`、`FBM`
- 砖墙材质：`BrickPattern`、`BrickColor`
- 城市布局：`CitySpineMask`、`CityLandmarkMask`、`BuildingArchetype`
- 建筑几何：`GetFutureBuildingBounds`
- 阴影/GI proxy：`GetFutureBuildingShadowBounds`
- 立面材质：`SetFutureFacadeMaterial`
- 主场景遍历：`TraceProceduralCity`
- 阴影/proxy 遍历：`TraceProceduralCityOcclusion`
- BSDF 与采样：`EvalBRDF`、`SampleBSDF`
- 城市 GI：`EstimateProceduralCityGI`
- 城市反射：`EstimateCitySpecularField`、`EstimateGlossyCityReflection`
- 直射太阳光：`EstimateDirectLighting`
- 路径追踪循环：`GetColorForRay`
- 相机、采样、时间累积：`mainImage`

## 程序化城市生成

场景基于二维 city cell。世界坐标的 `xz` 平面除以 `CITY_CELL_SIZE` 得到 `ivec2 cell`，然后所有城市结构都从这个 cell 的 hash 派生出来。这样城市不需要任何 mesh、贴图或存储表，也能保持稳定、可复现、尺度很大。

### 道路和广场

`IsMainRoadCell`、`IsSecondaryRoadCell` 和 `IsRoadCell` 生成规则化道路网络。主路每 8 个 cell 出现，次级道路每 4 个 cell 出现并带偏移。`IsPlazaCell` 在中心区域和稀有 cell 上生成广场，同时避开道路。

这个结构让 DDA 遍历中存在大量开阔走廊，画面不会变成完全随机的高楼盒子堆叠，也让默认视角能形成更清晰的街谷透视。

### 城市构图 mask

城市不是纯随机铺砖，而是由两个低频 mask 组织：

- `CitySpineMask`：制造中央主轴街谷和较弱的横向轴线。
- `CityLandmarkMask`：制造几个高层地标簇。

这些 mask 会影响楼高、玻璃比例、霓虹密度、窗户密度、建筑细长程度和材质倾向。它们让 skyline 有层次，而不是均匀噪声。

### 建筑 archetype

`BuildingArchetype` 将非道路 cell 映射为几种抽象建筑类型：

- warm block
- stepped podium
- dark slab
- glass needle
- brick/composite tower

`GetFutureBuildingBounds` 根据 archetype、spine、landmark 和 hash 生成 podium/tower bounds、楼高、footprint、细长轴和 style。实际几何主要是 analytic box，辅以 roof equipment、spire 和 beacon。

### 立面材质

`SetFutureFacadeMaterial` 在 box 命中后根据命中点、法线和 wall-space 坐标生成局部材质：

- 窗户来自 wall grid 和 `sdBox2D`
- 窗光分为 warm/cool emissive
- 砖墙通过 mortar、per-brick variation 和 dirt FBM 生成
- 金属面板来自结构线和 panel gap
- 玻璃幕墙在高塔、spine 和 landmark 上更常见
- 木质装饰偏向 warm/stepped facade
- 霓虹招牌由二维 sign frame SDF 生成

最终保留的显式材质类型只有 diffuse、GGX 和 thin glass。视觉上的金属、玻璃、砖、木等差异主要来自 albedo、roughness、metallic、emissive 和确定性的反射场。

## 几何遍历

主可见性由 `TraceProceduralCity` 完成。它在 `xz` 平面上做有界 2D DDA：

1. 根据 ray 起点找到所在 cell。
2. 计算下一条 x/z cell 边界的交点距离。
3. 每次只测试当前 cell 中的道路、广场、建筑、屋顶和细节。
4. 按最近的边界移动到下一个 cell。
5. 用 `CITY_MAX_CELLS` 和 `CITY_MAX_TRACE_DIST` 限制遍历。

这就是场景“巨大”但仍然可控的关键。shader 不需要存储城市，也不会无界搜索。

阴影和 GI 查询使用 `TraceProceduralCityOcclusion`。它使用更短的 DDA 和 `GetFutureBuildingShadowBounds` 生成的简化 proxy box。可见几何可以保持丰富，而阴影/GI 查询不会重复所有细节。

## 路径追踪

`GetColorForRay` 是核心路径循环。每条 ray 的流程是：

1. 追踪最近城市命中。
2. 没有命中则返回 sky。
3. 命中 thin glass 时使用天空反射和城市反射场直接着色。
4. 命中 emissive 时加入 emission 并终止。
5. 对选定 bounce 加入带阴影的太阳直射。
6. primary hit 加入程序化城市 GI 和 glossy city reflection。
7. 使用 BSDF sample 继续路径。

BSDF 支持：

- diffuse 的 cosine hemisphere sampling
- GGX 的 diffuse/specular 混合采样
- Schlick Fresnel
- GGX distribution 和 Smith geometry
- thin glass 的专门快速 shading

提交版本的真实路径深度是保守的：普通静止样本为 2 个 surface hit，时间 checkerboard 的一部分样本为 3 个 surface hit。这样能保留真实 secondary sun lighting 和少量 emissive path hit，同时避免每个样本都付出深路径成本。

## 全局光照

这个 shader 的 GI 有两层：真实路径传输和确定性的程序化 irradiance。

### 真实路径传输

真实路径部分负责：

- primary visibility
- 太阳直射和 hard shadow
- secondary path continuation
- 部分 secondary hit 的 shadowed sun
- 随机路径命中发光窗户/霓虹时的 indirect emission
- GGX glossy continuation

这让渲染器仍然和物理路径追踪保持联系。但在 `c_spp = 2` 的条件下，随机路径很少能命中小面积窗户和霓虹，因此还需要程序化 GI 场来稳定表达间接光。

### 漫反射城市 irradiance field

`EstimateProceduralCityGI` 组合了几个稳定项：

- `EstimateRoadOpenness`：估计附近道路/广场开阔度，开阔处获得更多 sky 和 road bounce。
- `EstimateBuildingOcclusion`：根据附近 proxy building 高度和距离估计街谷遮蔽。
- sky visibility：由法线、高度、building occlusion 和 road openness 估计。屋顶更亮，低处墙面更暗。
- warm ground bounce：模拟太阳照亮道路/广场后给附近墙面的暖色反弹。
- `EstimateNearbyEmissionField`：估计附近窗户、霓虹、道路和广场带来的局部色溢出。
- `EstimateFacadeBounceField`：估计低频立面互反弹，颜色来自同一套程序化建筑规则。
- cheap second bounce：在街谷遮蔽强的地方放大多次反弹感。

这些项合成后乘以 surface albedo，并做 clamp，避免能量爆炸。

### 金属和玻璃的城市反射场

金属和玻璃如果只依赖低 sample path tracing，通常只能看到天空或噪声。因此 shader 使用 `EstimateCitySpecularField`。

它沿反射方向从附近 cell 估计能量：

- road glow
- plaza glow
- lit window field
- neon color
- tower height/density
- far city horizon color

`EstimateGlossyCityReflection` 根据 Fresnel、roughness 和 metallic 把这个场加到 GGX 材质上。`ShadeThinGlass` 也使用同一城市反射场，再混合天空反射和太阳 glint。

这不是严格无偏的反射路径追踪，而是一个确定性近似，用来让低 sample 的 ShaderToy 城市依然有可读的玻璃和金属反射。

## 路径追踪优化

主要优化策略：

- `c_spp = 2` 降低每帧采样数。
- 相机移动时只追踪 1 个 surface hit，保证交互。
- 相机静止时使用时间累积。
- 只有 checkerboard 子集启用 3 hit 深路径。
- 普通静止样本为 2 hit。
- 太阳直射使用单个方向 shadow ray，不采样大面积光源。
- 阴影 ray 使用 proxy bounds 和较短 DDA。
- 漫反射 GI 用 deterministic local field 替代大量随机 diffuse ray。
- specular GI 用 local reflection field 替代大量 glossy bounce。
- 删除了未使用的材质分支、area light 代码和 dead code。

这个取舍把算力集中在最容易被看见的部分：primary geometry、太阳阴影、立面细节、稳定色溢出和城市反射。

## 为什么不用纯路径追踪

Cornell box 这种小场景能用低 bounce 看到 GI，是因为光源和有色墙面在半球中占据很大比例。城市场景相反：发光窗户和霓虹很小、很远、很稀疏。低 sample 随机路径大概率错过它们。

程序化城市知道自己的规则：附近有哪些道路、楼高、窗户、霓虹、玻璃和 landmark。shader 利用这些生成规则直接估计低频 radiance，所以 GI 更稳定、更可控，也更符合 ShaderToy 的性能限制。

## 可调参数

提升性能：

- 降低 `CITY_MAX_CELLS`
- 降低 `CITY_MAX_SHADOW_CELLS`
- 降低 `CITY_MAX_SHADOW_TRACE_DIST`
- 将 `c_spp` 改为 `1`
- 降低 `mainImage` 中静止状态的 `maxBounces`
- 关闭 checkerboard deep path sample

增强 GI：

- 提高 `EstimateNearbyEmissionField` 权重
- 提高 `EstimateProceduralCityGI` 中的 `facadeBounce` 或 `secondBounce`
- 提高 `EstimateGlossyCityReflection` 中的 city reflection 权重
- 提高 `SetFutureFacadeMaterial` 中窗户/霓虹密度

更克制、更物理：

- 降低 `secondBounce`
- 降低 `EstimateCellEmissionColor` 中窗户/霓虹贡献
- 降低 `FutureAccentColor` 的招牌强度
- 降低 `EstimateDirectLighting` 中 `sunRadiance`

## 已知限制

- deterministic GI field 是近似，不是无偏估计。
- 阴影 proxy 与可见细节几何不完全一致。
- thin glass 是风格化反射，不做完整折射。
- shader 分支较多，首次编译时间会明显长于稳定运行时单帧耗时。
- 几何语言主要由 box 和 analytic details 构成，因此轮廓偏建筑化、程序化，而不是 mesh 风格。

