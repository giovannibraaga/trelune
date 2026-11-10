# dmgbuild settings for the Trelune installer (Figma "57 · Instalação DMG · escuro").
# Values come from make-dmg.sh: -D app=<Trelune.app> -D background=<background.png> -D icon=<AppIcon.icns>
import os.path

app = defines["app"]
format = defines.get("format", "UDZO")
compression_level = 9
filesystem = "HFS+"
size = None
files = [app]
symlinks = {"Aplicativos": "/Applications"}
icon = defines.get("icon")
background = defines["background"]          # background@2x.png next to it is picked up for Retina

# Finder window: 760 × 444 pt content, icon view, no chrome.
window_rect = ((200, 120), (760, 444))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 96
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (231, 225),
    "Aplicativos": (534, 225),
}
