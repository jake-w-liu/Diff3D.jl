"""Check the comparison harness records and the published summary derivation."""

from pathlib import Path
import unittest

from run import portable_argument
from summarize import median, statistics


class PortableArgumentTests(unittest.TestCase):
    def setUp(self):
        self.root = Path("/checkout/Diff3D.jl")
        self.inside = self.root / "benchmarks/threejs/results"
        self.outside = Path("/var/tmp/comparison-output")

    def portable(self, argument, output):
        return portable_argument(argument, root=self.root, output=output)

    def test_repository_paths_become_placeholders(self):
        for output in (self.inside, self.outside):
            with self.subTest(output=output):
                self.assertEqual(
                    self.portable(str(self.root / "benchmarks/threejs/run.py"), output),
                    "<repo>/benchmarks/threejs/run.py")
                self.assertEqual(self.portable(f"--project={self.root}", output), "--project=<repo>")

    def test_output_paths_become_placeholders(self):
        for output in (self.inside, self.outside):
            with self.subTest(output=output):
                self.assertEqual(self.portable(str(output / "fixtures/browser.json"), output),
                                 "<output>/fixtures/browser.json")
                self.assertEqual(self.portable(str(output), output), "<output>")

    def test_output_inside_the_repository_is_replaced_first(self):
        # The repository prefix also matches, so the more specific one must win.
        self.assertEqual(self.portable(str(self.inside / "html"), self.inside), "<output>/html")

    def test_external_absolute_paths_keep_only_the_program_name(self):
        for argument, expected in (("/opt/python-env/bin/python", "python"),
                                   ("/usr/local/bin/node", "node")):
            with self.subTest(argument=argument):
                self.assertEqual(self.portable(argument, self.outside), expected)

    def test_relative_arguments_and_options_are_unchanged(self):
        for argument in ("julia", "node", "--startup-file=no", "--browser", "chromium",
                         "--order", "diff3d-first", "benchmarks/threejs/run.py"):
            with self.subTest(argument=argument):
                self.assertEqual(self.portable(argument, self.outside), argument)

    def test_no_recorded_argument_stays_absolute(self):
        command = [str(self.root / "x"), f"--project={self.root}", str(self.outside / "y"),
                   "/opt/python-env/bin/python", "julia", "--order", "three-first"]
        for output in (self.inside, self.outside):
            with self.subTest(output=output):
                recorded = [self.portable(argument, output) for argument in command]
                self.assertFalse([value for value in recorded if Path(value).is_absolute()])


class TimingStatisticsTests(unittest.TestCase):
    def test_nearest_rank_percentile_matches_the_published_definition(self):
        # ceil(0.95 * 21) = 20, so the 20th of 21 sorted samples is quoted.
        samples = [float(value) for value in range(21, 0, -1)]
        self.assertEqual(statistics(samples), {
            "samples": 21, "minimum_ms": 1.0, "median_ms": 11.0,
            "p95_nearest_rank_ms": 20.0, "maximum_ms": 21.0})

    def test_single_sample_is_its_own_statistic(self):
        self.assertEqual(statistics([2.5]), {
            "samples": 1, "minimum_ms": 2.5, "median_ms": 2.5,
            "p95_nearest_rank_ms": 2.5, "maximum_ms": 2.5})

    def test_even_sample_count_averages_the_middle_pair(self):
        self.assertEqual(median([1.0, 2.0, 3.0, 5.0]), 2.5)
        # ceil(0.95 * 4) = 4, so an even distribution quotes its maximum.
        self.assertEqual(statistics([5.0, 1.0, 3.0, 2.0])["p95_nearest_rank_ms"], 5.0)

    def test_unsorted_input_is_ordered_before_summarising(self):
        self.assertEqual(statistics([9.0, 1.0, 5.0]),
                         statistics([1.0, 5.0, 9.0]))

    def test_an_empty_distribution_is_rejected(self):
        with self.assertRaises(ValueError):
            statistics([])


if __name__ == "__main__":
    unittest.main()
