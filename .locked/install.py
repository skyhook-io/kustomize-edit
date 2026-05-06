#!/usr/bin/env python3
"""Install a snapshot's tool bytes, checking their recorded SHA-256."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


def main():
    name = sys.argv[1]
    config = json.loads(Path(__file__).with_name("tools.json").read_text())
    tool = config[name]
    os_name = platform.system().lower()
    arch = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    asset = tool["assets"].get(f"{os_name}-{arch}")
    if asset is None:
        raise RuntimeError("This snapshot has no tool binary for the runner platform")
    requested = os.environ.get("LOCKED_REQUESTED_VERSION", "")
    if requested and requested not in ("latest",tool["version"], tool["version"].removeprefix("v")):
        raise RuntimeError("Requested tool version differs from this locked snapshot")
    filename = {"rollouts": "kubectl-argo-rollouts", "argo": "argo", "yq": "yq", "buildx": "docker-buildx"}[name]
    if name == "buildx":
        existing_config = Path(os.environ.get("DOCKER_CONFIG", str(Path.home()/".docker")))
        scoped_config = Path(tempfile.mkdtemp(prefix="skyhook-locked-docker-",dir=os.environ["RUNNER_TEMP"]))
        scoped_config.chmod(0o700)
        if (existing_config/"config.json").is_file():
            settings = json.loads((existing_config/"config.json").read_text())
            if not isinstance(settings,dict):
                raise RuntimeError("Docker configuration must be a JSON object")
            settings.pop("cliPluginsExtraDirs",None)
            (scoped_config/"config.json").write_text(json.dumps(settings))
            (scoped_config/"config.json").chmod(0o600)
        for directory in ("contexts","certs.d","tls"):
            if (existing_config/directory).is_dir():
                shutil.copytree(existing_config/directory,scoped_config/directory)
        folder = scoped_config/"cli-plugins"
        with open(os.environ["GITHUB_ENV"],"a") as output:
            output.write("DOCKER_CONFIG="+str(scoped_config)+"\n")
            output.write("DOCKER_CLI_PLUGIN_EXTRA_DIRS=\n")
    else:
        folder = Path(os.environ["RUNNER_TEMP"]) / "skyhook-locked-tools" / asset["sha256"]
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / filename
    if os.environ.get("LOCKED_VERIFY_ONLY") == "true":
        # Only raw plugins support verifying preinstalled bytes directly.
        existing = shutil.which(filename)
        if not existing or asset["encoding"] != "raw" or hashlib.sha256(Path(existing).read_bytes()).hexdigest() != asset["sha256"]:
            raise RuntimeError("Preinstalled tool must match the snapshot checksum when installation is disabled. Enable installation or provide the recorded binary.")
        return
    for attempt in range(3):
        try:
            with urlopen(asset["url"], timeout=120) as response:
                content = response.read()
            break
        except HTTPError as error:
            if error.code not in {429,500,502,503,504} or attempt == 2:
                raise
        except (URLError,TimeoutError):
            if attempt == 2:
                raise
        time.sleep(attempt+1)
    if hashlib.sha256(content).hexdigest() != asset["sha256"]:
        raise RuntimeError("Downloaded tool failed SHA-256 verification")
    if asset["encoding"] == "gzip":
        content = gzip.decompress(content)
    with tempfile.NamedTemporaryFile(dir=folder, delete=False) as temporary:
        temporary.write(content)
        tmp = Path(temporary.name)
    tmp.chmod(0o755)
    tmp.replace(target)
    if name != "buildx":
        with open(os.environ["GITHUB_PATH"], "a") as output:
            output.write(str(folder) + "\n")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print("::error::"+str(error),file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("::error::Locked tool installation failed. Check platform, version, network access, and snapshot integrity.", file=sys.stderr)
        sys.exit(1)
