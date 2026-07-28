# 技術概要

この文書では、最終版 `FutureCity_BufferA.glsl` を、プロシージャル都市生成、パストレーシング、グローバルイルミネーション、性能最適化の 4 つの観点から説明します。

## コードマップ

主な構成は次の通りです。

- 定数、材質 ID、hit record：ファイル冒頭
- hash、noise、FBM：`Hash12`、`Hash22`、`Noise2`、`FBM`
- レンガ材質：`BrickPattern`、`BrickColor`
- 都市レイアウト：`CitySpineMask`、`CityLandmarkMask`、`BuildingArchetype`
- 建物形状：`GetFutureBuildingBounds`
- シャドウ/GI proxy：`GetFutureBuildingShadowBounds`
- ファサード材質：`SetFutureFacadeMaterial`
- 主トラバース：`TraceProceduralCity`
- シャドウ/proxy トラバース：`TraceProceduralCityOcclusion`
- BSDF とサンプリング：`EvalBRDF`、`SampleBSDF`
- 都市 GI：`EstimateProceduralCityGI`
- 都市反射：`EstimateCitySpecularField`、`EstimateGlossyCityReflection`
- 太陽直接光：`EstimateDirectLighting`
- パストレーシングループ：`GetColorForRay`
- カメラ、サンプリング、時間蓄積：`mainImage`

## プロシージャル都市生成

都市は 2D の city cell から生成されます。ワールド空間の `xz` 座標を `CITY_CELL_SIZE` で割って `ivec2 cell` を得て、その cell の hash から都市のほぼすべての判断を行います。これにより、mesh、texture、都市データ表なしで、安定して再現可能な大規模都市を生成できます。

### 道路と広場

`IsMainRoadCell`、`IsSecondaryRoadCell`、`IsRoadCell` は道路ネットワークを生成します。メイン道路は 8 cell ごとに現れ、サブ道路はオフセット付きで 4 cell ごとに現れます。`IsPlazaCell` は中心部とまれな cell に広場を生成し、道路 cell とは重ならないようにします。

この構造は DDA トラバースに開けた廊下を作り、都市が単なるランダムな箱の壁になることを防ぎます。デフォルト視点でも中央の街路峡谷が読みやすくなります。

### 都市構図マスク

都市は完全ランダムではなく、2 つの低周波マスクで構成されています。

- `CitySpineMask`：中央の強い街路軸と弱い横軸を作ります。
- `CityLandmarkMask`：複数の高層ランドマーククラスターを作ります。

これらのマスクは、建物の高さ、ガラス率、ネオン密度、窓密度、細長さ、材質傾向に影響します。その結果、均一なノイズではなく、階層のある skyline が得られます。

### 建物 archetype

`BuildingArchetype` は非道路 cell をいくつかの抽象的な建物タイプに分類します。

- warm block
- stepped podium
- dark slab
- glass needle
- brick/composite tower

`GetFutureBuildingBounds` は archetype、spine、landmark、hash を使って、podium/tower bounds、高さ、footprint、細長い軸、style を計算します。可視ジオメトリの中心は analytic box で、屋上設備、spire、beacon が少量追加されます。

### ファサード材質

`SetFutureFacadeMaterial` は box への hit を局所的なファサード材質に変換します。

- 窓は wall-space grid と `sdBox2D` から生成
- 窓光は warm/cool emissive
- レンガは mortar、per-brick variation、dirt FBM を含む
- 金属パネルは構造線と panel gap で駆動
- ガラスカーテンウォールは高層、spine、landmark で増える
- 木質アクセントは warm/stepped facade に寄る
- ネオンサインは 2D sign-frame SDF で生成

明示的な材質タイプは diffuse、GGX、thin glass の 3 種類に絞っています。見た目の金属、ガラス、レンガ、木の違いは、albedo、roughness、metallic、emissive、決定的な反射フィールドによって表現されます。

## ジオメトリトラバース

主可視性は `TraceProceduralCity` が担当します。`xz` 平面上の有界 2D DDA です。

1. ray の始点から現在 cell を求める。
2. 次の x/z cell 境界までの距離を計算する。
3. 現在 cell 内の道路、広場、建物、屋上、細部だけをテストする。
4. 近い境界へ進んで次の cell に移動する。
5. `CITY_MAX_CELLS` と `CITY_MAX_TRACE_DIST` で上限を設ける。

これが、都市を大規模に見せながら処理を有限に保つ主要な理由です。shader は都市を保存せず、無限探索もしません。

シャドウと GI クエリには `TraceProceduralCityOcclusion` を使います。これは短い DDA と `GetFutureBuildingShadowBounds` の簡略 proxy box を使います。可視ジオメトリは詳細なまま、シャドウ/GI クエリを軽くできます。

## パストレーシング

`GetColorForRay` が中心ループです。各 ray は次の流れで処理されます。

1. 最も近い都市 hit を探す。
2. hit がなければ sky を返す。
3. thin glass に hit した場合、sky と都市反射フィールドで直接 shading。
4. emissive に hit した場合、emission を加えて終了。
5. 選択された bounce に shadowed sun lighting を追加。
6. primary hit に procedural city GI と glossy city reflection を追加。
7. BSDF を sample してパスを継続。

BSDF は次をサポートします。

- diffuse の cosine hemisphere sampling
- GGX の diffuse/specular 混合 sampling
- Schlick Fresnel
- GGX distribution と Smith geometry
- thin glass 専用の高速 shading

提出版の真のパス深度は控えめです。通常の静止サンプルは 2 surface hits、時間 checkerboard の一部だけ 3 surface hits を使います。これにより、secondary sun lighting と少量の emissive path hit を保ちつつ、全サンプルで深いパスを払う必要を避けます。

## グローバルイルミネーション

この shader の GI は、真のパス輸送と決定的なプロシージャル irradiance の 2 層です。

### 真のパス輸送

真のパス部分は以下を扱います。

- primary visibility
- 太陽直接光と hard shadow
- secondary path continuation
- 一部の secondary hit での shadowed sun
- ランダムパスが発光窓やネオンに当たった時の indirect emission
- GGX glossy continuation

これにより、レンダラは物理ベースの light transport とつながっています。ただし `c_spp = 2` では、小さな窓やネオンにランダムパスが当たる確率は低いです。そのため、間接光を安定して見せるためにプロシージャル GI フィールドを追加しています。

### 拡散都市 irradiance field

`EstimateProceduralCityGI` は複数の安定した項を合成します。

- `EstimateRoadOpenness`：近くの道路/広場の開け具合を推定し、開けた場所には sky と road bounce を増やす。
- `EstimateBuildingOcclusion`：近くの proxy building の高さと距離から街路峡谷の遮蔽を推定。
- sky visibility：法線、高さ、building occlusion、road openness から計算。屋上は明るく、低い壁面は暗くなる。
- warm ground bounce：太陽に照らされた道路/広場から近い壁へ暖色の反射を加える。
- `EstimateNearbyEmissionField`：窓、ネオン、道路、広場の局所的な色移りを推定。
- `EstimateFacadeBounceField`：近傍ファサード間の低周波反射を推定。色は同じプロシージャル建物規則から得る。
- cheap second bounce：遮蔽の強い街路峡谷で多重反射感を増やす。

合成後は surface albedo を掛け、エネルギーが暴走しないように clamp します。

### 金属とガラスの都市反射フィールド

低 sample のパストレーシングだけでは、金属やガラスは sky か noise しか映しにくくなります。そのため shader は `EstimateCitySpecularField` を使います。

反射方向に対して近傍 cell から次のエネルギーを推定します。

- road glow
- plaza glow
- lit window field
- neon color
- tower height/density
- far city horizon color

`EstimateGlossyCityReflection` は Fresnel、roughness、metallic に基づいてこのフィールドを GGX 材質へ加えます。`ShadeThinGlass` も同じ都市反射フィールドを使い、sky reflection と sun glint を混ぜます。

これは厳密な不偏反射パストレーシングではなく、低 sample の ShaderToy 都市でもガラスと金属反射を読みやすくするための決定的近似です。

## パストレーシング最適化

主な最適化は次の通りです。

- `c_spp = 2` でフレームあたりのサンプル数を抑える。
- カメラ移動中は 1 surface hit のみ。
- 静止時は temporal accumulation を使う。
- checkerboard の一部だけ 3 hit の深いパスを使う。
- 通常の静止サンプルは 2 hit。
- 太陽は大きな area light ではなく、単一の方向 shadow ray。
- shadow ray は proxy bounds と短い DDA を使う。
- diffuse GI は多数のランダム ray ではなく deterministic local field。
- specular GI は多数の glossy bounce ではなく local reflection field。
- 未使用の材質分岐、area light、dead code を削除済み。

計算コストは、primary geometry、太陽シャドウ、ファサード詳細、安定した色移り、都市反射など、視覚的に目立つ部分へ集中させています。

## なぜ純粋なパストレーシングではないのか

Cornell box のような小さいシーンでは、光源や色付き壁が半球内で大きな割合を占めるため、低 bounce でも GI が見えます。都市シーンでは逆に、発光窓やネオンは小さく、遠く、疎です。低 sample のランダムパスはほとんどそれらを外します。

この shader は、都市を生成する規則をそのまま照明推定にも使います。近くに道路、高い建物、窓、ネオン、ガラス、landmark があることを shader 自身が知っているため、低周波 radiance を直接推定できます。そのため GI は安定し、制御しやすく、ShaderToy の性能制約にも合います。

## 調整ポイント

高速化したい場合：

- `CITY_MAX_CELLS` を下げる
- `CITY_MAX_SHADOW_CELLS` を下げる
- `CITY_MAX_SHADOW_TRACE_DIST` を下げる
- `c_spp` を `1` にする
- `mainImage` の静止時 `maxBounces` を下げる
- checkerboard deep path sample を無効化する

GI を強めたい場合：

- `EstimateNearbyEmissionField` の重みを上げる
- `EstimateProceduralCityGI` の `facadeBounce` や `secondBounce` を上げる
- `EstimateGlossyCityReflection` の city reflection を上げる
- `SetFutureFacadeMaterial` の窓/ネオン密度を上げる

より落ち着いた物理寄りの見た目にしたい場合：

- `secondBounce` を下げる
- `EstimateCellEmissionColor` の窓/ネオン寄与を下げる
- `FutureAccentColor` のサイン強度を下げる
- `EstimateDirectLighting` の `sunRadiance` を下げる

## 既知の制限

- deterministic GI field は近似であり、不偏推定ではありません。
- shadow proxy は可視詳細ジオメトリと完全には一致しません。
- thin glass は完全な屈折ではなく、スタイライズされた反射です。
- shader は分岐が多いため、初回コンパイル時間は安定時のフレーム時間より長くなります。
- 形状は box と analytic details が中心なので、silhouette は建築的でプロシージャルな表現になります。

