"""Local-only checks: no SSH, AWS access, Vault secrets or live reconfigure.
Run: python -m unittest discover -s tests -v
Requires ansible-core and PyYAML; uses ansible-playbook from PATH or its install dir.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sysconfig
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
ANSIBLE = shutil.which('ansible-playbook') or str(Path.home() / '.local/bin/ansible-playbook')

class TransportTests(unittest.TestCase):
    def run_mode(self, enabled, overrides=None):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            inventory = {'all': {'vars': {
                'ansible_connection': 'local', 'ansible_become': False,
                'ansible_python_interpreter': sysconfig.get_path('scripts') + '/python',
                'cluster_rpc_tls_enabled': enabled,
            }, 'children': {
                'gitaly': {'hosts': {'gitaly-1.internal': {}}},
                'praefect': {'hosts': {'praefect-1.internal': {}}},
                'bastion': {'hosts': {'bastion.internal': {
                    'praefect_db_host': 'db.example.test', 'praefect_db_port': 5432,
                    'praefect_db_name': 'praefect_production', 'praefect_db_user': 'praefect',
                    'praefect_db_password': 'test-password-not-real'}}},
            }}}
            if overrides:
                inventory['all']['children']['gitaly']['hosts']['gitaly-1.internal'].update(overrides)
            (temp/'inventory.yml').write_text(yaml.safe_dump(inventory))
            preflight = yaml.safe_load((ROOT/'playbooks/configure_cluster.yml').read_text())[0]
            defaults = {}
            for role in ('gitaly', 'praefect'):
                defaults.update(yaml.safe_load((ROOT/f'roles/{role}/defaults/main.yml').read_text()))
            defaults.update(cluster_rpc_tls_enabled=enabled, gitaly_storage_name='gitaly-1',
                            gitaly_configure_gitlab_callbacks=False,
                            praefect_internal_token='internal-test-token-' * 3,
                            praefect_external_token='external-test-token-' * 3)
            tasks = []
            for role in ('gitaly', 'praefect'):
                tasks.append({'name': f'Render actual {role} template', 'ansible.builtin.template': {
                    'src': str(ROOT/f'roles/{role}/templates/gitlab.rb.j2'),
                    'dest': str(temp/f'{role}.rb')}})
            render = {'name': 'Local template check', 'hosts': 'bastion', 'gather_facts': False,
                      'vars': defaults, 'tasks': tasks}
            (temp/'check.yml').write_text(yaml.safe_dump([preflight, render], sort_keys=False))
            env = dict(os.environ, ANSIBLE_CONFIG=str(ROOT/'ansible.cfg'), ANSIBLE_NOCOLOR='1')
            result = subprocess.run([ANSIBLE, '-i', str(temp/'inventory.yml'), str(temp/'check.yml')],
                                    env=env, capture_output=True, text=True)
            rendered = {role: (temp/f'{role}.rb').read_text() for role in ('gitaly','praefect')
                        if (temp/f'{role}.rb').exists()}
            return result, rendered

    def test_plaintext(self):
        result, files = self.run_mode(False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('listen_addr: "0.0.0.0:8075"', files['gitaly'])
        self.assertIn('listen_addr: "0.0.0.0:2305"', files['praefect'])
        self.assertIn('tcp://gitaly-1.internal:8075', files['praefect'])
        for content in files.values():
            self.assertNotIn('tls_listen_addr:', content)
            self.assertNotIn('certificate_path:', content)
        self.assertIn('sslmode: "verify-full"', files['praefect'])

    def test_tls(self):
        result, files = self.run_mode(True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('tls_listen_addr: "0.0.0.0:9999"', files['gitaly'])
        self.assertIn('tls_listen_addr: "0.0.0.0:3305"', files['praefect'])
        self.assertIn('tls://gitaly-1.internal:9999', files['praefect'])
        for content in files.values():
            self.assertIn('listen_addr: nil', content)
            self.assertIn('certificate_path: "/etc/gitlab/ssl/server.crt"', content)
        self.assertIn('sslmode: "verify-full"', files['praefect'])

    def test_reject_mixed_modes(self):
        result, _ = self.run_mode(False, {'cluster_rpc_tls_enabled': True})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Both RPC services must use the same mode', result.stdout)

    def test_reject_string_mode(self):
        result, _ = self.run_mode('false')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Set cluster_rpc_tls_enabled to true or false', result.stdout)

    def test_reject_legacy_switch(self):
        result, _ = self.run_mode(False, {'gitaly_enable_tls': True})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Remove gitaly_enable_tls/praefect_enable_tls', result.stdout)

    def test_all_yaml_parses(self):
        for path in ROOT.rglob('*'):
            if path.suffix in ('.yml', '.yaml') and not path.name == 'vault.yml':
                with self.subTest(path=str(path.relative_to(ROOT))):
                    list(yaml.safe_load_all(path.read_text()))

if __name__ == '__main__':
    unittest.main()
