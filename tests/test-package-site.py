#!/usr/bin/env python3
"""Real MkDocs packaging tests; synthetic agents, actual strict site builds.

Run with DEEPDOCS_MKDOCS_BIN=/absolute/path/to/mkdocs when it is not on PATH.
These tests preserve root-owned documentation and verify a symlink publishing view.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('cli_fixtures', Path(__file__).with_name('test-update-cli.py'))
assert spec is not None and spec.loader is not None
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
MKDOCS = os.environ.get('DEEPDOCS_MKDOCS_BIN') or shutil.which('mkdocs')

@unittest.skipUnless(MKDOCS and Path(MKDOCS).is_file(), 'Real MkDocs required; set DEEPDOCS_MKDOCS_BIN')
class PackageSiteTests(unittest.TestCase):
    def fixture(self):
        assert MKDOCS is not None
        f = m.Fixture(self)
        (f.bin / 'mkdocs').unlink()
        (f.bin / 'mkdocs').symlink_to(Path(MKDOCS).resolve())
        return f

    def test_strict_build_uses_current_root_docs_without_moving_them(self):
        f = self.fixture()
        original = (f.docs / 'L4/alpha.md').read_bytes()
        self.assertEqual(f.run(phase='package'), 0, f.last_output)
        f.assert_baseline_unchanged()
        self.assertEqual((f.docs / 'L4/alpha.md').read_bytes(), original)
        self.assertTrue((f.docs / 'docs/L4').is_symlink())
        self.assertEqual((f.docs / 'docs/L4').resolve(), f.docs / 'L4')
        page = f.docs / 'site/L4/alpha/index.html'
        self.assertTrue(page.is_file(), f.last_output)
        self.assertIn('TEST DOUBLE inherited L4 alpha', page.read_text())
        m.write(f.docs / 'L4/alpha.md', '# Latest source documentation\n\nLIVE_EDIT_SENTINEL\n')
        self.assertEqual(f.run(), 0, f.last_output)
        self.assertIn('LIVE_EDIT_SENTINEL', page.read_text())
        self.assertFalse((f.docs / 'docs/builder').exists())
        self.assertFalse((f.docs / 'site/builder').exists())

    def test_conflicting_user_content_in_publish_view_is_not_overwritten(self):
        f = self.fixture()
        m.write(f.docs / 'docs/L4/alpha.md', 'USER_OWNED_CONTENT\n')
        self.assertNotEqual(f.run(phase='package'), 0, f.last_output)
        self.assertEqual((f.docs / 'docs/L4/alpha.md').read_text(), 'USER_OWNED_CONTENT\n')
        f.assert_baseline_unchanged()

    def test_existing_buzz_style_view_is_accepted_and_updated(self):
        f = self.fixture()
        (f.docs / 'docs').mkdir()
        for name in ('L1','L2','L3','L4','diagrams','index.md'):
            (f.docs / 'docs' / name).symlink_to('../' + name)
        m.write(f.docs / 'CHANGELOG.md', '# Changelog\n')
        self.assertEqual(f.run(phase='package'), 0, f.last_output)
        self.assertTrue((f.docs / 'docs/CHANGELOG.md').is_symlink())
        self.assertTrue((f.docs / 'site/CHANGELOG/index.html').is_file())
        f.assert_baseline_unchanged()

if __name__ == '__main__':
    unittest.main(verbosity=2)
