#!/usr/bin/env python3
"""Build a sanitized, reproducible-ish ZIP of the Surge Skill for sharing."""
from __future__ import annotations
import hashlib, os, re, stat, sys, zipfile
from datetime import datetime
from pathlib import Path

SCRIPT_DIR=Path(__file__).resolve().parent
SOURCE=SCRIPT_DIR.parent
DEFAULT=Path("/var/minis/workspace") / f"surge-ios-skill-{datetime.now():%Y%m%d}.zip"
OUTPUT=Path(sys.argv[1]).expanduser() if len(sys.argv)>1 else DEFAULT
EXCLUDED_PARTS={"__pycache__",".git",".DS_Store"}
EXCLUDED_SUFFIXES={".pyc",".pyo",".session",".sqlite",".db"}
EXCLUDED_NAMES={"password","credentials",".env","id_rsa","id_ed25519"}
SECRET_PATTERNS=[
    re.compile(rb"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"),
    re.compile(rb"(?i)(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{20,}"),
]

def included(path:Path)->bool:
    rel=path.relative_to(SOURCE)
    return not (set(rel.parts)&EXCLUDED_PARTS or path.suffix in EXCLUDED_SUFFIXES or path.name in EXCLUDED_NAMES)

def digest(data:bytes)->str: return hashlib.sha256(data).hexdigest()

def main():
    try:
        OUTPUT.resolve().relative_to(SOURCE.resolve())
    except ValueError:
        pass
    else:
        raise SystemExit("Output ZIP must be outside the Skill directory")
    files=[]
    for p in SOURCE.rglob("*"):
        if p.is_symlink():
            raise SystemExit(f"Symlinks are not allowed in release packages: {p.relative_to(SOURCE)}")
        if p.is_file() and included(p):
            files.append(p)
    if not files: raise SystemExit("No files to package")
    for p in files:
        data=p.read_bytes()
        for pattern in SECRET_PATTERNS:
            if pattern.search(data): raise SystemExit(f"Potential secret found in {p.relative_to(SOURCE)}")
    OUTPUT.parent.mkdir(parents=True,exist_ok=True)
    tmp=OUTPUT.with_suffix(OUTPUT.suffix+".tmp")
    root="surge"
    try:
        with zipfile.ZipFile(tmp,"w",zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            for p in sorted(files,key=lambda x:str(x.relative_to(SOURCE))):
                rel=p.relative_to(SOURCE); data=p.read_bytes()
                info=zipfile.ZipInfo(f"{root}/{rel.as_posix()}",date_time=(2026,1,1,0,0,0))
                mode=0o755 if os.access(p,os.X_OK) else 0o644
                info.external_attr=(stat.S_IFREG|mode)<<16
                info.compress_type=zipfile.ZIP_DEFLATED
                z.writestr(info,data)
        tmp.replace(OUTPUT)
    finally:
        tmp.unlink(missing_ok=True)
    print(OUTPUT)
    print(digest(OUTPUT.read_bytes()))
    print(f"files={len(files)} bytes={OUTPUT.stat().st_size}")
if __name__=="__main__": main()
