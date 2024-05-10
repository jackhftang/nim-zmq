import ./bindings
import std/[strformat, logging]

# Unofficial easier-for-Nim API

#[
  Types definition
]#
type
  ZmqError* = object of IOError ## exception that is raised if something fails
                                ## errno value code
    error*: cint

  ZConnectionImpl* {.pure, final.} = object
    ## A Zmq connection. Since ``ZContext`` and ``ZSocket`` are pointers, it is highly recommended to **not** copy ``ZConnection``.
    context*: ZContext ## Zmq context from C-bindings.
    socket*: ZSocket   ## Zmq socket from C-bindings.
    ownctx: bool       # Boolean indicating if the connection owns the Zmq context
    alive: bool        # Boolean indicating if the connection has been closed
    sockaddr: string   # Address of the embedded socket

  ZConnection * = ref ZConnectionImpl

#[
  Error handler
]#
proc zmqError*() {.noinline, noreturn.} =
  ## raises ZmqError with error message from `zmq.strerror`.
  var e: ref ZmqError
  new(e)
  e.error = errno()
  e.msg = &"Error: {e.error}. " & $strerror(e.error)
  raise e

proc zmqErrorExceptEAGAIN() =
  var e: ref ZmqError
  new(e)
  e.error = errno()
  let errmsg = $strerror(e.error)
  if e.error == ZMQ_EAGAIN:
    when defined(zmqEAGAIN):
      if logging.getHandlers().len() > 0:
        warn(errmsg)
      else:
        echo(errmsg)
    else:
      discard
  else:
    e.msg = &"Error: {e.error}. " & errmsg
    raise e

template defaultFlag() : ZSendRecvOptions =
  when defined(defaultFlagDontWait):
    DONTWAIT
  else:
    NOFLAGS

#[
# Context related proc
]#
proc newZContext*(): ZContext =
  ## Create a new ZContext
  result = ctx_new()

proc newZContext*(option: int, optval: int): ZContext =
  ## Create a new ZContext and set its options
  result = newZContext()
  if result.ctx_set(option.cint, optval.cint) != 0:
    zmqError()

proc newZContext*(numthreads: int): ZContext =
  ## Create a new ZContext with a thread pool set to ``numthreads``
  result = newZContext(ZMQ_IO_THREADS, numthreads)

proc terminate*(ctx: ZContext) =
  ## Terminate the ZContext
  if ctx_term(ctx) != 0:
    zmqError()

#[
  get/set socket options
  Declare socket options first because it's used in =destroy hooks
]#
# Some option take cint, int64 or uint64
proc setsockopt_impl[T: SomeOrdinal](s: ZSocket, option: ZSockOptions, optval: T) =
  var val: T = optval
  if setsockopt(s, option, addr(val), sizeof(val)) != 0:
    zmqError()

# Some option take cstring
proc setsockopt_impl(s: ZSocket, option: ZSockOptions, optval: string) =
  var val: string = optval
  if setsockopt(s, option, cstring(val), val.len) != 0:
    zmqError()

# some sockopt returns integer values
proc getsockopt_impl[T: SomeOrdinal](s: ZSocket, option: ZSockOptions, optval: var T) =
  var optval_len: int = sizeof(optval)

  if bindings.getsockopt(s, option, addr(optval), addr(optval_len)) != 0:
    zmqError()

# Some sockopt returns a string
proc getsockopt_impl(s: ZSocket, option: ZSockOptions, optval: var string) =
  var optval_len: int = optval.len

  if bindings.getsockopt(s, option, cstring(optval), addr(optval_len)) != 0:
    zmqError()

#[
  Public set/get sockopt function on ZSocket / ZConnection
]#
proc setsockopt*[T: SomeOrdinal|string](s: ZSocket, option: ZSockOptions, optval: T) =
  ## setsockopt on ``ZSocket``
  ##
  ## Careful, the ``sizeof`` of ``optval`` depends on the ``ZSockOptions`` passed.
  ## Check http://api.zeromq.org/4-2:zmq-setsockopt
  setsockopt_impl[T](s, option, optval)

proc setsockopt[T: SomeOrdinal|string](c: ZConnectionImpl, option: ZSockOptions, optval: T) =
  ## Internal
  setsockopt[T](c.socket, option, optval)

proc setsockopt*[T: SomeOrdinal|string](c: ZConnection, option: ZSockOptions, optval: T) =
  ## setsockopt on ``ZConnection``
  ##
  ## Careful, the ``sizeof`` of ``optval`` depends on the ``ZSockOptions`` passed.
  ## Check http://api.zeromq.org/4-2:zmq-setsockopt
  setsockopt[T](c.socket, option, optval)

proc getsockopt*[T: SomeOrdinal|string](s: ZSocket, option: ZSockOptions): T =
  ## getsockopt on ``ZSocket``
  ##
  ## Careful, the ``sizeof`` of ``optval`` depends on the ``ZSockOptions`` passed.
  ## Check http://api.zeromq.org/4-2:zmq-setsockopt
  var optval: T
  getsockopt_impl(s, option, optval)
  optval

proc getsockopt[T: SomeOrdinal|string](c: ZConnectionImpl, option: ZSockOptions): T =
  ## Internal
  getsockopt[T](c.socket, option)

proc getsockopt*[T: SomeOrdinal|string](c: ZConnection, option: ZSockOptions): T =
  ## getsockopt on ``ZConnection``
  ##
  ## Careful, the ``sizeof`` of ``optval`` depends on the ``ZSockOptions`` passed.
  ## Check http://api.zeromq.org/4-2:zmq-setsockopt
  getsockopt[T](c.socket, option)

#[
  Destructor
]#
when defined(gcDestructors):
  proc `=destroy`(x: ZConnectionImpl) =
    # Handle exception in =destroy hook or use private close without possible exception ?
    if x.alive and not isNil(x.socket):
      var linger = 500.cint
      # Use low level primitive to avoid throwing
      if setsockopt(x.socket, LINGER, addr(linger), sizeof(linger)) != 0:
        # Handle error in closure ?
        echo("Error in closing ZMQ-socket")

      if close(x.socket) != 0:
        # Handle error in closure ?
        echo("Error in closing ZMQ-socket")

      if x.ownctx and not isNil(x.context):
        if ctx_term(x.context) != 0:
          echo("Error in closing ZMQ-context")

  proc `=wasMoved`(x: var ZConnectionImpl) =
    x.alive = false
    x.socket = nil
    x.context = nil

  proc `=sink`*(dest: var ZConnectionImpl, source: ZConnectionImpl) =
    `=destroy`(dest)
    wasMoved(dest)
    dest.context  = source.context
    dest.socket   = source.socket
    dest.ownctx   = source.ownctx
    dest.sockaddr = source.sockaddr

  proc `=copy`*(dest: var ZConnectionImpl, source: ZConnectionImpl) =
    if dest.socket != source.socket:
      dest.socket = source.socket

    if dest.sockaddr != source.sockaddr:
      dest.sockaddr = source.sockaddr

    if dest.context != source.context:
      dest.context = source.context
      dest.ownctx = false

#[
  Connect / Listen / Close
]#
proc reconnect*(conn: ZConnection) =
  ## Reconnect a previously binded/connected address
  if connect(conn.socket, conn.sockaddr.cstring) != 0:
    zmqError()

proc reconnect*(conn: var ZConnection, address: string) =
  ## Reconnect a socket to a new address
  if connect(conn.socket, address) != 0:
    zmqError()
  conn.sockaddr = address

proc disconnect*(conn: ZConnection) =
  ## Disconnect the socket
  if disconnect(conn.socket, conn.sockaddr.cstring) != 0:
    zmqError()

proc unbind*(conn: ZConnection) =
  ## Unbind the socket
  if unbind(conn.socket, conn.sockaddr.cstring) != 0:
    zmqError()

proc bindAddr*(conn: var ZConnection, address: string) =
  ## Bind the socket to a new address
  ## The socket must disconnected / unbind beforehand
  if bindAddr(conn.socket, address) != 0:
    zmqError()
  conn.sockaddr = address

proc connect*(address: string, mode: ZSocketType, context: ZContext): ZConnection =
  ## Open a new connection on an external ``ZContext`` and connect the socket. External context are useful for inproc connections.
  result = new(ZConnection)
  result.context = context
  result.ownctx = false
  result.sockaddr = address
  result.alive = true
  result.socket = socket(result.context, cint(mode))
  if result.socket == nil:
    zmqError()

  if connect(result.socket, address) != 0:
    zmqError()

proc connect*(address: string, mode: ZSocketType): ZConnection =
  ## Open a new connection on an internal (owned) ``ZContext`` and connects the socket
  runnableExamples:
    import zmq
    var pull_conn = connect("tcp://127.0.0.1:34444", PULL)
    var push_conn = listen("tcp://127.0.0.1:34444", PUSH)

    let msgpayload = "hello world !"
    push_conn.send(msgpayload)
    assert pull_conn.receive() == msgpayload

    push_conn.close()
    pull_conn.close()

  let ctx = newZContext()
  if ctx == nil:
    zmqError()

  result = connect(address, mode, ctx)
  result.ownctx = true

proc listen*(address: string, mode: ZSocketType, context: ZContext): ZConnection =
  ## Open a new connection on an external ``ZContext`` and binds on the socket. External context are useful for inproc connections.
  runnableExamples:
    import zmq
    var monoserver = listen("tcp://127.0.0.1:34444", PAIR)
    var monoclient = connect("tcp://127.0.0.1:34444", PAIR)

    monoclient.send("ping")
    assert monoserver.receive() == "ping"
    monoserver.send("pong")
    assert monoclient.receive() == "pong"

    monoclient.close()
    monoserver.close()

  result = new(ZConnection)
  result.context = context
  result.ownctx = false
  result.sockaddr = address
  result.alive = true

  result.socket = socket(result.context, cint(mode))
  if result.socket == nil:
    zmqError()

  if bindAddr(result.socket, address) != 0:
    zmqError()

proc listen*(address: string, mode: ZSocketType): ZConnection =
  ## Open a new connection on an internal (owned) ``ZContext`` and binds the socket
  let ctx = newZContext()
  if ctx == nil:
    zmqError()

  result = listen(address, mode, ctx)
  result.ownctx = true

proc close(c: var ZConnectionImpl, linger: int = 500) =
  ## Closes the ``ZConnection``.
  ## Set socket linger to ``linger`` to drop buffered message and avoid blocking, then close the socket.
  ##
  ## If the ``ZContext`` is owned by the connection, terminate the context as well.
  ##
  ## With --gc:arc/orc ``close`` must be called before ``ZConnection`` destruction or the``=destroy`` hook.
  setsockopt(c, LINGER, linger.cint)
  if close(c.socket) != 0:
    zmqError()
  c.alive = false

  # Do not destroy embedded socket if it does not own it
  if c.ownctx:
    c.context.terminate()

proc close*(c: ZConnection, linger: int = 500) =
  c[].close()

# Send / Receive
# Send with ZSocket type
proc send*(s: ZSocket, msg: string, flags: ZSendRecvOptions = defaultFlag()) =
  ## Sends a message through the socket.
  var m: ZMsg
  if msg_init(m, msg.len) != 0:
    zmqError()

  if msg.len > 0:
    # Using cstring will cause issue with XPUB / XSUB socket that can send a payload containing `\x00`
    # Copying the memory is safer
    copyMem(msg_data(m), unsafeAddr(msg[0]), msg.len)

  if msg_send(m, s, flags.cint) == -1:
    zmqError()
  # no close msg after a send

proc sendAll*(s: ZSocket, msg: varargs[string]) =
  ## Send msg as a multipart message
  let msglen = msg.len
  if msglen > 0:
    var i = 0
    while i < msglen - 1:
      s.send(msg[i], SNDMORE)
      inc(i)
    s.send(msg[i])

proc send*(c: ZConnection, msg: string, flags: ZSendRecvOptions = defaultFlag()) =
  ## Sends a message over the connection.
  send(c.socket, msg, flags)

proc sendAll*(c: ZConnection, msg: varargs[string]) =
  ## Send msg as a multipart message over the connection
  sendAll(c.socket, msg)

# receive with ZSocket type
proc receiveImpl(s: ZSocket, flags: ZSendRecvOptions = defaultFlag()): tuple[msgAvailable: bool, moreAvailable: bool, msg: string] =
  result.moreAvailable = false
  result.msgAvailable = false

  var m: ZMsg
  if msg_init(m) != 0:
    zmqError()

  if msg_recv(m, s, flags.cint) != -1:
    # normal case, proceed
    result.msgAvailable = true
    result.msg = newString(msg_size(m))
    if result.msg.len > 0:
      copyMem(addr(result.msg[0]), msg_data(m), result.msg.len)

    # Check if more part follows
    result.moreAvailable = msg_more(m).bool
  else:
    # Either an error or EAGAIN
    # EAGAIN does not raise exception
    zmqErrorExceptEAGAIN()

  if msg_close(m) != 0:
    zmqError()

proc waitForReceive*(s: ZSocket, timeout: int = -2, flags: ZSendRecvOptions = defaultFlag()): tuple[msgAvailable: bool, moreAvailable: bool, msg: string] =
  ## Set RCVTIMEO for the socket and wait until a message is available.
  ## This function is blocking.
  ##
  ## timeout:
  ##   -1 means infinite wait
  ##   positive value is in milliseconds
  ##   negative value strictly below -1 are ignored and the wait time will default to RCVTIMEO set for the socket (which by default is -1).
  ##
  ## Indicate whether a message was received or EAGAIN occured by ``msgAvailable``
  ## Indicate if more parts are needed to be received by ``moreAvailable``
  result.moreAvailable = false
  result.msgAvailable = false

  let curtimeout : cint = getsockopt[cint](s, RCVTIMEO)

  # If rcvtimeout is set and not timeout argument is passed (or -1), use the existing timeout
  # Otherwise update the rcvtimeout
  let shouldUpdateTimeout = (timeout >= -1) and ((curtimeout > 0 and timeout > 0) or (curtimeout < 0))

  if shouldUpdateTimeout:
    s.setsockopt(RCVTIMEO, timeout.cint)

  result = receiveImpl(s, flags)

  if shouldUpdateTimeout:
    s.setsockopt(RCVTIMEO, curtimeout.cint)

proc tryReceive*(s: ZSocket, flags: ZSendRecvOptions = defaultFlag()): tuple[msgAvailable: bool, moreAvailable: bool, msg: string] =
  ## Receives a message from a socket in a non-blocking way.
  ##
  ## Indicate whether a message was received or EAGAIN occured by ``msgAvailable``
  ##
  ## Indicate if more parts are needed to be received by ``moreAvailable``
  result.moreAvailable = false
  result.msgAvailable = false

  let status = getsockopt[cint](s, ZSockOptions.EVENTS).int()
  # Check if socket has an incoming message
  if (status and ZMQ_POLLIN) != 0:
    result = receiveImpl(s, flags)

proc receive*(s: ZSocket, flags: ZSendRecvOptions = defaultFlag()): string =
  ## Receive a message on socket.
  #
  ## Return an empty string on EAGAIN
  receiveImpl(s, flags).msg

proc receiveAll*(s: ZSocket, flags: ZSendRecvOptions = defaultFlag()): seq[string] =
  ## Receive all parts of a message
  ##
  ## If EAGAIN occurs without any data being received, it will be an empty seq
  var expectMessage = true
  while expectMessage:
    let (msgAvailable, moreAvailable, msg) = receiveImpl(s, flags)
    if msgAvailable:
      result.add msg
      expectMessage = moreAvailable
    else:
      expectMessage = false

proc waitForReceive*(c: ZConnection, timeout: int = -1, flags: ZSendRecvOptions = defaultFlag()): tuple[msgAvailable: bool, moreAvailable: bool, msg: string] =
  ## Set RCVTIMEO for the socket and wait until a message is available.
  ## This function is blocking.
  ##
  ## timeout:
  ##   -1 means infinite wait
  ##   positive value is in milliseconds
  ##   negative value strictly below -1 are ignored and the wait time will default to RCVTIMEO set for the socket (which by default is -1).
  ##
  ## Indicate whether a message was received or EAGAIN occured by ``msgAvailable``
  ## Indicate if more parts are needed to be received by ``moreAvailable``
  waitForReceive(c.socket, timeout, flags)

proc tryReceive*(c: ZConnection, flags: ZSendRecvOptions = defaultFlag()): tuple[msgAvailable: bool, moreAvailable: bool, msg: string] =
  ## Receives a message from a socket in a non-blocking way.
  ##
  ## Indicate whether a message was received or EAGAIN occured by ``msgAvailable``
  ##
  ## Indicate if more parts are needed to be received by ``moreAvailable``
  tryReceive(c.socket, flags)

proc receive*(c: ZConnection, flags: ZSendRecvOptions = defaultFlag()): string =
  ## Receive data over the connection
  receive(c.socket, flags)

proc receiveAll*(c: ZConnection, flags: ZSendRecvOptions = defaultFlag()): seq[string] =
  ## Receive all parts of a message
  ##
  ## If EAGAIN occurs without any data being received, it will be an empty seq
  receiveAll(c.socket, flags)


proc proxy*(frontend, backend: ZConnection) =
  ## The proxy connects a frontend socket to a backend socket. Data flows from frontend to backend.
  ## Depending on the socket types, replies may flow in the opposite direction.
  ## Before calling proxy(), you must set any socket options, and connect or bind both frontend and backend sockets. The two conventional proxy models are:
  ## ``proxy()`` runs in the current thread and returns only if/when the current context is closed.
  discard proxy(frontend.socket, backend.socket, nil)
  zmqError()

proc proxy*(frontend, backend, capture: ZConnection) =
  ## Same as ``proxy(frontend, backend: ZConnection)`` but enable the use of a capture socket.
  ## The proxy shall send all messages, received on both frontend and backend, to the capture socket. The capture socket should be a ZMQ_PUB, ZMQ_DEALER, ZMQ_PUSH, or ZMQ_PAIR socket.
  discard proxy(frontend.socket, backend.socket, capture.socket)
  zmqError()
