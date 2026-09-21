"""Check that the published-tree path guard reports real paths and only those."""

import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

from check_no_local_paths import SELF, findings, scan


class PathDetection(unittest.TestCase):
    def matches(self, text):
        return [matched for _, _, matched in findings("sample", text.encode())]

    def test_machine_specific_paths_are_reported(self):
        cases = {
            'path = "/Users/someone/code/Diff3D.jl"': "/Users/someone/code/Diff3D.jl",
            "cd /home/builder/work/Diff3D.jl": "/home/builder/work/Diff3D.jl",
            "julia --project=/private/tmp/run-42/env": "/private/tmp/run-42/env",
            "cache at /private/var/folders/x/T/build": "/private/var/folders/x/T/build",
            r'"C:\Users\builder\Diff3D.jl"': r"C:\Users\builder\Diff3D.jl",
        }
        for line, expected in cases.items():
            with self.subTest(line=line):
                self.assertEqual(self.matches(line), [expected])

    def test_portable_and_generic_text_is_accepted(self):
        for line in ('path = ".."', "--project=<repo>", "<output>/fixtures/browser.json",
                     "python benchmarks/threejs/run.py /tmp/diff3d-comparison",
                     "files under /home", "/usr/bin/python3", "/opt/hostedtoolcache/Python",
                     "https://github.com/jake-w-liu/Diff3D.jl", "docs/build/index.html"):
            with self.subTest(line=line):
                self.assertEqual(self.matches(line), [])

    def test_every_occurrence_on_a_line_is_reported(self):
        line = "cp /Users/a/one.txt /Users/b/two.txt"
        self.assertEqual(self.matches(line), ["/Users/a/one.txt", "/Users/b/two.txt"])

    def test_binary_content_is_skipped(self):
        self.assertEqual(findings("image.png", b"\x89PNG\r\n\x1a\n\xff\xfe/Users/someone/x"), [])


class RepositoryScan(unittest.TestCase):
    def repository(self, directory: Path, files: dict, archive: dict | None = None):
        subprocess.run(["git", "init", "-q"], cwd=directory, check=True)
        for name, contents in files.items():
            (directory / name).write_text(contents)
        if archive is not None:
            with tarfile.open(directory / "evidence.tar.gz", "w:gz") as stream:
                for name, contents in archive.items():
                    info = tarfile.TarInfo(name)
                    info.size = len(contents.encode())
                    stream.addfile(info, io.BytesIO(contents.encode()))
        subprocess.run(["git", "add", "-A"], cwd=directory, check=True)
        return scan(directory)

    def test_clean_tree_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            results = self.repository(Path(directory), {"a.toml": 'path = ".."\n'},
                                      {"run.json": '{"argv": ["<repo>/run.py"]}\n'})
            self.assertEqual(results, [])

    def test_tracked_file_and_archive_member_are_both_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            results = self.repository(
                Path(directory), {"a.toml": 'x = 1\npath = "/Users/someone/pkg"\n'},
                {"run.json": '{}\n{"argv": ["/Users/someone/run.py"]}\n'})
            self.assertEqual(sorted(results), [
                ("a.toml", 2, "/Users/someone/pkg"),
                ("evidence.tar.gz:run.json", 2, "/Users/someone/run.py"),
            ])

    def test_only_the_guard_and_its_tests_are_exempt(self):
        self.assertEqual(SELF, ("test/check_no_local_paths.py",
                                "test/test_check_no_local_paths.py"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test").mkdir()
            contents = 'path = "/Users/someone/pkg"\n'
            results = self.repository(root, {name: contents for name in SELF}
                                      | {"test/other_check.py": contents})
            self.assertEqual(results, [("test/other_check.py", 1, "/Users/someone/pkg")])

    def test_untracked_files_are_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = self.repository(root, {"a.toml": 'path = ".."\n'})
            (root / "scratch.log").write_text("/Users/someone/scratch\n")
            self.assertEqual(results, [])
            self.assertEqual(scan(root), [])


if __name__ == "__main__":
    unittest.main()
