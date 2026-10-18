#!/usr/bin/env python3
"""Type- and content-check the settings bundle's specifier plists.

Preferences.framework trusts these types and crashes Settings when one is wrong: `autoCaps` goes
to +[PSSpecifier autoCapsTypeForString:], which sends it -isEqualToString: ("sentences", "words",
"all"; anything else means none), so `<false/>` there aborted Settings on opening the Lyrics and
Sources pages (0.2.2). `autoCorrection` goes to +autoCorrectionTypeForNumber: and wants a number.

Beyond types (0.5.0): no plist may mention a removed preference key as a `key` or `id`; the
`lyricsMode` and `progressBarStyle` pickers must offer exactly the values the tweak understands;
the `id`s the controllers insert, remove or reload by must exist in their plist; and the bundle's
CFBundleShortVersionString must equal the deb's version in `control`.

Every selector a plist names (`buttonAction`, `action`, `get`, `set`) must start with `cl_` (0.8.1):
PSListController has private methods with plain names, and a button action called `clearCache`
overrode the one Preferences calls from -reload and -dealloc — the alert popped up on opening the
page and Settings crashed on leaving it.
Exit status 1 when anything is off.
"""
import glob
import os
import plistlib
import re
import sys

STRING_KEYS = {"autoCaps", "keyboard", "cell", "key", "label", "defaults", "PostNotification",
               "detail", "action", "get", "set", "id", "footerText", "placeholder", "bundle",
               "icon", "headerCellClass", "cellClass", "buttonAction", "appIDForLazyIcon"}
BOOL_KEYS = {"autoCorrection", "negate", "showValue", "isContinuous", "enabled", "isController",
             "noAutoCorrect", "hasIcon", "isSegmented", "isURL", "isEmail", "isNumeric",
             "isDecimalPad", "useLazyIcons", "hidesDisclosureIndicator"}
NUMBER_KEYS = {"min", "max", "height", "segmentCount"}
AUTOCAPS = {"none", "sentences", "words", "all"}

# Specifier keys whose value is a selector on our controller.
SELECTOR_KEYS = ("buttonAction", "action", "get", "set")

# Keys 0.5.0 removed (contracts.md §2). They exist only in +[CLPrefsShared legacyKeys].
REMOVED_KEYS = {"lyricsPosition", "lyricsMaxLines", "artworkScale", "titleFontSize", "compactMode",
                "hideAppBadge"}

# The values a picker for these keys must offer, in order.
REQUIRED_VALID_VALUES = {
    "lyricsMode": [0, 2, 4],
    "progressBarStyle": [0, 2],
    "lyricsSide": [1, 0],
}

# The ids the controllers show, hide or reload by (contracts.md §5).
REQUIRED_IDS = {
    "Root.plist": ["layout", "version"],
    "Layout.plist": ["layoutGroup", "lyricsSide", "fullScreenGroup", "showLyricsButton", "playerGroup", "showAlbum",
                     "progressBarStyle", "artworkCornerRadius",
                     "backgroundGroup", "backdropStyle", "backdropOpacity", "accentGroup", "tintFromArtwork",
                     "accentColor", "toolbarGroup", "hideQueueButton", "hidePlaybackRateButton"],
    "Lyrics.plist": ["lyricsFontFamily", "lyricsBackground", "lyricsBackgroundColor", "lyricsBackgroundAlpha"],
    "Sources.plist": ["customEndpointEnabled", "customEndpointGroup", "customEndpointURL",
                      "customEndpointHeaderName", "customEndpointHeaderValue", "cacheNegativeHours"],
    "Apps.plist": ["allApps", "appsGroup", "addApp"],
    "Maintenance.plist": ["cachedSongs"],
}

# Cell types (and getters) the ids above are expected to have, where the controller relies on it.
REQUIRED_CELLS = {
    ("Root.plist", "layout"): ("PSLinkListCell", "cl_layoutModeValue:"),
    ("Root.plist", "version"): ("PSTitleValueCell", "cl_version:"),
    ("Lyrics.plist", "lyricsFontFamily"): ("PSLinkListCell", None),
    # Colour rows: PSLinkListCell so the row shows its colour (CLListController cl_refreshColorRowTitle:).
    ("Lyrics.plist", "lyricsCurrentColor"): ("PSLinkListCell", None),
    ("Lyrics.plist", "lyricsNextColor"): ("PSLinkListCell", None),
    ("Lyrics.plist", "lyricsBackgroundColor"): ("PSLinkListCell", None),
    ("Layout.plist", "accentColor"): ("PSLinkListCell", None),
    ("Lyrics.plist", "lyricsBackground"): ("PSSegmentCell", None),
    ("Sources.plist", "cacheNegativeHours"): ("PSLinkListCell", None),
    ("Maintenance.plist", "cachedSongs"): ("PSTitleValueCell", "cl_cachedSongsSummary:"),
}
CACHE_NEGATIVE_HOURS_VALUES = [1, 6, 24, 72, 168]

problems = []
for path in sorted(glob.glob("Prefs/Resources/*.plist") + glob.glob("Prefs/*.plist")):
    with open(path, "rb") as handle:
        document = plistlib.load(handle)
    if not isinstance(document, dict):
        continue
    items = list(document.get("items", []))
    if isinstance(document.get("entry"), dict):
        items.append(document["entry"])
    seen_ids = {}
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            problems.append(f"{path}: item {index} is {type(item).__name__}, not a dict")
            continue
        name = item.get("id") or item.get("key") or item.get("label") or f"item {index}"
        for key, value in item.items():
            wrong = ((key in STRING_KEYS and not isinstance(value, str)) or
                     (key in BOOL_KEYS and not isinstance(value, bool)) or
                     (key in NUMBER_KEYS and (isinstance(value, bool) or not isinstance(value, (int, float)))))
            if wrong:
                problems.append(f"{path}: {name}: {key} is {type(value).__name__}")
        if isinstance(item.get("autoCaps"), str) and item["autoCaps"] not in AUTOCAPS:
            problems.append(f"{path}: {name}: autoCaps '{item['autoCaps']}' is not one of {sorted(AUTOCAPS)}")
        titles, values = item.get("validTitles"), item.get("validValues")
        if titles is not None and values is not None and len(titles) != len(values):
            problems.append(f"{path}: {name}: {len(titles)} validTitles for {len(values)} validValues")
        if (titles is None) != (values is None):
            problems.append(f"{path}: {name}: validTitles and validValues must come together")

        for field in ("key", "id"):
            value = item.get(field)
            if isinstance(value, str) and value in REMOVED_KEYS:
                problems.append(f"{path}: {name}: {field} '{value}' was removed in 0.5.0")
        for field in SELECTOR_KEYS:
            value = item.get(field)
            if isinstance(value, str) and not value.startswith("cl_"):
                problems.append(f"{path}: {name}: {field} '{value}' must start with cl_ "
                                "(a plain name can override a private PSListController method)")
        key = item.get("key")
        if isinstance(key, str) and key in REQUIRED_VALID_VALUES and values is not None:
            if list(values) != REQUIRED_VALID_VALUES[key]:
                problems.append(f"{path}: {name}: validValues {list(values)} must be {REQUIRED_VALID_VALUES[key]}")
        if key == "cacheNegativeHours" and values is not None and list(values) != CACHE_NEGATIVE_HOURS_VALUES:
            problems.append(f"{path}: {name}: validValues {list(values)} must be {CACHE_NEGATIVE_HOURS_VALUES}")
        if item.get("cell") == "PSSliderCell" and "PostNotification" not in item and os.path.basename(path) != "Layout.plist":
            problems.append(f"{path}: {name}: live slider without PostNotification")
        if os.path.basename(path) == "Layout.plist" and "PostNotification" in item:
            problems.append(f"{path}: {name}: Layout rows are staged and must not PostNotification")

        identifier = item.get("id")
        if isinstance(identifier, str):
            if identifier in seen_ids:
                problems.append(f"{path}: id '{identifier}' appears twice")
            seen_ids[identifier] = item

    base = os.path.basename(path)
    for identifier in REQUIRED_IDS.get(base, []):
        if identifier not in seen_ids:
            problems.append(f"{path}: missing id '{identifier}'")
    for (plist, identifier), (cell, getter) in REQUIRED_CELLS.items():
        if plist != base or identifier not in seen_ids:
            continue
        item = seen_ids[identifier]
        if item.get("cell") != cell:
            problems.append(f"{path}: {identifier}: cell is {item.get('cell')!r}, expected {cell!r}")
        if getter and item.get("get") != getter:
            problems.append(f"{path}: {identifier}: get is {item.get('get')!r}, expected {getter!r}")


def control_version():
    try:
        with open("control", encoding="utf-8") as handle:
            for line in handle:
                match = re.match(r"^Version:\s*(\S+)\s*$", line)
                if match:
                    return match.group(1)
    except OSError:
        return None
    return None


def bundle_version():
    try:
        with open("Prefs/Resources/Info.plist", "rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return None
    return info.get("CFBundleShortVersionString") if isinstance(info, dict) else None


deb_version, prefs_version = control_version(), bundle_version()
if deb_version is None:
    problems.append("control: no Version line")
if prefs_version is None:
    problems.append("Prefs/Resources/Info.plist: no CFBundleShortVersionString")
if deb_version is not None and prefs_version is not None and deb_version != prefs_version:
    problems.append(f"version mismatch: control says {deb_version}, Prefs/Resources/Info.plist says {prefs_version}")

# PSListController on 17.3 implements -table, not -tableView (0.9.1): `self.tableView` in a list page
# compiled against Theos' header and aborted Settings on the All Apps switch with an unrecognised
# selector. A page that declares its own tableView property (a PSViewController) is fine.
for source in sorted(glob.glob("Prefs/*.m")):
    header = source[:-2] + ".h"
    try:
        with open(header) as handle:
            declaration = handle.read()
        with open(source) as handle:
            body = handle.read()
    except OSError:
        continue
    is_list = re.search(r"@interface\s+\w+\s*:\s*(CLListController|PSListController)\b", declaration)
    if is_list and re.search(r"self\.tableView\b|\[self tableView\]", body):
        problems.append(f"{source}: PSListController has no -tableView on iOS 17; use self.table or -reloadSpecifiers")

for problem in problems:
    print(problem)
print(f"settings plists: {'OK' if not problems else f'{len(problems)} problem(s)'}")
sys.exit(1 if problems else 0)
