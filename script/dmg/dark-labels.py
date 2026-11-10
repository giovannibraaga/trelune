# Finder picks the icon label color from the window's background color, even when a background picture
# is set; dmgbuild stores white there, so labels come out black. Store the Figma background (#171717).
import sys
from ds_store import DSStore

with DSStore.open(sys.argv[1] + "/.DS_Store", "r+") as store:
    icvp = store["."]["icvp"]
    icvp["backgroundColorRed"] = icvp["backgroundColorGreen"] = icvp["backgroundColorBlue"] = 0x17 / 255
    store["."]["icvp"] = icvp
