# 独立 Images API 接入

## 配置

需要 Python 3.10+、`requests`、`Pillow`；Python 3.10 还需 `tomli`（已写入 requirements.txt）。无需 OpenAI SDK、MCP 或内置工具。可使用独立接口配置，也可默认复用 Codex 当前第三方 provider 的 API key 配置。

JSON 参考 [config.example.json](config.example.json)，通过子命令后的 `--config config.json` 使用。支持 `base_url`、`api_key_env`、`api_key`、`model`、`timeout`。建议保持 key 在环境变量中，不分享含真实 key 的文件。

| 配置项 | 优先级，从高到低 |
| --- | --- |
| URL | `--base-url` → `IMAGE_API_BASE_URL` → `OPENAI_BASE_URL` → JSON `base_url` → Codex 当前第三方 provider 的 `base_url` |
| Key | 显式 `--api-key*` → JSON 指定 `api_key_env` → `IMAGE_API_KEY` → `OPENAI_API_KEY` → JSON `api_key` → URL 匹配的 Codex provider API key |
| Model | `--model` → `IMAGE_API_MODEL` → JSON `model` → `gpt-image-2` |
| Timeout | `--timeout` → JSON `timeout` → 600 秒 |

`--api-key`、`--api-key-file`、`--api-key-env` 互斥。显式指定变量名（命令行或 JSON）但变量为空时会报错，不会换其他 key。JSON 已指定 `api_key_env` 时，删除这一项才启用普通 key 回退顺序。

### Codex 默认配置

- 读取 `$CODEX_HOME/config.toml`；未设置 `CODEX_HOME` 时读取 `~/.codex/config.toml`。只选择当前 `model_provider`，不遍历其他 provider 的密钥。
- 如果文件设置了默认 `profile`，优先应用同目录 `<profile>.config.toml`；没有该文件时兼容 `[profiles.<profile>]`。其他 Codex 进程临时使用的 `--profile`、`-c` 或项目配置无法从全局文件推断；这种情况使用显式接口配置。
- 仅在选中 provider 显式配置第三方 `base_url` 时回退；不从 OpenAI/ChatGPT 官方域名配置导入凭据。
- `requires_openai_auth=true`：读取同目录 `auth.json` 的 `OPENAI_API_KEY`，并忽略 provider 的 `env_key`。`auth_mode` 为 ChatGPT 或只有 OAuth/access/refresh token 时不复用。
- 其他认证方式：优先使用 provider 的 `env_key` 指定的环境变量；未配置 `env_key` 时读取 `experimental_bearer_token`。指定的 provider 环境变量为空时不改用旧 auth.json 密钥。
- URL 与 key 分别补齐，但 Codex key 只补给相同 API 前缀（含路径）；显式 URL 不匹配时需显式提供对应 key。
- 不修改 Codex 配置，不把密钥写入输出、报告或进程参数。显式 URL 和 key 已齐全时，不读取 Codex 配置。

URL 通常为 `https://host/v1`。脚本保留用户前缀，拼接 `/models`、`/images/generations` 或 `/images/edits`，不会自动补 `/v1`。

## HTTP 协议

共同认证头：`Authorization: Bearer YOUR_API_KEY`。

生成：`POST {base_url}/images/generations`，JSON：

```json
{
  "model": "gpt-image-2.5-flare",
  "prompt": "完整入镜的玩具机器人，真实透明背景，干净边缘",
  "background": "transparent",
  "output_format": "png",
  "size": "1024x1024",
  "quality": "auto",
  "n": 1
}
```

修图：`POST {base_url}/images/edits`，`multipart/form-data`，文本字段同上，单张文件用 `image`，多张用重复 `image[]`，可选 `mask`。不要把路径字符串当图片内容，不要手工设置 multipart boundary。

```bash
curl "$IMAGE_API_BASE_URL/images/edits" \
  -H "Authorization: Bearer $IMAGE_API_KEY" \
  -F "model=gpt-image-2.5-sunburst" \
  -F "image=@input.png" \
  -F "prompt=只把外壳改成绿色，保留形状和蓝色眼睛，透明背景" \
  -F "background=transparent" \
  -F "output_format=png"
```

取 `data[i].b64_json`，Base64 解码成文件；脚本也支持返回 `data[i].url`，下载时不发送 provider 认证头。脚本不打印 Base64 或认证头，返回 URL 应及时保存。

## 参数与输入

| 参数 | 说明 |
| --- | --- |
| `--model` | provider 准确 ID，重点覆盖 `gpt-image-2` 和两个 `gpt-image-2.5-*` |
| `--quality` | 默认 `auto`；`low/medium/high/auto`，2.5 另有 `xhigh/max` |
| `--size` | 默认 `auto`，或 `WIDTHxHEIGHT` |
| `--background` | 省略或 `auto/opaque/transparent` |
| `--output-format` | 默认 `png`，或 `jpeg/webp` |
| `--output-compression` | 0～100，仅 JPEG/WebP |
| `--n` | 1～10，同一 prompt 的变体，网关可能进一步限制 |
| `--image` | 可重复，最多 16 张，每张小于 50 MB，PNG/JPEG/WebP |
| `--mask` | 第一张图的同尺寸同格式 alpha 蒙版；推荐 PNG |
| `--prompt-file` | UTF-8，与 `--prompt` 互斥 |
| `--strict-size` | 实际尺寸不一致时返回退出码 2，不自动缩放 |

Image 2/2.5 尺寸约束：宽高为 16 的倍数；最长边≤3840；长宽比≤3；像素数 655360～8294400。常用 `1024x1024`、`1536x1024`、`1024x1536`、`2048x2048`、`3840x2160`。超过 `2560x1440` 像素的分辨率属于实验范围。服务端可能不严格执行尺寸，需读实际文件。

`gpt-image-2` 输入始终按高保真处理，不发送 `input_fidelity`；本脚本不暴露此参数，避免盲目套用旧模型参数。

## 验证与来源

实测记录见 [validation.md](validation.md)。模型列表和 `data[].model` 是 provider 声明，不能独立证明底层上游模型。未测试参数和其他网关不描述为已验证。

创建时阅读 Codex 内置 `imagegen/SKILL.md` 及 API/提示词指引，并参考官方文档；本 skill 为独立实现，不导入或修改内置脚本。

- [OpenAI Image generation](https://developers.openai.com/api/docs/guides/image-generation)
- [Responses image generation tool](https://developers.openai.com/api/docs/guides/tools-image-generation)：用于核对 API 边界，本脚本使用直接 Images API。

2026-10-24 获取的官方文档已描述 Image 2.5 透明输出；Responses 工具文档将 Image 2 透明输出标为 preview。本机旧版 skill 的限制更保守，使用时以指定服务端及实际 alpha 检查为准。
