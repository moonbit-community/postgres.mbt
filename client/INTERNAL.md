# Postgres Client Internals

## Core Design

The package is built around an explicit split between:

- `Client`: a lightweight handle used to submit work
- `Connection`: the socket-owning runtime that performs all PostgreSQL I/O

That split is the main architectural decision in the package.

At a conceptual level, one live connection consists of:

- one shared outbound queue
- one ordered list of requests that have been sent but not yet completed
- one private inbound queue for each in-flight request
- one side channel for asynchronous backend messages

Direction note: `outbound` and `inbound` are named relative to the local
socket-owning connection runtime. `outbound` means bytes and requests flowing
from this package to PostgreSQL. `inbound` means backend frames flowing from
PostgreSQL back into this package.

The important consequence is that the package does not route replies by looking
up a particular client handle. It routes replies by request ownership.

## Queue Ownership Model

Every operation submitted through a client handle is turned into one or more
request objects.

Each request owns:

- encoded outbound protocol bytes
- a private response queue for backend messages
- optional extra state when the request needs bidirectional coordination, such
  as COPY FROM STDIN input

All client handles derived from the same connection share the same submission
path. They all send work through one socket and therefore share one protocol
timeline. The runtime keeps their results separate by giving each request its
own response queue and routing replies according to request ownership.

That is the central routing rule in this package.

## End-To-End Flow

From a high level, message delivery works like this:

1. Connection startup finishes and constructs shared runtime state.
2. Application code submits work through a lightweight handle.
3. That work is packaged as a request and pushed into the shared outbound
   queue.
4. The socket-owning runtime takes requests from that queue in protocol order
   and writes them to the wire.
5. Sent requests enter an ordered pending list.
6. Backend frames are then read from the socket in order.
7. Frames that are globally asynchronous are peeled off into the async side
   channel.
8. All other frames are delivered to the oldest pending request.
9. The consumer that already owns that request's private response queue reads
   and decodes the frames into rows, completion states, copy chunks, or errors.
10. When PostgreSQL sends `ReadyForQuery`, that request is considered complete
    and is removed from the pending list.

So the full handoff model is:

- shared outbound queue
- FIFO pending list
- one inbound response queue per request

## What "A Specific Client Gets The Data" Means

A `Client` value is only a lightweight reference into shared runtime state.
It does not own a mailbox of its own.

Inside one live connection, reply ownership is tracked like this:

- the submitting side creates a fresh response queue for a request
- the consumer that represents that request keeps the queue
- the connection runtime forwards matching backend frames into that queue
- that same consumer drains and decodes them

This leads to two important properties:

- copying or passing around a client handle does not create an independent
  connection
- true isolation only exists across separate connections, because separate
  connections have different shared state, queues, pending lists, and sockets

In other words, the runtime is not asking "which client object should receive
this frame?" It is asking "which pending request owns this frame?"

## Multi-Stage Operations

Not every user-visible operation maps to exactly one protocol request.

Some operations naturally decompose into multiple stages, for example:

- a metadata-discovery stage
- an execution stage
- a cleanup stage

Each stage can have its own request object and therefore its own response
queue, but those stages still belong to one higher-level operation from the
caller's point of view.

This matters for understanding the runtime:

- one high-level action may occupy multiple positions on the protocol timeline
- later stages may depend on metadata learned from earlier stages
- cleanup may be delayed until the response stream reaches its terminal state

So the abstraction boundary is:

- protocol scheduling happens per request
- user intent is often expressed per multi-stage operation

## Backpressure And Stream Lifetime

The package relies on a strict invariant:

- a request is not complete until PostgreSQL sends `ReadyForQuery`

This is why response consumers cannot be abandoned casually.

Per-request response queues are intentionally bounded. That means an unfinished
consumer can stop the socket-owning runtime from making forward progress, which
in turn can stall later pipelined work.

This is also why some cleanup actions are tied to terminal stream state instead
of happening immediately: interrupting the active protocol exchange would be
incorrect.

At a conceptual level, a response consumer must do one of three things:

- consume to completion
- synchronously drain to completion
- delegate the remaining drain to background work

If none of those happens, protocol progress may stop behind unread messages.

## Pipelining Rules

The runtime opportunistically pipelines requests when it is safe to do so.

The rule is simple:

- ordinary one-way request/response traffic may be pipelined
- requests that require tight mid-stream coordination act as barriers

COPY FROM STDIN is the main example of a barrier, because the client must
continue producing outbound data while also processing inbound backend messages
for the same logical request.

Graceful shutdown is also a barrier, because once termination is requested the
runtime must stop accepting normal forward progress and instead converge toward
closure.

## Startup And Authentication

Startup is conceptually separate from the normal request loop.

Before the runtime can begin ordinary request scheduling, it must first:

1. open the transport
2. negotiate TLS if needed
3. send PostgreSQL startup parameters
4. complete authentication
5. collect backend identity and initial session state
6. construct the shared runtime state

Only after that handoff does the connection enter its steady-state request loop.

## Request Encoding

Request construction is intentionally front-loaded.

Before a request enters the shared outbound queue, the runtime tries to do as
much deterministic work as possible:

- assemble protocol frames
- validate parameter counts and type compatibility
- serialize parameter payloads
- represent SQL `NULL` explicitly rather than implicitly

This front-loading keeps runtime behavior predictable and makes many failures
occur before bytes are written to the socket.

## Response Interpretation

Inbound processing is split into two layers:

- the connection runtime only decides where each backend frame belongs
- the request-specific consumer interprets the meaning of those frames

That second layer is responsible for things like:

- turning row data into user-facing values
- tracking completion summaries
- delaying database errors until the terminal ready state
- detecting impossible protocol states and failing the stream

This separation keeps the routing logic simple and keeps protocol semantics
close to the consumer that actually cares about them.

## Async Side Channel

Some backend messages are intentionally treated as out-of-band:

- parameter updates
- notices
- notifications

These messages do not belong to the current request head in the same way that
row data or command completion does, so the runtime peels them off first and
publishes them through a separate side channel.

That separation has two benefits:

- request-specific consumers can stay focused on messages that advance their own
  protocol state
- session-wide events remain observable even while ordinary requests are in
  flight

## Type Metadata And Caching

The package separates two concerns:

- PostgreSQL's own type metadata
- MoonBit-side encode/decode contracts

The runtime starts with a built-in set of known PostgreSQL types, then enriches
that picture lazily when later operations need more detail.

This allows early progress with only raw OIDs while still supporting richer
metadata for enums, composites, domains, ranges, and other server-defined
types.

The shared cache exists so later operations do not have to rediscover the same
type information repeatedly.

## Cancellation

Cancellation is intentionally out-of-band.

Instead of trying to interrupt the main socket directly, the client keeps the
backend identity needed to open a separate short-lived control connection and
send a PostgreSQL cancel request there.

This matches PostgreSQL's own cancellation model and avoids corrupting the main
protocol stream.

## Transactions

Transaction handling is layered on top of the same request machinery.

Top-level transactions use PostgreSQL transaction commands directly. Nested
transaction scopes are modeled with savepoints.

The important runtime property is not the SQL spelling, but the handle
discipline:

- a transaction scope is single-use
- once committed or rolled back, that scope must not be reused

That rule prevents later requests from being issued against a logical scope
that no longer exists on the server.

## COPY

COPY support stays intentionally low-level.

The package treats COPY as protocol transport rather than as a format parser.
It therefore moves raw copy payloads and completion states, but leaves CSV,
text, or binary interpretation to higher layers.

COPY is also the clearest example of why the runtime distinguishes between
ordinary request traffic and barrier-style traffic:

- COPY TO STDOUT is still a streamed response
- COPY FROM STDIN is a coordinated exchange in both directions

That distinction is part of the runtime scheduler, not just part of the public
API surface.

## File Map

- `config.mbt`, `errors.mbt`
  Config and public error surface.
- `descriptors.mbt`
  PostgreSQL type descriptors and builtin-type helpers.
- `sqldata.mbt`, `scalars.mbt`
  Codec traits and built-in primitive codecs.
- `rows.mbt`, `row_stream.mbt`
  Row values and extended-query streaming.
- `simple_query.mbt`
  Simple-query messages and stream.
- `copy.mbt`
  Async messages plus COPY IN/OUT APIs and streams.
- `backend_parsing.mbt`
  Shared backend parsing helpers.
- `runtime.mbt`
  Shared runtime structs and internal handle types.
- `connect.mbt`
  Public connect/close/cancel APIs.
- `startup.mbt`
  TCP/TLS startup and authentication.
- `query.mbt`
  Prepare/query/execute/bind/portal APIs.
- `transactions.mbt`
  Transaction and savepoint APIs.
- `connection_loop.mbt`
  Socket-owning event loop and message routing.
- `wire.mbt`
  Frontend protocol encoding helpers.
- `responses.mbt`
  Backend response interpretation helpers.
- `type_cache.mbt`
  Lazy catalog-backed type lookup.
- `support.mbt`
  Smaller shared runtime helpers such as request submission and shutdown.

## Reading Order For New Maintainers

If you are taking over this package, this is a good reading order:

1. [`README.mbt.md`](./README.mbt.md)
2. `runtime.mbt`
3. `connect.mbt`
4. `support.mbt`
5. `query.mbt`
6. `connection_loop.mbt`
7. `startup.mbt`
8. `row_stream.mbt`
9. `simple_query.mbt`
10. `copy.mbt`
11. `type_cache.mbt`

That order gets you from public API shape to queue ownership to socket control
flow and finally to codec/type machinery with minimal jumping around.
