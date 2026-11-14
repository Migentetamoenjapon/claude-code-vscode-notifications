#!/usr/bin/env python3
"""Build the extension as a .vsix without npm or vsce.

A .vsix is a zip with a manifest and the extension files under extension/.

    python3 package.py                      -> ccnotify-focus-terminal-<version>.vsix next to this file
    python3 package.py --out /tmp/x.vsix    -> custom output path

Prints the path of the file it wrote.
"""
import argparse
import json
import os
import sys
import zipfile
from xml.sax.saxutils import escape, quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ("package.json", "extension.js")

CONTENT_TYPES = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".txt" ContentType="text/plain"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
"""


def manifest(pkg, has_license):
    license_asset = ('\n    <Asset Type="Microsoft.VisualStudio.Services.Content.License" '
                     'Path="extension/LICENSE.txt" Addressable="true"/>') if has_license else ""
    return """<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011"
  xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id=%s Version=%s Publisher=%s/>
    <DisplayName>%s</DisplayName>
    <Description xml:space="preserve">%s</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value=%s/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>%s
  </Assets>
</PackageManifest>
""" % (quoteattr(pkg["name"]), quoteattr(pkg["version"]), quoteattr(pkg["publisher"]),
       escape(pkg["displayName"]), escape(pkg["description"]), quoteattr(pkg["engines"]["vscode"]),
       license_asset)


def build(out=None):
    with open(os.path.join(HERE, "package.json"), encoding="utf-8") as f:
        pkg = json.load(f)
    out = out or os.path.join(HERE, "ccnotify-%s-%s.vsix" % (pkg["name"], pkg["version"]))
    license_file = next((p for p in (os.path.join(HERE, "LICENSE"), os.path.join(HERE, "..", "LICENSE"))
                         if os.path.isfile(p)), None)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("extension.vsixmanifest", manifest(pkg, bool(license_file)))
        for name in FILES:
            z.write(os.path.join(HERE, name), "extension/" + name)
        if license_file:
            z.write(license_file, "extension/LICENSE.txt")
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", help="output .vsix path")
    args = parser.parse_args(argv)
    print(build(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
