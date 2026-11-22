"""Validate packaged WoW textures without a game or imaging dependency."""
from pathlib import Path
import struct
import unittest

ADDON = Path(__file__).resolve().parents[1]


class ArtworkTests(unittest.TestCase):
    def test_packaged_alpha_tga_textures(self):
        for name, size in (("baggler", 1024), ("baggler-icon", 128), ("baggler-header", 64)):
            with self.subTest(name=name):
                data = (ADDON / "Assets" / (name + ".tga")).read_bytes()
                id_length, cmap, kind = data[:3]
                width, height, depth, descriptor = struct.unpack_from("<HHBB", data, 12)
                self.assertEqual((cmap, kind, width, height, depth), (0, 2, size, size, 32))
                self.assertEqual(descriptor & 15, 8, "eight alpha bits, not flattened RGB")
                pixels = data[18 + id_length:18 + id_length + size * size * 4]
                self.assertEqual(len(pixels), size * size * 4)
                alpha = pixels[3::4]
                self.assertEqual((min(alpha), max(alpha)), (0, 255))
                self.assertTrue(any(0 < a < 255 for a in alpha), "soft alpha edges retained")
                for corner in (0, size - 1, size * (size - 1), size * size - 1):
                    self.assertEqual(alpha[corner], 0, "no opaque background rectangle")

    def test_master_and_manifest(self):
        png = (ADDON / "Assets" / "baggler-master.png").read_bytes()
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack_from(">II", png, 16), (1024, 1024))
        self.assertEqual(png[25], 6, "original RGBA master")
        toc = (ADDON / "Baggler.toc").read_text()
        self.assertIn("## Title: |cff5ec8ffBaggler|r", toc)
        self.assertIn("## SavedVariables: BagglerDB", toc)
        self.assertIn("## IconTexture: Interface\\AddOns\\Baggler\\Assets\\baggler-icon.tga", toc)


if __name__ == "__main__":
    unittest.main()
