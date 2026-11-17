#!/usr/bin/env python3
"""Package locally with the configured Developer ID and notarization key."""
import base64
import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

root = Path(__file__).resolve().parents[1]
build = Path(os.environ.get("WAWUBI_BUILD_DIR", Path.home() / "dev/build/wa-wubi/release"))
build.mkdir(parents=True, exist_ok=True)
with (Path.home() / ".apple.json").open() as file:
    team = json.load(file)["common"]
account = team["appStoreConnect"]
with TemporaryDirectory(prefix="notary-", dir=build) as scratch:
    key = Path(scratch) / "AuthKey.p8"
    key.touch(mode=0o600)
    key.write_bytes(base64.b64decode(account["privateKeyBase64"], validate=True))
    environment = dict(
        os.environ,
        WAWUBI_BUILD_DIR=str(build),
        WAWUBI_SIGN_IDENTITY=team["certificates"]["developerIdApplication"]["identity"],
        WAWUBI_NOTARY_KEY_FILE=str(key),
        WAWUBI_NOTARY_KEY_ID=account["keyId"],
        WAWUBI_NOTARY_ISSUER=account["issuerId"],
    )
    raise SystemExit(subprocess.call([str(root / "script/package_release.sh")], cwd=root, env=environment))
