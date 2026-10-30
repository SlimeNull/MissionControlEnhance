#!/usr/bin/env python3
"""通过兼容 Images API 的 URL/API key 生图、修图并检查实际输出。"""
from __future__ import annotations

import argparse
import base64
from contextlib import ExitStack
from datetime import datetime, timezone
from io import BytesIO
import json
import mimetypes
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit

import requests
from PIL import Image

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    import tomli as tomllib


class ImageAPIError(Exception):
    pass


def emit(value, *, error=False):
    print(json.dumps(value, ensure_ascii=False, indent=2), file=sys.stderr if error else sys.stdout)


def load_json(path):
    value = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    if not isinstance(value, dict):
        raise ImageAPIError('配置文件必须是 JSON 对象。')
    return value


def validate_base_url(base):
    if not isinstance(base, str):
        raise ImageAPIError('base URL 必须是字符串。')
    base = base.rstrip('/')
    u = urlsplit(base)
    if u.scheme not in ('http', 'https') or not u.netloc or u.username or u.password or u.query or u.fragment:
        raise ImageAPIError('base URL 必须是无凭据、无查询参数的 http(s) API 前缀，例如 https://host/v1。')
    if re.search(r'/(?:images/(?:generations|edits)|responses|models)$', u.path):
        raise ImageAPIError('请提供 API 前缀（通常以 /v1 结尾），不要填写具体接口路径。')
    return base


def load_codex_toml(path):
    try:
        return tomllib.loads(path.read_text(encoding='utf-8-sig'))
    except (OSError, ValueError):
        # TOML 错误可能包含原始配置片段，不把它们写入聊天或报告。
        raise ImageAPIError(f'无法读取或解析 Codex 配置：{path}') from None


def codex_defaults(*, need_key):
    """仅复用当前选中的第三方 provider；不读取 ChatGPT 登录 token。"""
    codex_home = Path(os.getenv('CODEX_HOME') or Path.home() / '.codex').expanduser()
    config_path = codex_home / 'config.toml'
    if not config_path.is_file():
        return None, None
    config = load_codex_toml(config_path)
    providers = config.get('model_providers', {})
    provider_id = config.get('model_provider', 'openai')
    # 尊重配置文件选中的默认 profile；不猜测其他进程的临时 CLI 覆写。
    profile_name = config.get('profile')
    if profile_name:
        profile_path = codex_home / f'{profile_name}.config.toml'
        profile = (load_codex_toml(profile_path) if profile_path.is_file()
                   else config.get('profiles', {}).get(profile_name))
        if not isinstance(profile, dict):
            raise ImageAPIError('Codex 配置选中的 profile 不存在。')
        provider_id = profile.get('model_provider', provider_id)
        providers = dict(providers)
        for name, values in profile.get('model_providers', {}).items():
            providers[name] = {**providers.get(name, {}), **values}
    provider = providers.get(provider_id, {})
    base = provider.get('base_url')
    if not base:
        return None, None
    base = validate_base_url(base)
    host = (urlsplit(base).hostname or '').lower()
    if any(host == domain or host.endswith('.' + domain) for domain in ('openai.com', 'chatgpt.com')):
        return None, None
    if not need_key:
        return base, None
    if provider.get('requires_openai_auth'):
        auth_path = codex_home / 'auth.json'
        if not auth_path.is_file():
            return base, None
        try:
            auth = load_json(auth_path)
        except (OSError, ValueError, ImageAPIError):
            raise ImageAPIError(f'无法读取 Codex API key：{auth_path}') from None
        # 即使 auth.json 留有旧 API key，也不能复用当前 ChatGPT 登录模式。
        key = auth.get('OPENAI_API_KEY') if auth.get('auth_mode') in (None, 'apikey', 'api_key') else None
    elif provider.get('env_key'):
        key = os.getenv(provider['env_key'])
    else:
        key = provider.get('experimental_bearer_token')
    return base, key if isinstance(key, str) and key.strip() else None


def same_api_base(left, right):
    def identity(base):
        u = urlsplit(base)
        port = u.port or (443 if u.scheme == 'https' else 80)
        return u.scheme.lower(), (u.hostname or '').lower(), port, u.path.rstrip('/')
    return identity(left) == identity(right)


def resolve(args):
    config = load_json(args.config) if args.config else {}
    base = args.base_url or os.getenv('IMAGE_API_BASE_URL') or os.getenv('OPENAI_BASE_URL') or config.get('base_url')
    key_env = args.api_key_env or config.get('api_key_env')
    explicit_key = args.api_key_file is not None or args.api_key is not None or bool(key_env)
    if args.api_key_file is not None:
        key = Path(args.api_key_file).read_text(encoding='utf-8-sig').strip()
    elif args.api_key is not None:
        key = args.api_key
    elif key_env:
        key = os.getenv(key_env)
    else:
        key = os.getenv('IMAGE_API_KEY') or os.getenv('OPENAI_API_KEY') or config.get('api_key')
    if explicit_key and not key:
        raise ImageAPIError('显式指定的 API key 来源为空，请检查参数、key 文件或环境变量。')
    if base:
        base = validate_base_url(base)
    if not base or not key:
        codex_base, codex_key = codex_defaults(need_key=not key)
        if not base:
            base = codex_base
        # 不把 Codex provider 的密钥发送到显式指定的另一个 API 地址。
        if not key and base and codex_base and same_api_base(base, codex_base):
            key = codex_key
    if not base:
        raise ImageAPIError('URL 缺失，且 Codex 未配置可复用的第三方 provider。请设置 IMAGE_API_BASE_URL 或 --base-url。')
    if not key and not getattr(args, 'dry_run', False):
        raise ImageAPIError('API key 缺失，且当前 URL 没有匹配的 Codex 第三方 API key。请设置 IMAGE_API_KEY 或 --api-key-file。')
    if key and not isinstance(key, str):
        raise ImageAPIError('API key 必须是字符串。')
    if key and ('\n' in key or '\r' in key):
        raise ImageAPIError('API key 不能包含换行。')
    args.model = getattr(args, 'model', None) or os.getenv('IMAGE_API_MODEL') or config.get('model') or 'gpt-image-2'
    args.timeout = args.timeout if args.timeout is not None else config.get('timeout', 600)
    if not isinstance(args.timeout, (int, float)) or args.timeout <= 0:
        raise ImageAPIError('timeout 必须大于 0。')
    return base, key


def checked_json(response, key):
    if not 200 <= response.status_code < 300:
        # 不打印请求头，且错误正文始终脱敏、截断。
        detail = response.text[:2000].replace(key, '[REDACTED]') if key else response.text[:2000]
        hint = ''
        if response.status_code in (404, 405):
            hint = ' 请检查 API 前缀及网关是否开放 Images API。'
        elif response.status_code in (401, 403):
            hint = ' 请检查 key、账户分组及模型权限。'
        raise ImageAPIError(f'HTTP {response.status_code}: {detail}{hint}')
    try:
        data = response.json()
    except ValueError:
        raise ImageAPIError('服务端返回的不是 JSON。请检查 API URL，可能指向了网页。') from None
    if not isinstance(data, dict):
        raise ImageAPIError('API 响应必须是 JSON 对象。')
    if data.get('error'):
        detail = json.dumps(data['error'], ensure_ascii=False)[:2000]
        raise ImageAPIError(detail.replace(key, '[REDACTED]') if key else detail)
    return data


def image_info(raw):
    with Image.open(BytesIO(raw)) as im:
        im.load()
        alpha = im.convert('RGBA').getchannel('A')
        hist = alpha.histogram()
        pixels = im.width * im.height
        return {
            'format': im.format, 'mode': im.mode, 'size': list(im.size),
            'alpha_min': alpha.getextrema()[0], 'alpha_max': alpha.getextrema()[1],
            'transparent_pixels': hist[0], 'nonopaque_pixels': sum(hist[:255]),
            'fully_transparent_fraction': round(hist[0] / pixels, 6),
            'has_visible_content': sum(hist[1:]) > 0,
        }


def validate_input(path):
    p = Path(path)
    if not p.is_file():
        raise ImageAPIError(f'输入文件不存在：{p}')
    if p.stat().st_size >= 50 * 1024 * 1024:
        raise ImageAPIError(f'输入图像需小于 50 MB：{p}')
    with Image.open(p) as im:
        if im.format not in ('PNG', 'JPEG', 'WEBP'):
            raise ImageAPIError(f'输入图片需为 PNG/JPEG/WebP：{p}')
        im.verify()
    return p


def make_payload(args):
    if args.prompt_file:
        prompt = Path(args.prompt_file).read_text(encoding='utf-8-sig').strip()
    else:
        prompt = args.prompt.strip()
    if not prompt:
        raise ImageAPIError('prompt 不能为空。')
    if args.size != 'auto':
        match = re.fullmatch(r'(\d+)x(\d+)', args.size)
        if not match:
            raise ImageAPIError('size 格式为 auto 或 WIDTHxHEIGHT。')
        w, h = map(int, match.groups())
        if min(w, h) <= 0 or w % 16 or h % 16 or max(w, h) > 3840 or max(w, h) > 3 * min(w, h) or not 655360 <= w*h <= 8294400:
            raise ImageAPIError('尺寸需为 16 的倍数，长边≤3840，长宽比≤3，像素数在 655360～8294400 之间。')
    if args.quality in ('xhigh', 'max') and args.model in ('gpt-image-2', 'gpt-image-1', 'gpt-image-1.5', 'gpt-image-1-mini'):
        raise ImageAPIError('xhigh/max 仅用于支持它们的模型，例如 gpt-image-2.5-flare/sunburst。')
    if args.background == 'transparent' and args.output_format == 'jpeg':
        raise ImageAPIError('透明图请使用 PNG 或 WebP。JPEG 无法保存 alpha。')
    payload = {'model': args.model, 'prompt': prompt, 'size': args.size, 'quality': args.quality,
               'output_format': args.output_format, 'n': args.n}
    if args.background:
        payload['background'] = args.background
    if args.output_compression is not None:
        if args.output_format == 'png':
            raise ImageAPIError('output-compression 仅适用于 JPEG/WebP。')
        payload['output_compression'] = args.output_compression
    if args.command == 'edit':
        if not 1 <= len(args.image) <= 16:
            raise ImageAPIError('修图需提供 1～16 张 --image。')
        for path in args.image:
            validate_input(path)
        if args.mask:
            validate_input(args.mask)
            with Image.open(args.mask) as mask, Image.open(args.image[0]) as target:
                if mask.size != target.size or mask.format != target.format:
                    raise ImageAPIError('mask 必须与第一张输入图的尺寸及格式一致。推荐二者均使用 PNG。')
                if 'A' not in mask.getbands() and 'transparency' not in mask.info:
                    raise ImageAPIError('mask 必须包含 alpha 通道；透明区域表示允许编辑。')
    return payload


def output_paths(args):
    out = Path(args.out).expanduser()
    ext = {'png': '.png', 'jpeg': '.jpg', 'webp': '.webp'}[args.output_format]
    allowed = ('.jpg', '.jpeg') if args.output_format == 'jpeg' else (ext,)
    if not out.suffix:
        out = out.with_suffix(ext)
    if out.suffix.lower() not in allowed:
        raise ImageAPIError(f'--out 扩展名应匹配 output-format={args.output_format}。')
    paths = [out] if args.n == 1 else [out.with_name(f'{out.stem}-{i+1}{out.suffix}') for i in range(args.n)]
    report = out.with_name(out.name + '.json')
    for p in [*paths, report]:
        if p.exists() and not args.force:
            raise ImageAPIError(f'文件已存在：{p}。另选文件名或明确使用 --force。')
    return paths, report


def download_image(url, timeout):
    parsed = urlsplit(url)
    if parsed.scheme not in ('http', 'https') or not parsed.netloc or parsed.username or parsed.password:
        raise ImageAPIError('返回的图片 URL 不是合法的 http(s) 地址。')
    # 使用独立请求，不向图片地址转发 provider 的 Authorization。
    response = requests.get(url, timeout=(30, timeout))
    if not response.ok:
        raise ImageAPIError(f'下载返回图片失败：HTTP {response.status_code}')
    return response.content


def run(args):
    if args.command == 'inspect':
        emit({'path': str(Path(args.image).resolve()), **image_info(Path(args.image).read_bytes())})
        return 0
    base, key = resolve(args)
    headers = {'Authorization': 'Bearer ' + key} if key else {}
    if args.command == 'models':
        response = requests.get(base + '/models', headers=headers, timeout=(30, args.timeout), allow_redirects=False)
        data = checked_json(response, key)
        models = data.get('data', [])
        emit({'base_url': base, 'models': [m.get('id') for m in models if isinstance(m, dict) and (not args.images_only or 'image' in m.get('id', '').lower())]})
        return 0
    payload = make_payload(args)
    paths, report_path = output_paths(args)
    endpoint = '/images/generations' if args.command == 'generate' else '/images/edits'
    request_info = {'endpoint': base + endpoint, 'payload': payload}
    if args.command == 'edit':
        request_info['images'] = [str(Path(p).resolve()) for p in args.image]
        request_info['mask'] = str(Path(args.mask).resolve()) if args.mask else None
    if args.dry_run:
        emit({'dry_run': True, 'request': request_info, 'outputs': [str(p.resolve()) for p in paths]})
        return 0
    start = time.monotonic()
    # 不自动重试生成请求，避免超时后重复计费。
    if args.command == 'generate':
        response = requests.post(base + endpoint, headers=headers, json=payload, timeout=(30, args.timeout), allow_redirects=False)
    else:
        with ExitStack() as stack:
            field = 'image' if len(args.image) == 1 else 'image[]'
            files = [(field, (Path(p).name, stack.enter_context(open(p, 'rb')), mimetypes.guess_type(p)[0] or 'application/octet-stream')) for p in args.image]
            if args.mask:
                files.append(('mask', (Path(args.mask).name, stack.enter_context(open(args.mask, 'rb')), 'image/png')))
            response = requests.post(base + endpoint, headers=headers, data=payload, files=files, timeout=(30, args.timeout), allow_redirects=False)
    data = checked_json(response, key)
    items = data.get('data')
    if not isinstance(items, list) or not items:
        raise ImageAPIError('响应没有 data[] 图片结果。HTTP 成功并不表示生成了图片。')
    report = {'timestamp_utc': datetime.now(timezone.utc).isoformat(), 'request': request_info,
              'elapsed_seconds': round(time.monotonic()-start, 3), 'usage': data.get('usage'),
              'response_metadata': {k: data[k] for k in ('created', 'model', 'size', 'quality', 'background', 'output_format') if k in data},
              'outputs': [], 'warnings': [], 'validation_errors': []}
    if len(items) != args.n:
        report['validation_errors'].append(f'请求 {args.n} 张，实际返回 {len(items)} 张。')
    prepared = []
    for i, item in enumerate(items):
        if not isinstance(item, dict):
            raise ImageAPIError(f'data[{i}] 不是图片对象。')
        if item.get('b64_json'):
            try:
                raw = base64.b64decode(item['b64_json'], validate=True)
            except ValueError:
                raise ImageAPIError(f'data[{i}].b64_json 不是有效 base64。') from None
        elif item.get('url'):
            raw = download_image(item['url'], args.timeout)
        else:
            raise ImageAPIError(f'data[{i}] 缺少 b64_json/url。')
        info = image_info(raw)
        ext = {'PNG': '.png', 'JPEG': '.jpg', 'WEBP': '.webp'}.get(info['format'])
        if not ext:
            raise ImageAPIError(f'返回图片格式不受支持：{info["format"]}')
        path = paths[i] if i < len(paths) else paths[0].with_name(f'{paths[0].stem}-extra-{i+1}{ext}')
        expected_format = {'png': 'PNG', 'jpeg': 'JPEG', 'webp': 'WEBP'}[args.output_format]
        if info['format'] != expected_format:
            path = path.with_suffix(ext)
            report['warnings'].append(f'请求 {expected_format}，实际为 {info["format"]}，已按实际格式保存。')
        if args.size != 'auto' and info['size'] != list(map(int, args.size.split('x'))):
            message = f'请求尺寸 {args.size}，实际尺寸 {info["size"][0]}x{info["size"][1]}。'
            (report['validation_errors'] if args.strict_size else report['warnings']).append(message)
        if args.background == 'transparent' and not (info['transparent_pixels'] > 0 and info['has_visible_content']):
            report['validation_errors'].append(f'图片 {i+1} 未同时包含可见主体和完全透明像素，不能作为透明背景图交付。')
        prepared.append((path, raw))
        report['outputs'].append({'path': str(path.resolve()), **info,
                                  'reported_model': item.get('model'), 'reported_size': item.get('size'),
                                  'revised_prompt': item.get('revised_prompt')})
    for name in ('quality', 'background'):
        if name in payload and name in data and payload[name] != 'auto' and payload[name] != data[name]:
            report['warnings'].append(f'请求 {name}={payload[name]}，响应标注 {name}={data[name]}。')
    # 先检查所有实际输出路径，再保存，避免服务端改格式造成意外覆盖。
    for path, _ in prepared:
        if path.exists() and not args.force:
            raise ImageAPIError(f'实际输出路径已存在：{path}')
    for path, raw in prepared:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('wb' if args.force else 'xb') as f:
            f.write(raw)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open('w' if args.force else 'x', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
        f.write('\n')
    emit({'report': str(report_path.resolve()), **report})
    # 验证失败仍保留原图及报告供检查，但返回非零退出码。
    return 2 if report['validation_errors'] else 0


def bounded_int(low, high):
    def parse(value):
        result = int(value)
        if not low <= result <= high:
            raise argparse.ArgumentTypeError(f'必须在 {low}～{high} 之间。')
        return result
    return parse


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    for name in ('models', 'generate', 'edit'):
        c = sub.add_parser(name)
        c.add_argument('--config', help='UTF-8 JSON 配置文件。')
        c.add_argument('--base-url', help='例如 https://host/v1；不会自动追加 /v1。未配置时尝试 Codex 当前第三方 provider。')
        auth = c.add_mutually_exclusive_group()
        auth.add_argument('--api-key', help='支持直接传入，但建议环境变量或 key 文件以避免出现在进程参数中。')
        auth.add_argument('--api-key-file', help='只包含 API key 的 UTF-8 文本文件。')
        auth.add_argument('--api-key-env', help='存放 key 的环境变量名称。')
        c.add_argument('--timeout', type=float, help='读取超时秒数，默认 600；连接超时 30 秒。')
        if name == 'models':
            c.add_argument('--images-only', action='store_true')
            continue
        c.add_argument('--model', help='默认 gpt-image-2；也接受 provider 提供的准确模型 ID。')
        prompt = c.add_mutually_exclusive_group(required=True)
        prompt.add_argument('--prompt')
        prompt.add_argument('--prompt-file', help='UTF-8 提示词文件。')
        c.add_argument('--size', default='auto')
        c.add_argument('--quality', choices=('auto', 'low', 'medium', 'high', 'xhigh', 'max'), default='auto')
        c.add_argument('--background', choices=('auto', 'opaque', 'transparent'))
        c.add_argument('--output-format', choices=('png', 'jpeg', 'webp'), default='png')
        c.add_argument('--output-compression', type=bounded_int(0, 100))
        c.add_argument('--n', type=bounded_int(1, 10), default=1)
        c.add_argument('--out', required=True)
        c.add_argument('--strict-size', action='store_true', help='实际尺寸不符合请求时返回退出码 2。')
        c.add_argument('--force', action='store_true')
        c.add_argument('--dry-run', action='store_true', help='验证输入并输出请求摘要，不发送请求，也不需要 key。')
        if name == 'edit':
            c.add_argument('--image', action='append', required=True, help='可重复，第一张是编辑目标，其余由提示词说明用途。')
            c.add_argument('--mask', help='可选，与第一张输入图同尺寸同格式且有 alpha 通道。')
    inspect = sub.add_parser('inspect', help='检查本地图片尺寸、格式和 alpha，不需要联网。')
    inspect.add_argument('--image', required=True)
    return p


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    try:
        return run(parser().parse_args())
    except requests.Timeout:
        emit({'error': 'API 请求超时，未自动重试。服务端可能仍在生成，请先检查 provider 请求记录再决定是否重试。'}, error=True)
    except requests.RequestException as exc:
        emit({'error': f'网络请求失败（{type(exc).__name__}），未自动重试。'}, error=True)
    except (ImageAPIError, OSError, ValueError) as exc:
        emit({'error': str(exc)}, error=True)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
