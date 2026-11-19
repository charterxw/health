#!/usr/bin/env python3
"""Package only reviewed source/configuration; exclude local signing and build data."""
import hashlib
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
entries = ["App", "Activity", "Shared", "Checks", "NativeChecks", "Tests", "scripts", "Package.swift", "README.md", "DESIGN.md",
           "Config/Health.xcconfig", "Config/Local.xcconfig.example",
           "Health.xcodeproj/project.pbxproj", "Health.xcodeproj/xcshareddata/xcschemes/Health.xcscheme"]
destination = root / "build/Pine-native-iOS-source.zip"
destination.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
    for entry in entries:
        path = root / entry
        for item in sorted(path.rglob("*")) if path.is_dir() else [path]:
            if item.is_file() and not any(part.startswith(".") or part == "__pycache__" for part in item.relative_to(root).parts):
                archive.write(item, "ios/" + str(item.relative_to(root)))
with zipfile.ZipFile(destination) as archive:
    assert archive.testzip() is None
    assert "ios/Health.xcodeproj/project.pbxproj" in archive.namelist()
    assert not any("Local.xcconfig" == Path(name).name or ".build/" in name or "xcuserdata/" in name for name in archive.namelist())
print(destination)
print("SHA-256:", hashlib.sha256(destination.read_bytes()).hexdigest())
