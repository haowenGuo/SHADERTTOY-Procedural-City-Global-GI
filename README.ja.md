# SHADERTTOY-程序化城市-全局GI

HPG 2026 Student Competition のテーマ **Vast Proceduralism and Global Illumination** に向けた ShaderToy 作品です。

ShaderToy リンク：https://www.shadertoy.com/view/sXBGRw

言語：[English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

![Preview](assets/preview.png)

## 概要

`SHADERTTOY-程序化城市-全局GI` は、2 パス構成の ShaderToy プロシージャル都市 GI 実験です。道路、広場、高架レール、低層ポディウム、高層ビル、ガラスのタワー、暗い金属スラブ、レンガ/複合ファサード、ネオンサイン、暖色/寒色の窓光、金属パネル、ガラスカーテンウォール、木質アクセントを、すべて実行時の決定的な cell hash から生成します。

レンダラはハイブリッド GI 方式です。少量の確率的パストレーシングで primary hit、太陽の直接光、ハードシャドウ、GGX 材質、薄いガラス反射、一部の secondary bounce、emissive へのヒットを扱い、決定的な都市 irradiance field で空の可視性、道路反射、ファサード間の反射、窓/ネオンの色移り、金属/ガラスの都市反射を安定化します。

## ファイル構成

- `FutureCity_BufferA.glsl`  
  メインの ShaderToy Buffer A。プロシージャル都市、パストレーサ、GI フィールド、カメラ状態、時間蓄積を含みます。
- `FutureCity_Image.glsl`  
  表示パス。Buffer A の先頭 4 ピクセルに保存した状態を画面外へずらし、最終画像を表示します。
- `render_future_city_offline.js`  
  プレビュー用の任意のローカル WebGL2 レンダラです。
- `assets/preview.png`  
  `640 x 360` のローカル検証プレビューです。
- `docs/TECHNICAL_OVERVIEW.md`  
  英語の技術解説です。
- `docs/TECHNICAL_OVERVIEW.zh-CN.md`  
  中国語の技術解説です。
- `docs/TECHNICAL_OVERVIEW.ja.md`  
  日本語の技術解説です。
- `submission/`  
  コンペ提出用メモとメール草稿です。

## ShaderToy 設定

ShaderToy では 2 つのパスを使います。

- `Buffer A`：`FutureCity_BufferA.glsl` を貼り付ける
- `Image`：`FutureCity_Image.glsl` を貼り付ける

チャンネル設定：

- Buffer A `iChannel0`：Buffer A 自身
- Buffer A `iChannel1`：Keyboard
- Image `iChannel0`：Buffer A

Buffer A の先頭 4 ピクセルは永続状態として使われます。

- `(0,0)`：カメラ位置
- `(1,0)`：yaw、pitch、camera moved flag
- `(2,0)`：マウス位置と押下状態
- `(3,0)`：累積 sample 数

Image パスはこれらの状態ピクセルを可視領域から外して表示します。

## 操作

- `W/S`：前進/後退
- `A/D`：左右移動
- `E/Q`：上下移動
- マウスドラッグ：視点回転
- `Shift`：高速移動
- `R`：カメラリセット

## 現在のレンダリング設定

- 1 フレームあたりのサンプル数：`c_spp = 2`
- カメラ移動中：1 surface hit
- 静止時の通常サンプル：2 surface hits
- 静止時の深いサンプル：時間 checkerboard の一部だけ 3 surface hits
- 直接光：シャドウレイ付きの方向性太陽光 1 本
- パス継続：一部の secondary hit でも太陽直接光を評価
- 主トラバース：有界な 2D DDA による city cell traversal
- シャドウトラバース：短い DDA と簡略化された建物 proxy bounds
- 時間蓄積：カメラ静止中に Buffer A で蓄積

## GI の概要

GI は 3 つの層に分かれています。

1. **明示的なパストレース輸送**  
   primary visibility、太陽シャドウ、GGX 反射、薄いガラス、少量の secondary stochastic bounce を追跡します。

2. **プロシージャルな拡散 irradiance field**  
   近傍 cell から空の可視性、道路/広場の反射、ファサード間の反射、窓/ネオンの色移り、街路峡谷の遮蔽、cheap second bounce を推定します。

3. **プロシージャルな specular/reflection field**  
   金属とガラスは決定的な都市反射フィールドをサンプルし、低い sample count でも近くのネオン、明るい窓、道路、広場、遠景 skyline を反射できます。

これは完全な不偏パストレーシングではなく、ShaderToy の制約下で見える GI を安定して表現するための制御可能な近似です。小さな窓やネオンにランダムパスが偶然当たることへ依存しません。

## ローカル検証

任意の renderer は Playwright とローカル Chrome/WebGL2 を使います。

```powershell
cd FutureCity_GitHub_Submission
npm install
$env:WIDTH="640"
$env:HEIGHT="360"
$env:FRAMES="4"
$env:DURATION_SECONDS="1"
$env:MODE="frames"
$env:FRAMES_DIR="FutureCity_frames"
node .\render_future_city_offline.js
```

提出 shader のローカル検証結果：

- 解像度：`640 x 360`
- テスト：4 フレーム
- ブラウザ：Chrome/WebGL2 through ANGLE D3D11
- shader コンパイル後のレンダリング時間：約 `84.6 ms/frame`

大きなプロシージャル shader の初回コンパイルは、安定時のフレーム時間より長くなることがあります。

## コンペ提出ファイル

`submission/` フォルダには以下が含まれます。

- `FutureCity_SubmissionNotes.md`：設定、GI 概要、性能メモ、チェックリスト
- `FutureCity_SubmissionEmail.md`：英語メール本文草稿
- `FutureCity_SubmissionEmail.eml`：メール形式の草稿

公式提出先：

`studentcompetition@highperformancegraphics.org`
