redis = require 'redis'
MemoryAdapter = require './adapters/Memory'
Model = require './Model'
Stm = require './Stm'
PubSub = require './PubSub'
transaction = require './transaction'
pathParser = require './pathParser.server'
TxnApplier = require './TxnApplier'
redisInfo = require './redisInfo'

Store = module.exports = (AdapterClass = MemoryAdapter) ->
  @_adapter = adapter = new AdapterClass
  # Client for data access and event publishing
  @_redisClient = redisClient = redis.createClient()
  # Client for internal Rally event subscriptions
  @_subClient = subClient = redis.createClient()
  # Client for event subscriptions of txns only
  @_txnSubClient = txnSubClient = redis.createClient()
  
  ## Downstream Transactional Interface ##

  # Redis clients used for subscribe, psubscribe, unsubscribe,
  # and punsubscribe cannot be used with any other commands.
  # Therefore, we can only pass the current `redisClient` as the
  # pubsub's @_publishClient.
  @_pubSub = pubSub = new PubSub 'Redis',
    pubClient: redisClient
    subClient: txnSubClient
  @_localModels = localModels = {}
  pubSub.onMessage = (clientId, txn) ->
    # Don't send transactions back to the model that created them.
    # On the server, the model directly handles the store._commit callback.
    # Over Socket.io, a 'txnOk' message is sent below.
    return if clientId == transaction.clientId txn
    # For models only present on the server, process the transaction
    # directly in the model
    return model._onTxn txn if model = localModels[clientId]
    # Otherwise, send the transaction over Socket.io
    if socket = clientSockets[clientId]
      # Prevent sending duplicate transactions by only sending new versions
      base = transaction.base txn
      if base > socket.__base
        socket.__base = base
        nextTxnNum clientId, (num) ->
          socket.emit 'txn', txn, num
  
  @_nextTxnNum = nextTxnNum = (clientId, callback) ->
    redisClient.incr 'txnClock.' + clientId, (err, value) ->
      throw err if err
      callback value
  
  # TODO: Make sure there are no weird race conditions here, since we are
  # caching the value of starts and it could potentially be stale when a
  # transaction is received
  redisStarts = null
  startId = null
  redisClient.on 'connect', ->
    redisInfo.subscribeToStarts subClient, redisClient, (starts) ->
      redisStarts = starts
      startId = starts[0][0]
  redisClient.on 'end', ->
    redisStarts = null
    startId = null
  
  hasInvalidVer = (socket, ver, clientStartId) ->
    # Don't allow a client to connect unless there is a valid startId to
    # compare the model's against
    unless startId
      socket.disconnect()
      return true
    # TODO: Map the client's version number to the Stm's and update the client
    # with the new startId unless the client's version includes versions that
    # can't be mapped
    if clientStartId != startId
      socket.emit 'fatalErr'
      return true
    return false
  
  clientSockets = {}
  @_setSockets = (sockets) -> sockets.on 'connection', (socket) ->
    # TODO Once socket.io supports query params in the
    # socket.io urls, then we can remove this. Instead,
    # we can add the socket <-> clientId assoc in the
    # `sockets.on 'connection'...` callback.
    socket.on 'sub', (clientId, paths, ver, clientStartId) ->
      return if hasInvalidVer socket, ver, clientStartId
      
      # TODO Map the clientId to a nickname (e.g., via session?), and broadcast presence
      #      to subscribers of the relevant namespace(s)
      socket.on 'disconnect', ->
        pubSub.unsubscribe clientId
        delete clientSockets[clientId]
        redisClient.del 'txnClock.' + clientId, (err, value) ->
          throw err if err
      
      socket.on 'txn', (txn, clientStartId) ->
        base = transaction.base txn
        return if hasInvalidVer socket, base, clientStartId
        commit txn, (err, txn) ->
          txnId = transaction.id txn
          base = transaction.base txn
          # Return errors to client, with the exeption of duplicates, which
          # may need to be sent to the model again
          return socket.emit 'txnErr', err, txnId if err && err != 'duplicate'
          nextTxnNum clientId, (num) ->
            socket.emit 'txnOk', txnId, base, num
      
      socket.on 'txnsSince', txnsSince = (ver, clientStartId) ->
        return if hasInvalidVer socket, ver, clientStartId
        # Reset the pending transaction number in the model
        redisClient.get 'txnClock.' + clientId, (err, value) ->
          throw err if err
          socket.emit 'txnNum', value || 0
          forTxnSince ver, clientId, (txn) ->
            nextTxnNum clientId, (num) ->
              socket.__base = transaction.base txn
              socket.emit 'txn', txn, num
      
      # This is used to prevent emitting duplicate transactions
      socket.__base = 0
      # Set up subscriptions to the store for the model
      clientSockets[clientId] = socket
      pubSub.subscribe clientId, paths
      # Return any transactions that the model may have missed
      txnsSince ver + 1, clientStartId
  
  @_forTxnSince = forTxnSince = (ver, clientId, onTxn, done) ->
    return unless pubSub.hasSubscriptions clientId
    
    # TODO Replace with a LUA script that does filtering?
    redisClient.zrangebyscore 'txns', ver, '+inf', 'withscores', (err, vals) ->
      throw err if err
      txn = null
      for val, i in vals
        if i % 2
          continue unless pubSub.subscribedToTxn clientId, txn
          txn[0] = +val
          onTxn txn
        else
          txn = JSON.parse val
      done() if done
  
  populateModel = (model, paths, callback) ->
    # Store subscriptions in the model so that it can submit them to the
    # server when it connects
    model._storeSubs = model._storeSubs.concat paths
    # Subscribe while the model still only resides on the server
    # The model is unsubscribed before sending to the browser
    clientId = model._clientId
    pubSub.subscribe clientId, paths
    
    maxVer = 0
    getting = paths.length
    modelAdapter = model._adapter
    for path in paths
      # TODO: Select only the correct properties instead of everything under the path
      path = path.replace /\.\*.*/, ''
      adapter.get path, (err, value, ver) ->
        return callback err if err
        maxVer = Math.max maxVer, ver
        modelAdapter.set path, value, ver
        return if --getting
        modelAdapter.ver = maxVer
        
        # Apply any transactions in the STM that have not yet been applied
        # to the store
        forTxnSince maxVer + 1, clientId, onTxn = (txn) ->
          method = transaction.method txn
          args = transaction.args txn
          args.push transaction.base txn
          modelAdapter[method] args...
        , done = ->
          localModels[clientId] = model
          callback null, model
  
  @subscribe = (model, paths..., callback) ->
    # TODO: Support path wildcards, references, and functions
    
    if arguments.length == 1
      # If subscribe(callback)
      callback = model
    else
      # If subscribe(model, paths..., callback)
      return populateModel model, paths, callback if model instanceof Model
      # If subscribe(paths..., callback)
      paths.unshift model
    
    nextClientId (clientId) ->
      model = new Model(clientId)
      model._startId = startId
      populateModel model, paths, callback
  
  @unsubscribe = (model, paths..., callback) ->
    throw new Error 'Unimplemented'
    modelAdapter = model._adapter
    if !paths.length
      # If unsubscribe(model, callback)
      modelAdapter.flush() # unpopulate
    else
      # If unsubscribe(model, paths..., callback)
  

  ## Mutator Interface ##

  @flush = (callback) ->
    done = false
    cb = (err) ->
      if callback && (done || err)
        callback err
        callback = null
      done = true
    adapter.flush cb
    redisClient.flushdb (err) ->
      if err && callback
        callback err
        return callback = null
      redisInfo.onStart redisClient, cb
  
  @get = (path, callback) -> @_adapter.get path, callback
  
  @set = (path, value, ver, callback) ->
    commit [ver, nextTxnId(), 'set', path, value], callback

  @del = (path, ver, callback) ->
    commit [ver, nextTxnId(), 'del', path], callback
  
  nextClientId = (callback) ->
    redisClient.incr 'clientClock', (err, value) ->
      throw err if err
      callback value.toString(36)
  # Note that Store clientIds MUST begin with '#', as this is used to treat
  # conflict detection between Store and Model transactions differently
  clientId = ''
  nextClientId (value) -> clientId = '#' + value
  txnCount = 0
  nextTxnId = -> clientId + '.' + txnCount++
  
  ## Upstream Transaction Interface ##
  stm = new Stm redisClient
  @_commit = commit = (txn, callback) ->
    ver = transaction.base txn
    if ver && typeof ver isnt 'number'
      # In case of something like @set(path, value, callback)
      throw new Error 'Version must be null or a number'
    stm.commit txn, (err, ver) ->
      txn[0] = ver
      callback err, txn if callback
      return if err
      # TODO Wrap PubSub with TxnPubSub. Then, just pass around txn,
      # and TxnPubSub can subtract out the payload of path from txn, too.
      pubSub.publish transaction.clientId(txn), transaction.path(txn), txn
      txnApplier.add txn, ver
  
  ## Ensure Serialization of Transactions to the DB ##
  # TODO: This algorithm will need to change when we go multi-process,
  # because we can't count on the version to increase sequentially
  txnApplier = new TxnApplier
    applyTxn: (txn, ver) ->
      args = transaction.args txn
      args.push ver, (err) ->
        # TODO: Better adapter error handling and potentially a second callback
        # to the caller of commit when the adapter operation completes
        throw err if err
      adapter[transaction.method txn] args...

  return
