"""配置回退回归：使用临时 Codex 目录和假密钥，不发送生图请求。"""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import image_api


class ConfigFallbackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {'CODEX_HOME': str(self.root)}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.write_codex()

    def write_codex(self, *, provider='selected', url='https://images.example/v1',
                    auth_fields='requires_openai_auth = true', prefix=''):
        (self.root / 'config.toml').write_text(
            f'model_provider = "{provider}"\n{prefix}\n'
            '[model_providers.unused]\nbase_url = "https://wrong.example/v1"\n'
            'experimental_bearer_token = "WRONG_PROVIDER_KEY"\n'
            f'[model_providers.{provider}]\nbase_url = "{url}"\n{auth_fields}\n',
            encoding='utf-8')
        self.write_auth({'OPENAI_API_KEY': 'FAKE_CURRENT_KEY'})

    def write_auth(self, value):
        (self.root / 'auth.json').write_text(json.dumps(value), encoding='utf-8')

    def resolve(self, *options):
        args = image_api.parser().parse_args(['models', *options])
        return image_api.resolve(args)

    def write_image_config(self, data):
        path = self.root / 'image-config.json'
        path.write_text(json.dumps(data), encoding='utf-8')
        return str(path)

    def test_uses_only_selected_provider_and_saved_api_key(self):
        self.assertEqual(self.resolve(), ('https://images.example/v1', 'FAKE_CURRENT_KEY'))

    def test_env_key_auth_does_not_reuse_saved_key(self):
        self.write_codex(auth_fields='env_key = "PROVIDER_IMAGE_KEY"')
        os.environ['PROVIDER_IMAGE_KEY'] = 'FAKE_ENV_KEY'
        self.assertEqual(self.resolve()[1], 'FAKE_ENV_KEY')
        del os.environ['PROVIDER_IMAGE_KEY']
        with self.assertRaises(image_api.ImageAPIError):
            self.resolve()

    def test_openai_auth_ignores_provider_env_key(self):
        self.write_codex(auth_fields='requires_openai_auth = true\nenv_key = "PROVIDER_IMAGE_KEY"')
        os.environ['PROVIDER_IMAGE_KEY'] = 'UNUSED_ENV_KEY'
        self.assertEqual(self.resolve()[1], 'FAKE_CURRENT_KEY')

    def test_direct_provider_token(self):
        self.write_codex(auth_fields='experimental_bearer_token = "FAKE_BEARER_KEY"')
        self.assertEqual(self.resolve()[1], 'FAKE_BEARER_KEY')

    def test_missing_key_is_filled_only_for_matching_api_prefix(self):
        self.assertEqual(self.resolve('--base-url', 'https://IMAGES.example:443/v1/')[1], 'FAKE_CURRENT_KEY')
        for url in ('https://different.example/v1', 'https://images.example/other',
                    'http://images.example/v1'):
            with self.subTest(url=url), self.assertRaises(image_api.ImageAPIError):
                self.resolve('--base-url', url)

    def test_missing_url_is_filled_without_replacing_explicit_key(self):
        self.assertEqual(self.resolve('--api-key', 'USER_KEY'), ('https://images.example/v1', 'USER_KEY'))

    def test_explicit_configuration_priority(self):
        config_path = self.write_image_config({'base_url': 'https://config.example/v1', 'api_key': 'CONFIG_KEY'})
        os.environ.update(IMAGE_API_BASE_URL='https://image-env.example/v1', IMAGE_API_KEY='IMAGE_ENV_KEY',
                          OPENAI_BASE_URL='https://openai-env.example/v1', OPENAI_API_KEY='OPENAI_ENV_KEY')
        self.assertEqual(self.resolve('--config', config_path, '--base-url', 'https://cli.example/v1',
                                      '--api-key', 'CLI_KEY'), ('https://cli.example/v1', 'CLI_KEY'))
        self.assertEqual(self.resolve('--config', config_path), ('https://image-env.example/v1', 'IMAGE_ENV_KEY'))
        del os.environ['IMAGE_API_BASE_URL'], os.environ['IMAGE_API_KEY']
        self.assertEqual(self.resolve('--config', config_path), ('https://openai-env.example/v1', 'OPENAI_ENV_KEY'))
        del os.environ['OPENAI_BASE_URL'], os.environ['OPENAI_API_KEY']
        self.assertEqual(self.resolve('--config', config_path), ('https://config.example/v1', 'CONFIG_KEY'))

    def test_full_explicit_pair_bypasses_broken_codex_config(self):
        (self.root / 'config.toml').write_text('invalid TOML = [', encoding='utf-8')
        self.assertEqual(self.resolve('--base-url', 'https://explicit.example/v1', '--api-key', 'USER_KEY'),
                         ('https://explicit.example/v1', 'USER_KEY'))

    def test_named_key_environment_never_silently_falls_back(self):
        for options in (['--api-key-env', 'MISSING_KEY'],
                        ['--config', self.write_image_config({'api_key_env': 'MISSING_KEY'})]):
            with self.subTest(options=options), self.assertRaises(image_api.ImageAPIError):
                self.resolve(*options)

    def test_key_file_is_used_and_empty_file_fails(self):
        path = self.root / 'test.key'
        path.write_text('\ufeffFILE_KEY\n', encoding='utf-8')
        self.assertEqual(self.resolve('--api-key-file', str(path))[1], 'FILE_KEY')
        path.write_text('', encoding='utf-8')
        with self.assertRaises(image_api.ImageAPIError):
            self.resolve('--api-key-file', str(path))

    def test_chatgpt_tokens_and_stale_api_key_are_not_reused(self):
        for auth in ({'tokens': {'access_token': 'OAUTH_TOKEN'}},
                     {'auth_mode': 'chatgpt', 'OPENAI_API_KEY': 'STALE_KEY',
                      'tokens': {'access_token': 'OAUTH_TOKEN'}}):
            with self.subTest(auth_mode=auth.get('auth_mode')):
                self.write_auth(auth)
                with self.assertRaises(image_api.ImageAPIError):
                    self.resolve()

    def test_official_domains_are_not_codex_fallbacks(self):
        for url in ('https://api.openai.com/v1', 'https://chatgpt.com/backend-api/codex',
                    'https://example.openai.com/v1'):
            with self.subTest(url=url):
                self.write_codex(url=url)
                with self.assertRaises(image_api.ImageAPIError):
                    self.resolve()

    def test_official_openai_can_still_be_explicitly_configured(self):
        self.assertEqual(self.resolve('--base-url', 'https://api.openai.com/v1', '--api-key', 'USER_KEY'),
                         ('https://api.openai.com/v1', 'USER_KEY'))

    def test_both_api_key_auth_mode_spellings(self):
        for mode in ('apikey', 'api_key'):
            with self.subTest(mode=mode):
                self.write_auth({'auth_mode': mode, 'OPENAI_API_KEY': 'MODE_KEY'})
                self.assertEqual(self.resolve()[1], 'MODE_KEY')

    def test_default_profile_selects_its_provider(self):
        self.write_codex(prefix='profile = "art"')
        with (self.root / 'config.toml').open('a', encoding='utf-8') as f:
            f.write('\n[profiles.art]\nmodel_provider = "unused"\n')
        self.assertEqual(self.resolve(), ('https://wrong.example/v1', 'WRONG_PROVIDER_KEY'))

    def test_profile_file_overrides_legacy_table(self):
        self.write_codex(prefix='profile = "art"')
        (self.root / 'art.config.toml').write_text('model_provider = "unused"\n', encoding='utf-8')
        self.assertEqual(self.resolve(), ('https://wrong.example/v1', 'WRONG_PROVIDER_KEY'))

    def test_missing_default_profile_fails(self):
        self.write_codex(prefix='profile = "missing"')
        with self.assertRaises(image_api.ImageAPIError):
            self.resolve()

    def test_no_configured_auth_does_not_borrow_other_credentials(self):
        self.write_codex(auth_fields='')
        with self.assertRaises(image_api.ImageAPIError):
            self.resolve()

    def test_malformed_codex_files_do_not_echo_secret_text(self):
        for file in ('config.toml', 'auth.json'):
            with self.subTest(file=file):
                self.write_codex()
                (self.root / file).write_text('SENSITIVE_FAKE_SECRET = [bad', encoding='utf-8')
                with self.assertRaises(image_api.ImageAPIError) as error:
                    self.resolve()
                self.assertNotIn('SENSITIVE_FAKE_SECRET', str(error.exception))

    def test_default_codex_directory_when_env_is_absent(self):
        (self.root / '.codex').mkdir()
        for name in ('config.toml', 'auth.json'):
            (self.root / name).replace(self.root / '.codex' / name)
        del os.environ['CODEX_HOME']
        with patch.object(image_api.Path, 'home', return_value=self.root):
            self.assertEqual(self.resolve()[1], 'FAKE_CURRENT_KEY')

    def test_dry_run_is_offline_and_does_not_print_key(self):
        args = image_api.parser().parse_args(['generate', '--prompt', 'test', '--dry-run',
                                              '--out', str(self.root / 'not-created.png')])
        output = io.StringIO()
        with patch.object(image_api.requests, 'post') as post, contextlib.redirect_stdout(output):
            self.assertEqual(image_api.run(args), 0)
        post.assert_not_called()
        self.assertNotIn('FAKE_CURRENT_KEY', output.getvalue())
        self.assertIn('https://images.example/v1/images/generations', output.getvalue())
        self.assertFalse((self.root / 'not-created.png').exists())

    def test_models_request_uses_discovered_pair_without_logging_key(self):
        response = image_api.requests.Response()
        response.status_code = 200
        response._content = b'{"data":[{"id":"gpt-image-2"}]}'
        output = io.StringIO()
        args = image_api.parser().parse_args(['models', '--images-only'])
        with patch.object(image_api.requests, 'get', return_value=response) as get, contextlib.redirect_stdout(output):
            self.assertEqual(image_api.run(args), 0)
        self.assertEqual(get.call_args.args[0], 'https://images.example/v1/models')
        self.assertEqual(get.call_args.kwargs['headers']['Authorization'], 'Bearer FAKE_CURRENT_KEY')
        self.assertNotIn('FAKE_CURRENT_KEY', output.getvalue())


if __name__ == '__main__':
    unittest.main(verbosity=2)
