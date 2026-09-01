---
title: Telnet non-blocking receive design
status: active
owner: networking
last-verified: 2026-08-31
verified-against: Lambda64/applications/telnet.lisp
review-cycle: 30d
source-of-truth: code
---

# Telnet non-blocking receive design

This design is the shared implementation boundary for TF-WI-0003 (UTF-8 input)
and TF-WI-0004 (synchronous Telnet command reads). It applies only to the
binary TCP receive path in `Lambda64/applications/telnet.lisp`.

## Problem boundary

The application loop uses `read-byte-no-hang`, but the current receive helper
performs further synchronous `read-byte` calls after it sees IAC. A partial
command, option negotiation, or subnegotiation can therefore block the GUI
event loop. Ordinary payload bytes are also converted one byte at a time, so a
multi-byte UTF-8 character cannot survive packet boundaries.

The TCP stream remains an octet stream. Telnet framing and NVT CR/NUL handling
must occur before text decoding; changing the TCP stream to a character stream
would mix protocol bytes with character bytes.

## Ownership and non-blocking invariant

Each `telnet-client` owns one receive-state. The main loop feeds it exactly one
octet obtained through `read-byte-no-hang`. The feed operation may update local
state, write a Telnet reply, and deliver decoded characters to the XTerm, but
**must never read from the connection**. `NIL` means no byte is available and
must leave the receive-state unchanged.

The receive-state contains:

- framing state: `data`, `iac`, `negotiation-option`, `sb-option`, `sb-data`,
  `sb-iac`, `sb-discard`, or `sb-discard-iac`;
- pending negotiation command and subnegotiation option/payload;
- CR/NUL state for NVT data; and
- incremental UTF-8 state with the same valid-scalar and replacement behavior
  as `Lambda64/system/external-format.lisp`.

No state is global or shared by clients. The normal parser has no unbounded
buffer: at most 4096 payload octets are retained for a subnegotiation. The next
payload octet enters `sb-discard`; input is then discarded through the matching
IAC SE before the parser returns to `data`. An IAC IAC pair while discarding is
still part of the discarded payload. This prevents an oversized control frame
from leaking into terminal data while keeping recovery non-fatal.

## Framing transitions

| State | Incoming octet | Required action |
| --- | --- | --- |
| `data` | IAC | enter `iac` |
| `data` | other | apply NVT CR/NUL rule, then feed payload decoder |
| `iac` | IAC | restore one payload byte `FF`, return to `data` |
| `iac` | DO/DONT/WILL/WONT | retain command and enter `negotiation-option` |
| `iac` | SB | enter `sb-option` |
| `iac` | other | dispatch complete two-octet command; return to `data` |
| `negotiation-option` | any | dispatch complete command plus option; return to `data` |
| `sb-option` | any | retain option and enter `sb-data` |
| `sb-data` | IAC | enter `sb-iac` |
| `sb-data` | other | append payload subject to the configured limit |
| `sb-iac` | IAC | append one `FF`; return to `sb-data` |
| `sb-iac` | SE | dispatch complete subnegotiation; return to `data` |
| `sb-iac` | other | discard malformed subnegotiation, reset it, then resynchronise as a top-level IAC command |
| `sb-discard` | IAC | enter `sb-discard-iac` |
| `sb-discard` | other | discard the octet and remain in `sb-discard` |
| `sb-discard-iac` | SE | finish discarding and return to `data` |
| `sb-discard-iac` | other | discard the octet and return to `sb-discard` |

Command handlers receive complete command/option/payload values and may write a
response, but may not perform a read. A partial control sequence consequently
cannot stall compositor processing.

## NVT and UTF-8 behavior

The parser delivers CR immediately. A following *data* NUL is suppressed; a
following LF is delivered normally. Telnet control bytes do not clear a pending
CR state. CR/NUL removal therefore precedes UTF-8 handling.

Only framed data bytes reach the existing incremental external-format decoder.
It accepts one- to four-octet UTF-8 sequences, retains incomplete sequences
across feeds, and emits no character until a sequence is complete. Invalid
leaders, continuations, and values rejected by
`mezzano.internals::unicode-scalar-value-p` produce one U+FFFD according to
that decoder's behavior. If an invalid continuation is itself a new leader, it
is retained as the start of the next character. Restored IAC data byte `FF` is
an invalid UTF-8 byte and therefore follows that same replacement behavior.

EOF is handled by a distinct finalisation path: an incomplete UTF-8 sequence
emits one U+FFFD, incomplete IAC/negotiation/subnegotiation sequences are
discarded, and all state resets. A repeated EOF produces no additional output.

## Acceptance matrix

| Level | Required evidence |
| --- | --- |
| Host | Pure parser tests feed every byte boundary for ASCII, 2/3/4-octet UTF-8, invalid and truncated UTF-8, IAC quoting, negotiation, subnegotiation, CR/NUL, malformed frames, EOF, and no-data state preservation. |
| Guest | An `app.telnet` fixture with a simulated sink verifies delivered characters, replies, and parser state without a real GUI or network dependency. |
| Integration | A local scripted Telnet peer sends deliberately split control frames and UTF-8 while compositor events are injected; the UI must continue processing events until a clean EOF. |
