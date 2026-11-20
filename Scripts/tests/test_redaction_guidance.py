import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class RedactionGuidanceTests(unittest.TestCase):
    def test_redaction_guidance_recommends_a_solid_fill_for_secrets(self):
        for path, prefix in [('CHANGELOG.md', '- Blur and Pixelate'), ('DESIGN.md', '- **Redaction:**')]:
            with self.subTest(path=path):
                guidance = next(line for line in (ROOT / path).read_text().splitlines() if line.startswith(prefix)).lower()
                self.assertRegex(guidance, r'use (?:an? )?(?:opaque )?solid fill')
                self.assertIn('flattened image', guidance)
                self.assertNotRegex(guidance, r'can no longer be read back|text cannot be read|cannot be worked back')
