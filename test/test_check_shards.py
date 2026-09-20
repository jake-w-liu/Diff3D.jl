"""Check that release coverage validation rejects incomplete or misleading reports."""

from copy import deepcopy
import unittest

from check_shards import validate_reports


class CoverageValidation(unittest.TestCase):
    def setUp(self):
        self.reports = [
            dict(status="passed", revision="candidate", suite_sha256="a" * 64,
                 all_units=["math", "render", "include: regression.jl"],
                 allocation_assertions=True, opt_level=2, compile_enabled=1,
                 encountered_units=3, shard=index, shards=2,
                 unit_ids=list(range(index, 4, 2)), julia="1.10.12", os="Linux", arch="x86_64")
            for index in (1, 2)
        ]

    def validate(self, reports):
        return validate_reports(reports, groups=1, revision="candidate")

    def test_complete_partition(self):
        self.assertEqual(self.validate(self.reports), [("1.10.12", "Linux", "x86_64")])

    def test_missing_or_duplicate_shards(self):
        for reports in ([], self.reports[:1], self.reports + self.reports[:1]):
            with self.subTest(reports=len(reports)), self.assertRaises(ValueError):
                self.validate(reports)

    def test_invalid_evidence(self):
        changes = (
            ("status", "failed"), ("revision", "older"), ("suite_sha256", "b" * 64),
            ("all_units", ["math"]), ("allocation_assertions", False), ("opt_level", 0),
            ("compile_enabled", 3), ("encountered_units", 2), ("unit_ids", []),
            ("unit_ids", [2, 2]), ("unit_ids", [1]), ("shard", 0), ("shards", 3),
            ("julia", "1.12.7"), ("os", "Darwin"), ("arch", ""),
        )
        for key, value in changes:
            reports = deepcopy(self.reports)
            reports[1][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.validate(reports)


if __name__ == "__main__":
    unittest.main()
