#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source="$root/Lambda64/supervisor/dma-buffer.lisp"
package="$root/Lambda64/compiler/package.lisp"
python3 - "$source" "$package" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
package = Path(sys.argv[2]).read_text()
assert '(define-condition dma-buffer-allocation-error (error storage-condition)' in source
assert ':length :reader dma-buffer-allocation-error-length' in source
assert ':contiguous :reader dma-buffer-allocation-error-contiguous-p' in source
assert ':32-bit-only :reader dma-buffer-allocation-error-32-bit-only-p' in source
assert source.count("(error 'dma-buffer-allocation-error") == 2
assert ':length length' in source and ':contiguous contiguous' in source
assert ':32-bit-only 32-bit' in source
# ERRORP NIL remains a non-signalling allocation probe, and the pager TODO is
# intentionally retained until a reclaim hook exists in the physical allocator.
assert 'return-from alloc-sg-vec nil' in source
assert 'TODO: Should this call into the pager' in source
for symbol in ('#:dma-buffer-allocation-error',
               '#:dma-buffer-allocation-error-length',
               '#:dma-buffer-allocation-error-contiguous-p',
               '#:dma-buffer-allocation-error-32-bit-only-p'):
    assert symbol in package
print('dma-buffer allocation condition contract: ok')
PY
