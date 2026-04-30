"""Property P1 — raw-hash sensitivity.

**Property 1**: ``sha256_raw(f) != sha256_raw(m(f))`` for any byte-level
mutation ``m``.

We generate random byte buffers (length 1..4096), persist them to disk, hash
them via ``utils_sha256_file``, then flip a byte (xor with a random non-zero
byte at a random offset) and re-hash. SHA-256 must yield a different digest.

**Validates: Requirements 2.1, 2.3**
"""

from __future__ import annotations

from pathlib import Path

import hypothesis
import hypothesis.strategies as st
from hypothesis import HealthCheck, given, settings

from conftest import sha256_of_file


_SETTINGS = settings(
    max_examples=5,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)


@given(
    data=st.binary(min_size=1, max_size=4096),
    offset_frac=st.floats(min_value=0.0, max_value=0.9999, allow_nan=False, allow_infinity=False),
    xor_byte=st.integers(min_value=1, max_value=255),
)
@_SETTINGS
def test_p1_raw_hash_changes_after_single_byte_flip(
    tmp_path_factory, data: bytes, offset_frac: float, xor_byte: int
):
    """Any single-byte mutation must change the raw sha256."""
    tmp_dir = tmp_path_factory.mktemp("p1")
    path = Path(tmp_dir) / "fixture.bin"
    path.write_bytes(data)

    offset = int(offset_frac * len(data))
    mutated = bytearray(data)
    mutated[offset] ^= xor_byte  # xor_byte is 1..255 so byte is guaranteed different
    assert bytes(mutated) != data  # sanity: genuine mutation

    path_mut = Path(tmp_dir) / "fixture.mutated.bin"
    path_mut.write_bytes(bytes(mutated))

    h_before = sha256_of_file(path)
    h_after = sha256_of_file(path_mut)

    assert h_before != h_after, (
        f"sha256 unchanged after flipping byte {offset} with xor {xor_byte:#x}: "
        f"len={len(data)}, hash={h_before}"
    )
