#!/usr/bin/env python3
"""Structural validation runnable before the full iOS SDK is installed."""
import json
import hashlib
import plistlib
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(root / "Health.xcodeproj/project.pbxproj")]))
objects = project["objects"]
main = objects[project["rootObject"]]
targets = {objects[key]["name"]: objects[key] for key in main["targets"]}
assert set(targets) == {"Health", "WorkoutWidget", "HealthUITests"}
for value in objects.values():
    if value["isa"] == "PBXFileReference" and value["sourceTree"] == "<group>":
        assert (root / value["path"]).exists(), value["path"]
    if value["isa"] == "PBXBuildFile":
        assert value["fileRef"] in objects
app, widget = targets["Health"], targets["WorkoutWidget"]
assert app["productType"] == "com.apple.product-type.application"
assert widget["productType"] == "com.apple.product-type.app-extension"
assert any(objects[d]["target"] in main["targets"] and objects[objects[d]["target"]]["name"] == "WorkoutWidget" for d in app["dependencies"])
embed = next(objects[p] for p in app["buildPhases"] if objects[p]["isa"] == "PBXCopyFilesBuildPhase")
assert embed["dstSubfolderSpec"] == "13" or embed["dstSubfolderSpec"] == 13
assert any(objects[b]["fileRef"] == widget["productReference"] for b in embed["files"])
for target in (app, widget):
    sources = next(objects[p] for p in target["buildPhases"] if objects[p]["isa"] == "PBXSourcesBuildPhase")
    paths = [objects[objects[b]["fileRef"]]["path"] for b in sources["files"]]
    assert len(paths) == len(set(paths))
    assert "Shared/WorkoutSnapshot.swift" in paths and "Activity/WorkoutAttributes.swift" in paths
    assert sum("@main" in (root / p).read_text() for p in paths) == 1
    if target is app:
        assert {"App/NativeStore.swift", "App/HealthAPI.swift", "App/NativeWorkoutView.swift", "Shared/NativeTraining.swift", "Shared/NativeCache.swift"}.issubset(paths)
        assert not any("WebKit" in (root / p).read_text() or "WKWebView" in (root / p).read_text() for p in paths)
        assert not any(p.startswith("LegacyWebShell/") for p in paths)
with (root / "App/Info.plist").open("rb") as f:
    info = plistlib.load(f)
assert info["NSSupportsLiveActivities"] is True
assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["healthfp"]
assert "UIBackgroundModes" not in info
with (root / "Activity/Info.plist").open("rb") as f:
    assert plistlib.load(f)["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
scheme = ET.parse(root / "Health.xcodeproj/xcshareddata/xcschemes/Health.xcscheme")
assert scheme.find("BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference").attrib["BlueprintIdentifier"] in main["targets"]
test_reference = scheme.find("TestAction/Testables/TestableReference/BuildableReference")
assert objects[test_reference.attrib["BlueprintIdentifier"]] == targets["HealthUITests"]
icons = root / "App/Assets.xcassets/AppIcon.appiconset"
for image in json.loads((icons / "Contents.json").read_text())["images"]:
    assert (icons / image["filename"]).stat().st_size > 0
geometry = json.loads((root / "App/Resources/MusclePaths.json").read_text())
source_geometry = root.parent / "frontend/src/training/vendor/body-paths.js"
if source_geometry.exists():
    assert geometry["source_sha256"] == hashlib.sha256(source_geometry.read_bytes()).hexdigest(), "Regenerate native muscle paths from the current source"
for gender in ("male", "female"):
    assert set(geometry[gender]) == {"front", "back"}
    for view in geometry[gender].values():
        assert len(view["vb"]) == 4 and view["parts"]
        for commands in view["parts"].values():
            assert all(command[0] in {"M", "L", "C", "Q", "Z"} for command in commands)
print("Xcode structure, embedded Live Activity extension, source membership, plists, scheme, UI test target and icons: passed.")
