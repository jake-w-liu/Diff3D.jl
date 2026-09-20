"""Check the comparison oracle against captured pixels and deliberate corruption."""

import unittest

from browser import validate_pixels


class PixelOracleTests(unittest.TestCase):
    def setUp(self):
        self.fixture = {"width": 16, "height": 16, "color": [0.2, 0.4, 0.6],
                        "background": [0.0, 0.0, 0.0]}
        self.case = {"count": 1, "mode": "static", "amplitude": 0,
                     "positions": [-0.79, -0.84, 0, 0.89, -0.84, 0, 0.05, 0.84, 0],
                     "centers": [0, 0, 0]}
        # Captured from both engines on Chromium 153 / SwiftShader, which
        # reports four subpixel bits. This is the 16x16 crop at (14,120) of
        # static-128; the window vertices are (1.68,1.28), (15.12,1.28),
        # (8.40,14.72). The reference mask is independent of this oracle.
        mask = (
            "................",
            "..#############.",
            "..############..",
            "...###########..",
            "...##########...",
            "....#########...",
            "....########....",
            ".....#######....",
            ".....######.....",
            "......#####.....",
            "......####......",
            ".......###......",
            ".......##.......",
            "........#.......",
            "................",
            "................",
        )
        self.foreground = [51, 102, 153, 255]
        self.background = [0, 0, 0, 255]
        self.pixels = [channel for row in mask for value in row
                       for channel in (self.foreground if value == "#" else self.background)]

    def check(self, pixels, bits=4):
        return validate_pixels(pixels, self.fixture, self.case, 0, bits)

    def replace(self, x, y, color):
        result = self.pixels.copy()
        offset = 4 * (y * 16 + x)
        result[offset:offset + 4] = color
        return result

    def test_captured_rasterization_and_precision(self):
        record, boundary = self.check(self.pixels)
        self.assertGreater(record["colored_pixels"], 0)
        self.assertLess(record["edge_tolerance_pixels"], 0.1)
        self.assertIn(2 * 16 + 14, boundary)
        # The disputed pixel is farther from the ideal edge than the allowed
        # band for eight-bit subpixel precision. Do not ignore all edge errors.
        with self.assertRaises(AssertionError):
            self.check(self.pixels, bits=8)

    def test_edge_allows_only_the_two_expected_colors(self):
        self.check(self.replace(14, 2, self.foreground))
        with self.assertRaises(AssertionError):
            self.check(self.replace(14, 2, [1, 2, 3, 255]))

    def test_interior_and_background_corruption_fail(self):
        for x, y, color in ((8, 5, self.background), (0, 0, self.foreground),
                            (8, 5, [51, 102, 153, 0])):
            with self.subTest(x=x, y=y, color=color), self.assertRaises(AssertionError):
                self.check(self.replace(x, y, color))

    def test_one_pixel_shift_fails(self):
        shifted = []
        for y in range(16):
            shifted.extend(self.background)
            shifted.extend(self.pixels[y * 64:y * 64 + 60])
        with self.assertRaises(AssertionError):
            self.check(shifted)

    def test_empty_full_and_wrong_size_images_fail(self):
        for pixels in (self.background * 256, self.foreground * 256, self.pixels[:-1]):
            with self.subTest(length=len(pixels)), self.assertRaises(AssertionError):
                self.check(pixels)

    def test_invalid_subpixel_precision_fails(self):
        for bits in (None, True, -1, 0, 3, 4.0, float("nan")):
            with self.subTest(bits=bits), self.assertRaises(AssertionError):
                self.check(self.pixels, bits)


if __name__ == "__main__":
    unittest.main()
