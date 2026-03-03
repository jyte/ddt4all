from ddt4all.ui.main_window.utils import set_theme_style

def test_set_theme_style_does_not_crash(qapp):
    set_theme_style(qapp, 2)  # dark
    set_theme_style(qapp, 0)  # light