{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE RecordWildCards            #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.ManagedProcess
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a high(er) level API for building complex @Process@
-- implementations by abstracting out the management of the process' mailbox,
-- reply/response handling, timeouts, process hiberation, error handling
-- and shutdown/stop procedures. It is modelled along similar lines to OTP's
-- gen_server API - <http://www.erlang.org/doc/man/gen_server.html>.
--
-- In particular, a /managed process/ will interoperate cleanly with the
-- "Control.Distributed.Process.Platform.Supervisor" API.
--
-- [API Overview]
--
-- Once started, a /managed process/ will consume messages from its mailbox and
-- pass them on to user defined /handlers/ based on the types received (mapped
-- to those accepted by the handlers) and optionally by also evaluating user
-- supplied predicates to determine which handler(s) should run.
-- Each handler returns a 'ProcessAction' which specifies how we should proceed.
-- If none of the handlers is able to process a message (because their types are
-- incompatible), then the 'unhandledMessagePolicy' will be applied.
--
-- The 'ProcessAction' type defines the ways in which our process can respond
-- to its inputs, whether by continuing to read incoming messages, setting an
-- optional timeout, sleeping for a while or stopping. The optional timeout
-- behaves a little differently to the other process actions. If no messages
-- are received within the specified time span, a user defined 'timeoutHandler'
-- will be called in order to determine the next action.
--
-- The 'ProcessDefinition' type also defines a @terminateHandler@,
-- which is called whenever the process exits, whether because a callback has
-- returned 'stop' as the next action, or as the result of unhandled exit signal
-- or similar asynchronous exceptions thrown in (or to) the process itself.
--
-- The other handlers are split into two groups: /apiHandlers/ and /infoHandlers/.
-- The former contains handlers for the 'cast' and 'call' protocols, whilst the
-- latter contains handlers that deal with input messages which are not sent
-- via these API calls (i.e., messages sent using bare 'send' or signals put
-- into the process mailbox by the node controller, such as
-- 'ProcessMonitorNotification' and the like).
--
-- [The Cast/Call Protocol]
--
-- Deliberate interactions with a /managed process/ usually fall into one of
-- two categories. A 'cast' interaction involves a client sending a message
-- asynchronously and the server handling this input. No reply is sent to
-- the client. On the other hand, a 'call' is a /remote procedure call/,
-- where the client sends a message and waits for a reply from the server.
--
-- All expressions given to @apiHandlers@ have to conform to the /cast|call/
-- protocol. The protocol (messaging) implementation is hidden from the user;
-- API functions for creating user defined @apiHandlers@ are given instead,
-- which take expressions (i.e., a function or lambda expression) and create the
-- appropriate @Dispatcher@ for handling the cast (or call).
--
-- These cast/call protocols are for dealing with /expected/ inputs. They
-- will usually form the explicit public API for the process, and be exposed by
-- providing module level functions that defer to the cast/call API, giving
-- the author an opportunity to enforce the correct types. For
-- example:
--
-- @
-- {- Ask the server to add two numbers -}
-- add :: ProcessId -> Double -> Double -> Double
-- add pid x y = call pid (Add x y)
-- @
--
-- Note here that the return type from the call is /inferred/ and will not be
-- enforced by the type system. If the server sent a different type back in
-- the reply, then the caller might be blocked indefinitely! In fact, the
-- result of mis-matching the expected return type (in the client facing API)
-- with the actual type returned by the server is more severe in practise.
-- The underlying types that implement the /call/ protocol carry information
-- about the expected return type. If there is a mismatch between the input and
-- output types that the client API uses and those which the server declares it
-- can handle, then the message will be considered unroutable - no handler will
-- be executed against it and the unhandled message policy will be applied. You
-- should, therefore, take great care to align these types since the default
-- unhandled message policy is to terminate the server! That might seem pretty
-- extreme, but you can alter the unhandled message policy and/or use the
-- various overloaded versions of the call API in order to detect errors on the
-- server such as this.
--
-- The cost of potential type mismatches between the client and server is the
-- main disadvantage of this looser coupling between them. This mechanism does
-- however, allow servers to handle a variety of messages without specifying the
-- entire protocol to be supported in excruciating detail.
--
-- [Handling Unexpected/Info Messages]
--
-- An explicit protocol for communicating with the process can be
-- configured using 'cast' and 'call', but it is not possible to prevent
-- other kinds of messages from being sent to the process mailbox. When
-- any message arrives for which there are no handlers able to process
-- its content, the 'UnhandledMessagePolicy' will be applied. Sometimes
-- it is desireable to process incoming messages which aren't part of the
-- protocol, rather than let the policy deal with them. This is particularly
-- true when incoming messages are important to the process, but their point
-- of origin is outside the author's control. Handling /signals/ such as
-- 'ProcessMonitorNotification' is a typical example of this:
--
-- > handleInfo_ (\(ProcessMonitorNotification _ _ r) -> say $ show r >> continue_)
--
-- [Handling Process State]
--
-- The 'ProcessDefinition' is parameterised by the type of state it maintains.
-- A process that has no state will have the type @ProcessDefinition ()@ and can
-- be bootstrapped by evaluating 'statelessProcess'.
--
-- All call/cast handlers come in two flavours, those which take the process
-- state as an input and those which do not. Handlers that ignore the process
-- state have to return a function that takes the state and returns the required
-- action. Versions of the various action generating functions ending in an
-- underscore are provided to simplify this:
--
-- @
--   statelessProcess {
--       apiHandlers = [
--         handleCall_   (\\(n :: Int) -> return (n * 2))
--       , handleCastIf_ (\\(c :: String, _ :: Delay) -> c == \"timeout\")
--                       (\\(\"timeout\", Delay d) -> timeoutAfter_ d)
--       ]
--     , timeoutHandler = \\_ _ -> stop $ ExitOther \"timeout\"
--   }
-- @
--
-- [Avoiding Side Effects]
--
-- If you wish to only write side-effect free code in your server definition,
-- then there is an explicit API for doing so. Instead of using the handlers
-- definition functions in this module, import the /pure/ server module instead,
-- which provides a StateT based monad for building referentially transparent
-- callbacks.
--
-- See "Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted" for
-- details and API documentation.
--
-- [Handling Errors]
--
-- Error handling appears in several contexts and process definitions can
-- hook into these with relative ease. Only process failures as a result of
-- asynchronous exceptions are supported by the API, which provides several
-- scopes for error handling.
--
-- Catching exceptions inside handler functions is no different to ordinary
-- exception handling in monadic code.
--
-- @
--   handleCall (\\x y ->
--                catch (hereBeDragons x y)
--                      (\\(e :: SmaugTheTerribleException) ->
--                           return (Left (show e))))
-- @
--
-- The caveats mentioned in "Control.Distributed.Process.Platform" about
-- exit signal handling obviously apply here as well.
--
-- [Structured Exit Handling]
--
-- Because "Control.Distributed.Process.ProcessExitException" is a ubiquitous
-- signalling mechanism in Cloud Haskell, it is treated unlike other
-- asynchronous exceptions. The 'ProcessDefinition' 'exitHandlers' field
-- accepts a list of handlers that, for a specific exit reason, can decide
-- how the process should respond. If none of these handlers matches the
-- type of @reason@ then the process will exit with @DiedException why@. In
-- addition, a private /exit handler/ is installed for exit signals where
-- @reason :: ExitReason@, which is a form of /exit signal/ used explicitly
-- by the supervision APIs. This behaviour, which cannot be overriden, is to
-- gracefully shut down the process, calling the @terminateHandler@ as usual,
-- before stopping with @reason@ given as the final outcome.
--
-- /Example: handling custom data is @ProcessExitException@/
--
-- > handleExit  (\state from (sigExit :: SomeExitData) -> continue s)
--
-- Under some circumstances, handling exit signals is perfectly legitimate.
-- Handling of /other/ forms of asynchronous exception (e.g., exceptions not
-- generated by an /exit/ signal) is not supported by this API. Cloud Haskell's
-- primitives for exception handling /will/ work normally in managed process
-- callbacks however.
--
-- If any asynchronous exception goes unhandled, the process will immediately
-- exit without running the @terminateHandler@. It is very important to note
-- that in Cloud Haskell, link failures generate asynchronous exceptions in
-- the target and these will NOT be caught by the API and will therefore
-- cause the process to exit /without running the termination handler/
-- callback. If your termination handler is set up to do important work
-- (such as resource cleanup) then you should avoid linking you process
-- and use monitors instead.
--
-- [Prioritised Mailboxes]
--
-- Many processes need to prioritise certain classes of message over others,
-- so two subsets of the API are given to supporting those cases.
--
-- A 'PrioritisedProcessDefintion' combines the usual 'ProcessDefintion' -
-- containing the cast/call API, error, termination and info handlers - with a
-- list of 'Priority' entries, which are used at runtime to prioritise the
-- server's inputs. Note that it is only messages which are prioritised; The
-- server's various handlers are still evaluated in insertion order.
--
-- Prioritisation does not guarantee that a prioritised message/type will be
-- processed before other traffic - indeed doing so in a multi-threaded runtime
-- would be very hard - but in the absence of races between multiple processes,
-- if two messages are both present in the process' own mailbox, they will be
-- applied to the ProcessDefinition's handler's in priority order. This is
-- achieved by draining the real mailbox into a priority queue and processing
-- each message in turn.
--
-- A prioritised process must be configured with a 'Priority' list to be of
-- any use. Creating a prioritised process without any priorities would be a
-- big waste of computational resources, and it is worth thinking carefully
-- about whether or not prioritisation is truly necessary in your design before
-- choosing to use it.
--
-- Using a prioritised process is as simple as calling 'pserve' instead of
-- 'serve', and passing an initialised 'PrioritisedProcessDefinition'.
--
-- [Control Channels]
--
-- For advanced users and those requiring very low latency, a prioritised
-- process definition might not be suitable, since it performs considerable
-- work /behind the scenes/. There are also designs that wish to segregate a
-- process' /control plane/ from other kinds of traffic it is expected to
-- receive. For such use cases, a /control channel/ may prove a better choice,
-- since typed channels are already prioritised during the mailbox scans that
-- the base @receiveWait@ and @receiveTimeout@ primitives from
-- distribute-process provides.
--
-- In order to utilise a /control channel/, it is necessary to start the process
-- using 'chanServe'. Instead of passing in an initialised 'ProcessDefinition',
-- this requires an expression that takes an opaque 'ControlChannel' and yields
-- the 'ProcessDefinition' in the 'Process' monad. Providing the opaque reference
-- in this fashion is necessary, since the type of messages the control channel
-- carries does not correlate directly to the inter-process traffic it uses
-- internally. The API for creating handlers that respond to /control channel/
-- inputs (i.e., 'handleControlChan' and 'handleControlChan_') also requires the
-- reference to be passed with the handler expression.
--
-- In order for clients to communicate with a server via its control channel,
-- they must pass a handle to a 'ControlPort', which can be obtained by
-- evaluating 'channelControlPort' on the 'ControlChannel' passed to the
-- expression which yields the 'ProcessDefinition'. It is for this reason that
-- we evaluate the 'ProcessDefinition' construction in the process monad, since
-- using an @MVar@ or @STM@ construct is the easiest way to have the channel's
-- control port /escape/ to the outside world. A 'ControlPort' is @Serializable@,
-- so they can alternatively be sent to other processes.
--
-- /Control channel/ traffic will only be prioritised over other traffic if the
-- handlers using it are present before others (e.g., @handleInfo, handleCast@,
-- etc) in the process definition. It is not possible to combine prioritised
-- processes with /control channels/.
--
-- [Performance Considerations]
--
-- The server implementations are fairly optimised, but there /is/ a definite
-- cost associated with scanning the mailbox to match on protocol messages,
-- plus additional costs in space and time due to mapping over all available
-- /info handlers/ for non-protocol (i.e., neither /call/ nor /cast/) messages.
-- These are exacerbated when using prioritisation.
--
-- From the client perspective, it's important to remember that the /call/
-- protocol will wait for a reply in most cases, triggering a full O(n) scan of
-- the caller's mailbox. If the mailbox is extremely full and calls are
-- regularly made, this may have a significant impact on the caller. The
-- @callChan@ family of client API functions can alleviate this, by using (and
-- matching on) a private typed channel instead, but the server must be written
-- to accomodate this. Similar gains can be had using a /control channel/,
-- though only one /control channel/ is allowed per process definition, limiting
-- the input space to just one type.
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.ManagedProcess
  ( -- * Starting server processes
    InitResult(..)
  , InitHandler
  , serve
  , pserve
  , chanServe
  , runProcess
  , prioritised
    -- * Client interactions
  , module Control.Distributed.Process.Platform.ManagedProcess.Client
    -- * Defining server processes
  , ProcessDefinition(..)
  , PrioritisedProcessDefinition(..)
  , RecvTimeoutPolicy(..)
  , Priority(..)
  , DispatchPriority()
  , Dispatcher()
  , DeferredDispatcher()
  , ShutdownHandler
  , TimeoutHandler
  , ProcessAction(..)
  , ProcessReply
  , Condition
  , CallHandler
  , CastHandler
  , UnhandledMessagePolicy(..)
  , CallRef
  , ControlChannel()
  , ControlPort()
  , defaultProcess
  , defaultProcessWithPriorities
  , statelessProcess
  , statelessInit
    -- * Server side callbacks
  , handleCall
  , handleCallIf
  , handleCallFrom
  , handleCallFromIf
  , handleCast
  , handleCastIf
  , handleInfo
  , handleRaw
  , handleRpcChan
  , handleRpcChanIf
  , action
  , handleDispatch
  , handleExit
    -- * Stateless callbacks
  , handleCall_
  , handleCallFrom_
  , handleCallIf_
  , handleCallFromIf_
  , handleCast_
  , handleCastIf_
  , handleRpcChan_
  , handleRpcChanIf_
    -- * Control channels
  , handleControlChan
  , handleControlChan_
  , channelControlPort
    -- * Prioritised mailboxes
  , module Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
    -- * Constructing handler results
  , condition
  , state
  , input
  , reply
  , replyWith
  , noReply
  , noReply_
  , haltNoReply_
  , continue
  , continue_
  , timeoutAfter
  , timeoutAfter_
  , hibernate
  , hibernate_
  , stop
  , stopWith
  , stop_
  , replyTo
  , replyChan
  ) where

import Control.Distributed.Process hiding (call, Message)
import Control.Distributed.Process.Platform.ManagedProcess.Client
import Control.Distributed.Process.Platform.ManagedProcess.Server
import Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
import Control.Distributed.Process.Platform.ManagedProcess.Internal.GenProcess
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
import Control.Distributed.Process.Platform.Internal.Types (ExitReason(..))
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Prelude hiding (init)

-- TODO: automatic registration

-- | Starts a managed process configured with the supplied process definition,
-- using an init handler and its initial arguments.
serve :: a
      -> InitHandler a s
      -> ProcessDefinition s
      -> Process ()
serve argv init def = runProcess (recvLoop def) argv init

-- | Starts a prioritised managed process configured with the supplied process
-- definition, using an init handler and its initial arguments.
pserve :: a
       -> InitHandler a s
       -> PrioritisedProcessDefinition s
       -> Process ()
pserve argv init def = runProcess (precvLoop def) argv init

-- | Starts a managed process, configured with a typed /control channel/. The
-- caller supplied expression is evaluated with an opaque reference to the
-- channel, which must be passed when calling @handleControlChan@. The meaning
-- and behaviour of the init handler and initial arguments are the same as
-- those given to 'serve'.
--
chanServe :: (Serializable b)
          => a
          -> InitHandler a s
          -> (ControlChannel b -> Process (ProcessDefinition s))
          -> Process ()
chanServe argv init mkDef = do
  pDef <- mkDef . ControlChannel =<< newChan
  runProcess (recvLoop pDef) argv init

-- TODO: Make this work!!!!!!!!!!
{-
stmChanServe :: a
             -> InitHandler a s
             -> STM b
             -> (StmControlChannel b -> Process (ProcessDefintion s))
             -> Process ()
stmChanServe = undefined
-}

-- TODO: Make this work???
{-
busServe :: (Serializable b, MessageMatcher m) =>
         => a
         -> InitHandler a s
         -> m
         -> (ControlPlane b -> Process (ProcessDefintion s))
         -> Process ()
busServe argv init m mkDef = do
  pDef <- mkDef $ ControlPlane m
-}

-- | Wraps any /process loop/ and enforces that it adheres to the
-- managed process' start/stop semantics, i.e., evaluating the
-- @InitHandler@ with an initial state and delay will either
-- @die@ due to @InitStop@, exit silently (due to @InitIgnore@)
-- or evaluate the process' @loop@. The supplied @loop@ must evaluate
-- to @ExitNormal@, otherwise the evaluating processing will will
-- @die@ with the @ExitReason@.
--
runProcess :: (s -> Delay -> Process ExitReason)
           -> a
           -> InitHandler a s
           -> Process ()
runProcess loop args init = do
  ir <- init args
  case ir of
    InitOk s d -> loop s d >>= checkExitType
    InitStop s -> die $ ExitOther s
    InitIgnore -> return ()
  where
    checkExitType :: ExitReason -> Process ()
    checkExitType ExitNormal = return ()
    checkExitType other      = die other

defaultProcess :: ProcessDefinition s
defaultProcess = ProcessDefinition {
    apiHandlers      = []
  , infoHandlers     = []
  , exitHandlers     = []
  , timeoutHandler   = \s _ -> continue s
  , shutdownHandler  = \_ _ -> return ()
  , unhandledMessagePolicy = Terminate
  } :: ProcessDefinition s

-- | Turns a standard 'ProcessDefinition' into a 'PrioritisedProcessDefinition',
-- by virtue of the supplied list of 'DispatchPriority' expressions.
--
prioritised :: ProcessDefinition s
            -> [DispatchPriority s]
            -> PrioritisedProcessDefinition s
prioritised def ps = PrioritisedProcessDefinition def ps defaultRecvTimeoutPolicy

defaultRecvTimeoutPolicy :: RecvTimeoutPolicy
defaultRecvTimeoutPolicy = RecvCounter 10000

defaultProcessWithPriorities :: [DispatchPriority s] -> PrioritisedProcessDefinition s
defaultProcessWithPriorities dps = prioritised defaultProcess dps

-- | A basic, stateless process definition, where the unhandled message policy
-- is set to 'Terminate', the default timeout handlers does nothing (i.e., the
-- same as calling @continue ()@ and the terminate handler is a no-op.
statelessProcess :: ProcessDefinition ()
statelessProcess = defaultProcess :: ProcessDefinition ()

-- | A basic, state /unaware/ 'InitHandler' that can be used with
-- 'statelessProcess'.
statelessInit :: Delay -> InitHandler () ()
statelessInit d () = return $ InitOk () d
