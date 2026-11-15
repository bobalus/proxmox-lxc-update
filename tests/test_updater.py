import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'proxmox_lxc_update.sh'

class UpdaterTests(unittest.TestCase):
    def run_updater(self, scenario):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            bins = root / 'bin'
            bins.mkdir()
            mock = '''#!/bin/bash
case "$(basename "$0")" in
 apt-get) if [[ "${IN_CT:-}" == 1 ]]; then printf '%s\\n' "$1" >> "$APT_CALLS"; if [[ "$SCENARIO" == embeddedfail && "$1" == autoremove ]]; then echo 'autoremove exploded' >&2; exit 13; fi; if [[ "$1" == upgrade || "$1" == dist-upgrade ]]; then echo '0 upgraded, 0 newly installed'; fi; elif [[ "$SCENARIO" == hostfail ]]; then echo 'host repository broken' >&2; exit 42; fi ;;
 apt) printf 'Listing...\\n' ;;
 timeout) shift; exec "$@" ;;
 pct)
   if [[ "$1" == list ]]; then
     if [[ "$SCENARIO" == listfail ]]; then echo 'enumeration broken' >&2; exit 9; fi
     printf 'VMID Status Lock Name\\n101 running - demo\\n'; exit
   fi
   if [[ "$4" == hostname ]]; then echo demo; exit; fi
   if [[ "$4" == bash ]]; then echo Debian; exit; fi
   if [[ "$SCENARIO" == embedded* ]]; then export IN_CT=1; shift 3; exec "$@"; fi
   if [[ "$SCENARIO" == timeout ]]; then echo 'partial timeout details' >&2; exit 124; fi
   if [[ "$SCENARIO" == updatefail ]]; then echo 'E: container repository broken' >&2; exit 7; fi
   if [[ "$SCENARIO" == long ]]; then python3 -c "print('ERROR-LINE-' + 'x'*4000 + '-THE-END')"; exit 8; fi
   echo NO_PATCHES ;;
 curl)
   while [[ $# -gt 0 ]]; do if [[ "$1" == -d ]]; then printf '%s\\n' "$2" >> "$CAPTURE"; shift; fi; shift; done
   if [[ "$SCENARIO" == deliveryfail ]]; then printf 500; exit; fi
   printf 204 ;;
esac
'''
            for name in ('apt-get', 'apt', 'timeout', 'pct', 'curl'):
                p = bins / name
                p.write_text(mock)
                p.chmod(0o755)
            text = SCRIPT.read_text().replace('export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"', f'export PATH="{bins}:/usr/bin:/bin"')
            script = root / 'updater.sh'
            script.write_text(text)
            config = root / 'config'
            config.write_text('https://example.invalid/test\n')
            capture = root / 'capture'
            env = dict(os.environ, SCENARIO=scenario, CAPTURE=str(capture), APT_CALLS=str(root / 'apt-calls'), LXC_UPDATE_CONFIG=str(config))
            result = subprocess.run(['bash', str(script)], env=env, text=True, capture_output=True, timeout=15)
            payloads = [json.loads(line)['content'] for line in capture.read_text().splitlines()] if capture.exists() else []
            return result, payloads, (root / 'apt-calls').read_text().splitlines() if (root / 'apt-calls').exists() else []

    def test_container_error_reaches_report_and_fails_run(self):
        result, messages, _ = self.run_updater('updatefail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('container repository broken', ''.join(messages))

    def test_host_error_reaches_report(self):
        result, messages, _ = self.run_updater('hostfail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('host repository broken', ''.join(messages))

    def test_enumeration_error_is_not_empty_success(self):
        result, messages, _ = self.run_updater('listfail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('enumeration broken', ''.join(messages))
        self.assertNotIn('No running LXC', ''.join(messages))

    def test_timeout_is_failure_and_includes_output(self):
        result, messages, _ = self.run_updater('timeout')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('timed out', ''.join(messages))
        self.assertIn('partial timeout details', ''.join(messages))

    def test_long_output_is_not_truncated(self):
        result, messages, _ = self.run_updater('long')
        self.assertNotEqual(result.returncode, 0)
        self.assertGreater(len(messages), 1)
        self.assertTrue(all(len(m) <= 2000 for m in messages))
        self.assertIn('ERROR-LINE-' + 'x'*4000 + '-THE-END', ''.join(messages))

    def test_embedded_sequence_and_failure(self):
        result, messages, calls = self.run_updater('embeddedfail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['update', 'upgrade', 'dist-upgrade', 'autoremove'])
        self.assertIn('autoremove exploded', ''.join(messages))
        result, messages, calls = self.run_updater('embeddedsuccess')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['update', 'upgrade', 'dist-upgrade', 'autoremove', 'clean'])

    def test_delivery_failure_prints_summary_and_fails(self):
        result, messages, _ = self.run_updater('deliveryfail')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Full summary follows', result.stderr)
        self.assertIn('no patches applied', result.stderr)

    def test_success(self):
        result, messages, _ = self.run_updater('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no patches applied', ''.join(messages))

if __name__ == '__main__':
    unittest.main()
