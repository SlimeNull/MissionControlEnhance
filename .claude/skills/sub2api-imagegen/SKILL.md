---
name: sub2api-imagegen
description: 使用 URL 和 API key 调用兼容 OpenAI Images API 的生图、参考图生成、修图、蒙版编辑及透明 PNG/WebP 输出；未配置接口时默认读取 Codex 当前第三方 provider 的 URL 和 API key。适用于 sub2api 等网关的 gpt-image-2、gpt-image-2.5-flare 和 gpt-image-2.5-sunburst，不依赖内置生图工具或 MCP。
---

# 通过 URL 和 API key 生图与修图

可复制到支持 `SKILL.md` 的 agent 客户端使用，也可直接运行 Python 脚本。依赖 Python 3.10+、`requests`、`Pillow` 和兼容 Images API 的服务。首次运行：

```sh
python -m pip install -r <skill目录>/scripts/requirements.txt
```

下文以 `<CLI>` 表示本 skill 中 `scripts/image_api.py` 的实际路径。从任意目录运行时使用其绝对路径；输入输出路径相对于运行目录。

## 配置

未提供 URL 或 API key 时，脚本默认从 `$CODEX_HOME/config.toml`（未设置时为 `~/.codex/config.toml`）读取当前选中的第三方 `model_provider`。URL 使用该 provider 的 `base_url`；密钥按其认证方式读取 `env_key` 指定的环境变量、`experimental_bearer_token`，或在 `requires_openai_auth=true` 时读取同目录 `auth.json` 的 `OPENAI_API_KEY`。仅复用 API key，不使用 ChatGPT 登录 token，也不需要另写包装脚本或先询问用户提供已有配置。

命令行、环境变量和 `--config` 的显式配置优先，Codex 仅补齐缺失项；补用 Codex 密钥时 URL 必须与该 provider 匹配。若没有匹配的第三方配置，再请用户设置接口。默认 profile 和认证细节见 [references/api.md](references/api.md)。

也可以单独设置两个环境变量，不要把真实 key 写进 skill、提示词或聊天：

```powershell
$env:IMAGE_API_BASE_URL = "https://your-provider.example/v1"
$env:IMAGE_API_KEY = "本地填写你的 API key"
```

```bash
export IMAGE_API_BASE_URL="https://your-provider.example/v1"
export IMAGE_API_KEY="本地填写你的 API key"
```

URL 是 API 前缀，通常包含 `/v1`，不包含具体接口路径。脚本不会自动补 `/v1`。也支持 `OPENAI_BASE_URL` / `OPENAI_API_KEY`、`--base-url`、`--api-key-file` 或 `--config`，详见 [references/api.md](references/api.md)。

运行 `python <CLI> models --images-only` 查看准确模型名；列表只证明可发现，最终仍以调用结果为准。

## 选择操作与模型

- 新图：`generate`。
- 修改现有图：`edit --image 原图`；第一张是编辑目标，后续参考图使用重复的 `--image`，并在 prompt 中标注用途。
- 根据参考图创作新图：技术上走 `edit` 上传参考图，在 prompt 中明确“创建新构图”，说明每张参考图的角色。
- 局部编辑：`edit --image 原图 --mask 蒙版`。蒙版与第一张图尺寸、格式一致，包含 alpha；透明区域允许修改，实色区域应保留。蒙版是引导，不能承诺逐像素不变。
- 透明新图或抠图：`--background transparent --output-format png`，prompt 同时要求真实透明背景、保留主体和边缘；WebP 也可，JPEG 不支持 alpha。

默认 `gpt-image-2`，用户指定模型时保留原选择。Image 2.5 的准确 ID 是 `gpt-image-2.5-flare` 和 `gpt-image-2.5-sunburst`：前者可用于日常生成，后者可用于精细编辑。不要把口语 `gptimage2` 或 `image2.5` 直接当 API model，也不要默默切换模型。

`gpt-image-2`、两个 2.5 模型均可请求 `background=transparent`；当前服务是否实际返回透明像素由检查结果判定。内置旧版 imagegen skill 中“Image 2 API 不支持透明”的限制不能直接套用到当前网关。

## 调用示例

生图：

```sh
python <CLI> generate --model gpt-image-2 --prompt "一只红色玩具机器人，蓝色圆眼睛，完整入镜，简洁产品摄影，无文字水印" --size 1024x1024 --quality low --out output/robot.png
```

生成透明素材：

```sh
python <CLI> generate --model gpt-image-2.5-flare --prompt "一只完整入镜的红色玩具机器人，真实透明背景，干净的主体边缘，无地面和投影，无文字水印" --background transparent --output-format png --out output/robot-cutout.png
```

修图并保留透明通道：

```sh
python <CLI> edit --model gpt-image-2.5-sunburst --image input/robot.png --prompt "只把机器人红色外壳改成绿色，保持造型、姿势、蓝色眼睛、金属关节和构图不变，背景真实透明" --background transparent --out output/robot-green.png
```

局部编辑与多图合成：

```sh
python <CLI> edit --image input/scene.png --mask input/mask.png --prompt "只修改蒙版透明区域，把杯子改成蓝色陶瓷杯；保持其他主体、文字和光照不变" --out output/scene-edited.png
python <CLI> edit --image input/scene.png --image input/product.png --prompt "图1是目标场景，图2是需要放入的产品；将图2产品放在图1桌面上，匹配透视与照明，保留场景其他内容" --out output/composite.png
```

`--prompt-file` 接受 UTF-8 长提示词。`--n` 产生同一提示词的多个变体；不同素材分别调用。参数及 HTTP 协议见 [references/api.md](references/api.md)，提示词保留约束见 [references/prompting.md](references/prompting.md)。

## 检查与交付

1. 查看 JSON 报告，再用所在客户端的图片查看能力目视检查主体、文字、构图、编辑保留项及边缘。无图片工具时至少检查文件和报告，并说明未目视核验。
2. 脚本检查实际格式、尺寸、alpha 极值和透明像素。网关可能调整尺寸，不要照抄请求参数作为交付尺寸。必须精确尺寸时使用 `--strict-size`，必要时按用户目标本地缩放或补画布，说明处理方式。
3. 透明输出需包含可见内容及非实色 alpha；检查透明像素比例，并在浅色、深色底上查看。仅有 RGBA 模式、黑底、白底或棋盘格图案不能证明透明；空白全透明图也不能交付。
4. 默认不覆盖原图。输出旁保存 `.png.json` 等报告，含提示词、请求参数、实际指标和用量，不含 key。交付最终路径并说明模型、实际尺寸及材料性偏差。
5. 退出码：`0` 成功，`1` 请求/输入失败，`2` 返回图未满足透明、严格尺寸或张数条件。退出码 `2` 仍保存原图和报告供检查，不能视为完成。

`python <CLI> inspect --image output/robot-cutout.png` 可离线检查。`--dry-run` 验证输入并查看脱敏请求，无需 key、不会联网。`--force` 明确允许覆盖。

## 故障边界

脚本直接调用 `/images/generations` 和 `/images/edits`，不依赖 Responses image tool。另一个网关若只开放 `/responses`，需按其协议接入，本脚本不假装支持。

生成请求不自动重试，也不自动换模型或移除透明要求。超时后先查 provider 请求记录，再决定是否重试，避免重复计费。默认读取超时 600 秒，连接超时 30 秒，可用 `--timeout` 调整。详细实测边界见 [references/validation.md](references/validation.md)。
