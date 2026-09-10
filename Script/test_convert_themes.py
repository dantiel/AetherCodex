import unittest
from convert_themes import (normalize_hex, derive_chrome_palette, contrast,
                            composite_color)


class ThemeDecorationTests(unittest.TestCase):
    def test_magicwb_preserves_source_and_separates_surfaces(self):
        palette = derive_chrome_palette('0xCECECE', '0x000000', '0x42424282',
            {'background': '#88888830', 'foreground': '#111111',
             'selectionBackground': '#3A68A3A0'}, {}, 'light')
        value = lambda key: palette[key].strip('"')
        self.assertEqual(value('sourceRulerBackground'), '0x88888830')
        self.assertEqual(value('rulerBackground'), '0x888888')
        self.assertNotEqual(value('sidebarBackground'), value('rulerBackground'))
        self.assertGreaterEqual(contrast(value('sidebarForeground'), value('sidebarBackground')), 4.5)
        self.assertGreaterEqual(contrast(value('sidebarAccent'), value('sidebarBackground')), 3)

    def test_dark_and_light_palette_contrast(self):
        for kind, bg, fg in [('dark', '0x101826', '0xEEEEEE'), ('light', '0xF8F4E8', '0x222222')]:
            palette = derive_chrome_palette(bg, fg, '0x467ACCAA', {}, {}, kind)
            value = lambda key: palette[key].strip('"')
            self.assertGreaterEqual(contrast(value('sidebarForeground'), value('sidebarBackground')), 4.5)
            self.assertGreaterEqual(contrast(value('rulerForeground'), value('rulerBackground')), 4.5)

    def test_hex_and_rgba_order(self):
        self.assertEqual(normalize_hex('#abc')[0], '0xAABBCC')
        self.assertEqual(normalize_hex('0X88888830')[0], '0x88888830')
        self.assertEqual(composite_color('0x42424242', '0xFFFFFF'), '0xCECECE')


if __name__ == '__main__':
    unittest.main()
