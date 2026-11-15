#!/usr/bin/env python3
"""Download the pinned Linux amd64/arm64 age archive and verify its SHA-256."""

import argparse
import hashlib
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.request import Request, urlopen


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argumrnt('--arch', default='amd64')
    parser.add_argument('--version', required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()

    if sys.version_info < (3, 11):
        parser.error(f'Python 3.11+ required; found {sys.version.split()[0]}')

    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('version must be in MAJOR.MINOR.PATCH form')

    expected = args.sha256.lower()
    if not re.fullmatch(r'[0-9a-f]{64}', expected):
        parser.error('--sha256 must contain exactly 64 hexadecimal characters')

    download_url = (
        f'https://github.com/FiloSottile/age/releases/download/v{args.version}'
    )
    urls = dict(
        amd64=(
            f'{download_url}/age-v{args.version}-linux-amd64.tar.gz'
        ),
        arm64=(
            f'{download_url}/age-v{args.version}-linux-arm64.tar.gz'
        ),
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None

    try:
        request = Request(
            urls[args.arch],
            headers={'User-Agent': 'openresty-repo-docker-mirror'},
        )
        digest = hashlib.sha256()

        with urlopen(request, timeout=60) as response:
            if not response.geturl().startswith('https://'):
                raise RuntimeError('Download redirected to a non-HTTPS URL')

            with tempfile.NamedTemporaryFile(
                mode='wb',
                dir=args.output.parent,
                prefix=f'.{args.output.name}.',
                suffix='.part',
                delete=False,
            ) as download:
                temporary_path = Path(download.name)

                while chunk := response.read(1024 * 1024):
                    download.write(chunk)
                    digest.update(chunk)

        actual = digest.hexdigest()
        if actual != expected:
            raise RuntimeError(
                f'SHA-256 mismatch: expected {expected}, got {actual}'
            )

        os.replace(temporary_path, args.output)
        print(f'Verified age v{args.version} archive.')
        return 0

    except Exception as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        print(f'Download or verification failed: {error}', file=sys.stderr)
        return 1


if '__main__' == __name__:
    raise SystemExit(main())
