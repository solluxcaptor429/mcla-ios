#!/usr/bin/env python3
"""Pack the recompiled game code for the iOS build, encrypted.

The recompiled code (generated/default of an installed mcla-recomp) is derived
from the game's executable, so it never goes anywhere in the clear: this makes
generated.tar.zst.enc, which the workflow decrypts with the same passphrase
(openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000).

    python tools/pack_generated.py E:\\MCLA\\mcla-recomp\\generated\\default out\\generated.tar.zst.enc

The passphrase is read from the environment variable MCLA_PASSPHRASE, or from
the file named by --passphrase-file. Needs the zstandard and cryptography
packages (pip install zstandard cryptography).
"""

import argparse
import hashlib
import io
import os
import pathlib
import sys
import tarfile

KEEP_SUFFIXES = {".cpp", ".h", ".cmake"}
PBKDF2_ITERATIONS = 200000


def read_passphrase(args) -> bytes:
    if args.passphrase_file:
        return pathlib.Path(args.passphrase_file).read_text(encoding="utf-8").strip().encode()
    value = os.environ.get("MCLA_PASSPHRASE", "")
    if not value:
        sys.exit("set MCLA_PASSPHRASE or pass --passphrase-file")
    return value.encode()


def make_tar(source: pathlib.Path) -> bytes:
    buffer = io.BytesIO()
    count = 0
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        for path in sorted(source.iterdir()):
            if not path.is_file() or path.suffix not in KEEP_SUFFIXES:
                continue
            info = tarfile.TarInfo(path.name)
            data = path.read_bytes()
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
            count += 1
    if not (source / "sources.cmake").exists():
        sys.exit(f"{source} has no sources.cmake: is it generated/default?")
    print(f"{count} files, {buffer.tell() / 1e6:.1f} MB")
    return buffer.getvalue()


def encrypt_openssl(plain: bytes, passphrase: bytes) -> bytes:
    """What `openssl enc -aes-256-cbc -pbkdf2 -iter N -salt` writes."""
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    salt = os.urandom(8)
    material = hashlib.pbkdf2_hmac("sha256", passphrase, salt, PBKDF2_ITERATIONS, 48)
    key, iv = material[:32], material[32:]
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plain) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return b"Salted__" + salt + encryptor.update(padded) + encryptor.finalize()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=pathlib.Path, help="generated/default")
    parser.add_argument("output", type=pathlib.Path, help="generated.tar.zst.enc")
    parser.add_argument("--passphrase-file")
    args = parser.parse_args()

    import zstandard

    passphrase = read_passphrase(args)
    tar_bytes = make_tar(args.source)
    compressed = zstandard.ZstdCompressor(level=19, threads=-1).compress(tar_bytes)
    print(f"compressed: {len(compressed) / 1e6:.1f} MB")
    encrypted = encrypt_openssl(compressed, passphrase)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encrypted)
    print(f"wrote {args.output} ({len(encrypted) / 1e6:.1f} MB, sha256 {hashlib.sha256(encrypted).hexdigest()})")


if __name__ == "__main__":
    main()
